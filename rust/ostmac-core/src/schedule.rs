//! Team schedule week (Shifts) JSON over the FFI, plus write ops.
//!
//! One FFI call returns the whole week grid: schedule header + shifts
//! + time-off instances + reasons, so Swift renders with a single
//! round-trip. Balances are host-side counts of approved instances per
//! reason (Graph exposes no balances endpoint). Writes (change
//! requests, shift CRUD, publish) need `Schedule.ReadWrite.All` and
//! are manager-gated in the UI; without the scope they fail with
//! `error: "scope"`.

use std::ffi::c_char;
use std::os::raw::c_int;

use serde_json::json;

use super::{cstr_to_string, err_json, opt_cstr_to_string, rt, string_to_c};

fn shift_to_json(s: &ost::api::ShiftInfo) -> serde_json::Value {
    json!({
        "id": s.id,
        "user_id": s.user_id,
        "display_name": s.display_name,
        "start": s.start,
        "end": s.end,
        "theme": s.theme,
        "notes": s.notes,
        "is_draft": s.is_draft,
    })
}

fn time_off_to_json(t: &ost::api::TimeOffInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "user_id": t.user_id,
        "reason_id": t.reason_id,
        "start": t.start,
        "end": t.end,
        "is_draft": t.is_draft,
    })
}

fn reason_to_json(r: &ost::api::TimeOffReason) -> serde_json::Value {
    json!({
        "id": r.id,
        "name": r.name,
        "code": r.code,
    })
}

/// One team's schedule week as JSON (read-only). Requires sign-in;
/// unsigned yields `{ok:false}`. Empty `team_id` is rejected before
/// any network. `{ok:true, team_id, schedule:{enabled, time_zone,
/// provision_status}, shifts:[...], times_off:[...], reasons:[...]}`.
/// Whole schedule (first page of each collection); see
/// [`schedule_range_json`] for one week.
pub fn schedule_week_json(team_id: &str) -> String {
    schedule_json(team_id, None)
}

/// Same envelope as [`schedule_week_json`], but shifts and time off
/// are only those overlapping `[start, end]` (ISO-8601), filtered by
/// the server, every page. Bad bounds are rejected before any network.
pub fn schedule_range_json(team_id: &str, start: &str, end: &str) -> String {
    if let Err(e) = ost::api::schedule_range_path(team_id, "shifts", "sharedShift", start, end) {
        return err_json("arg", format!("{:#}", e));
    }
    schedule_json(team_id, Some((start, end)))
}

/// Longest one schedule read (sign-in check, header, shifts, time off,
/// reasons) may take before the week fails as "timed out" (the Shifts
/// pane then offers Retry). The shared reqwest client sets no timeout
/// of its own, so a stalled read would otherwise never return.
pub(crate) const SCHEDULE_CALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// Run one schedule read under [`SCHEDULE_CALL_TIMEOUT`]; errors keep
/// their full chain (`{:#}`), a timeout names the read.
async fn timed<T, E: std::fmt::Display>(
    what: &str,
    limit: std::time::Duration,
    fut: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, String> {
    match tokio::time::timeout(limit, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{:#}", e)),
        Err(_) => Err(format!("{} timed out after {}s", what, limit.as_secs())),
    }
}

/// The week payload. A team whose schedule is not enabled (Shifts never
/// set up: `enabled: false`, `provisionStatus: NotStarted`) answers
/// with empty rows; the host skips it as "no Shifts".
fn week_json(
    team_id: &str,
    schedule: &ost::api::ScheduleInfo,
    shifts: &[ost::api::ShiftInfo],
    offs: &[ost::api::TimeOffInfo],
    reasons: &[ost::api::TimeOffReason],
) -> String {
    json!({
        "ok": true,
        "team_id": team_id.trim(),
        "schedule": {
            "enabled": schedule.enabled,
            "time_zone": schedule.time_zone,
            "provision_status": schedule.provision_status,
        },
        "shifts": shifts.iter().map(shift_to_json).collect::<Vec<_>>(),
        "times_off": offs.iter().map(time_off_to_json).collect::<Vec<_>>(),
        "reasons": reasons.iter().map(reason_to_json).collect::<Vec<_>>(),
    })
    .to_string()
}

fn schedule_json(team_id: &str, range: Option<(&str, &str)>) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    let limit = SCHEDULE_CALL_TIMEOUT;
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = timed("sign-in", limit, ost::api::client::TeamsClient::new()).await?;
            let schedule =
                timed("schedule", limit, ost::api::list_schedule_data(&client, team_id)).await?;
            // Shifts not set up for this team: the collections 404, so
            // skip them (live 2026-09-28: 8 of 9 teams).
            if !schedule.enabled {
                return Ok(week_json(team_id, &schedule, &[], &[], &[]));
            }
            // Shifts, time off and reasons are independent reads.
            let (shifts, offs, reasons) = match range {
                Some((start, end)) => tokio::join!(
                    timed(
                        "shifts",
                        limit,
                        ost::api::list_shifts_range_data(&client, team_id, start, end)
                    ),
                    timed(
                        "time off",
                        limit,
                        ost::api::list_timesoffs_range_data(&client, team_id, start, end)
                    ),
                    timed(
                        "time-off reasons",
                        limit,
                        ost::api::list_timeoff_reasons_data(&client, team_id)
                    ),
                ),
                None => tokio::join!(
                    timed("shifts", limit, ost::api::list_shifts_data(&client, team_id)),
                    timed("time off", limit, ost::api::list_timesoffs_data(&client, team_id)),
                    timed(
                        "time-off reasons",
                        limit,
                        ost::api::list_timeoff_reasons_data(&client, team_id)
                    ),
                ),
            };
            Ok(week_json(team_id, &schedule, &shifts?, &offs?, &reasons?))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("schedule_week", e),
    }
}

#[no_mangle]
pub extern "C" fn ostmac_schedule_week(team_id: *const c_char) -> *mut c_char {
    match cstr_to_string(team_id) {
        Ok(t) => string_to_c(schedule_week_json(&t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One team's schedule for one date range (server-side filter). See
/// [`schedule_range_json`].
#[no_mangle]
pub extern "C" fn ostmac_schedule_range(
    team_id: *const c_char,
    start: *const c_char,
    end: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let from = match cstr_to_string(start) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(end) {
        Ok(to) => string_to_c(schedule_range_json(&team, &from, &to)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

// -- Write ops (swap/offer/time-off requests, shift CRUD, publish) --
//
// Envelopes: `{ok:true, ...}` or `{ok:false, error, detail}`. `error`
// is `arg` for caller mistakes (rejected before any sign-in/network),
// `scope` when the tenant token lacks `Schedule.ReadWrite.All`
// (the host shows scope-pending instead of raw JSON), else the op
// name. A null C string means "absent" for every optional arg; a
// non-null blank is absent too.

/// Map a write failure: missing-scope refusals become `scope`, arg
/// failures stay `arg` only when raised pre-network (FFI checks run
/// first), everything else carries the op name.
fn write_err(op: &str, e: String) -> String {
    let text = e;
    if ost::api::is_missing_scope(&text) {
        err_json("scope", format!("{} needs Schedule.ReadWrite.All: {}", op, text))
    } else {
        err_json(op, text)
    }
}

fn nonempty(value: &str, what: &str) -> Result<String, String> {
    let v = value.trim();
    if v.is_empty() {
        return Err(err_json("arg", format!("empty {}", what)));
    }
    Ok(v.to_string())
}

fn request_to_json(r: &ost::api::ChangeRequestInfo) -> serde_json::Value {
    json!({
        "id": r.id,
        "state": r.state,
        "sender_shift_id": r.sender_shift_id,
        "receiver_user_id": r.receiver_user_id,
        "reason_id": r.reason_id,
        "start": r.start,
        "end": r.end,
        "message": r.message,
    })
}

fn requests_json(team_id: &str, kind: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if ost::api::request_collection(kind).is_err() {
        return err_json("arg", format!("unknown shift request kind '{}'", kind.trim()));
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            let reqs = timed(
                "requests",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::list_change_requests_data(&client, team_id, kind),
            )
            .await?;
            Ok(json!({
                "ok": true,
                "team_id": team_id.trim(),
                "kind": kind.trim(),
                "requests": reqs.iter().map(request_to_json).collect::<Vec<_>>(),
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_requests", e),
    }
}

/// One team's change requests of one kind (`swap`|`offer`|`timeoff`).
#[no_mangle]
pub extern "C" fn ostmac_schedule_requests(team_id: *const c_char, kind: *const c_char) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(kind) {
        Ok(k) => string_to_c(requests_json(&team, &k)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

fn sender_request_json(
    op: &str,
    team_id: &str,
    kind: &str,
    sender_shift_id: &str,
    receiver_user_id: Option<&str>,
    message: Option<&str>,
) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    let sender = match nonempty(sender_shift_id, "sender_shift_id") {
        Ok(s) => s,
        Err(e) => return e,
    };
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            let id = timed(op, SCHEDULE_CALL_TIMEOUT, async {
                match kind {
                    "swap" => ost::api::create_swap_request_data(&client, team_id, &sender, receiver_user_id, message).await,
                    _ => ost::api::create_offer_request_data(&client, team_id, &sender, receiver_user_id, message).await,
                }
            })
            .await?;
            Ok(json!({ "ok": true, "id": id }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err(op, e),
    }
}

/// Create a swap request for one shift. Null receiver/message = absent.
#[no_mangle]
pub extern "C" fn ostmac_schedule_swap_create(
    team_id: *const c_char,
    sender_shift_id: *const c_char,
    receiver_user_id: *const c_char,
    message: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let sender = match cstr_to_string(sender_shift_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let recv = opt_cstr_to_string(receiver_user_id).unwrap_or(None);
    let msg = opt_cstr_to_string(message).unwrap_or(None);
    string_to_c(sender_request_json(
        "schedule_swap", &team, "swap", &sender, recv.as_deref(), msg.as_deref(),
    ))
}

/// Create an offer request (give one shift to one member).
#[no_mangle]
pub extern "C" fn ostmac_schedule_offer_create(
    team_id: *const c_char,
    sender_shift_id: *const c_char,
    receiver_user_id: *const c_char,
    message: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let sender = match cstr_to_string(sender_shift_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let recv = opt_cstr_to_string(receiver_user_id).unwrap_or(None);
    let msg = opt_cstr_to_string(message).unwrap_or(None);
    string_to_c(sender_request_json(
        "schedule_offer", &team, "offer", &sender, recv.as_deref(), msg.as_deref(),
    ))
}

fn timeoff_request_json(
    team_id: &str,
    reason_id: &str,
    start: &str,
    end: &str,
    message: Option<&str>,
) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if reason_id.trim().is_empty() {
        return err_json("arg", "empty reason_id");
    }
    if !ost::api::datetime_ok(start) {
        return err_json("arg", "start must be an ISO-8601 date-time");
    }
    if !ost::api::datetime_ok(end) {
        return err_json("arg", "end must be an ISO-8601 date-time");
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            let id = timed(
                "schedule_timeoff_request",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::create_timeoff_request_data(&client, team_id, reason_id, start, end, message),
            )
            .await?;
            Ok(json!({ "ok": true, "id": id }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_timeoff_request", e),
    }
}

/// Create a time-off request for one reason and range.
#[no_mangle]
pub extern "C" fn ostmac_schedule_timeoff_request_create(
    team_id: *const c_char,
    reason_id: *const c_char,
    start: *const c_char,
    end: *const c_char,
    message: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let reason = match cstr_to_string(reason_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let from = match cstr_to_string(start) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let to = match cstr_to_string(end) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let msg = opt_cstr_to_string(message).unwrap_or(None);
    string_to_c(timeoff_request_json(&team, &reason, &from, &to, msg.as_deref()))
}

fn decide_json(
    team_id: &str,
    kind: &str,
    request_id: &str,
    approve: bool,
    message: Option<&str>,
) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if ost::api::request_collection(kind).is_err() {
        return err_json("arg", format!("unknown shift request kind '{}'", kind.trim()));
    }
    if request_id.trim().is_empty() {
        return err_json("arg", "empty request_id");
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            timed(
                "schedule_decide",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::decide_change_request_data(&client, team_id, kind, request_id, approve, message),
            )
            .await?;
            Ok(json!({ "ok": true }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_decide", e),
    }
}

/// Approve (`approve` != 0) or decline one change request (manager).
#[no_mangle]
pub extern "C" fn ostmac_schedule_request_decide(
    team_id: *const c_char,
    kind: *const c_char,
    request_id: *const c_char,
    approve: c_int,
    message: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let kind_s = match cstr_to_string(kind) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let req = match cstr_to_string(request_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let msg = opt_cstr_to_string(message).unwrap_or(None);
    string_to_c(decide_json(&team, &kind_s, &req, approve != 0, msg.as_deref()))
}

fn shift_create_json(
    team_id: &str,
    user_id: Option<&str>,
    start: &str,
    end: &str,
    display_name: Option<&str>,
    theme: Option<&str>,
    notes: Option<&str>,
) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if !ost::api::datetime_ok(start) {
        return err_json("arg", "start must be an ISO-8601 date-time");
    }
    if !ost::api::datetime_ok(end) {
        return err_json("arg", "end must be an ISO-8601 date-time");
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            let id = timed(
                "schedule_shift_create",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::create_shift_data(
                    &client, team_id, user_id.unwrap_or(""), start, end, display_name, theme, notes,
                ),
            )
            .await?;
            Ok(json!({ "ok": true, "id": id }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_shift_create", e),
    }
}

/// Create one draft shift (manager). Blank/null user = open shift.
#[no_mangle]
pub extern "C" fn ostmac_schedule_shift_create(
    team_id: *const c_char,
    user_id: *const c_char,
    start: *const c_char,
    end: *const c_char,
    display_name: *const c_char,
    theme: *const c_char,
    notes: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let user = opt_cstr_to_string(user_id).unwrap_or(None);
    let from = match cstr_to_string(start) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let to = match cstr_to_string(end) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let name = opt_cstr_to_string(display_name).unwrap_or(None);
    let theme_s = opt_cstr_to_string(theme).unwrap_or(None);
    let notes_s = opt_cstr_to_string(notes).unwrap_or(None);
    string_to_c(shift_create_json(
        &team, user.as_deref(), &from, &to, name.as_deref(), theme_s.as_deref(), notes_s.as_deref(),
    ))
}

fn shift_update_json(
    team_id: &str,
    shift_id: &str,
    start: Option<&str>,
    end: Option<&str>,
    display_name: Option<&str>,
    theme: Option<&str>,
    notes: Option<&str>,
) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if shift_id.trim().is_empty() {
        return err_json("arg", "empty shift_id");
    }
    let fields = [start, end, display_name, theme, notes];
    if !fields.iter().any(|f| f.is_some_and(|s| !s.trim().is_empty())) {
        return err_json("arg", "nothing to update (all fields blank)");
    }
    for (name, v) in [("start", start), ("end", end)] {
        if let Some(s) = v.filter(|s| !s.trim().is_empty()) {
            if !ost::api::datetime_ok(s) {
                return err_json("arg", format!("{} must be an ISO-8601 date-time", name));
            }
        }
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            timed(
                "schedule_shift_update",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::update_shift_data(&client, team_id, shift_id, start, end, display_name, theme, notes),
            )
            .await?;
            Ok(json!({ "ok": true }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_shift_update", e),
    }
}

/// Patch one shift's draft slot (manager). Blank/null = unchanged.
#[no_mangle]
pub extern "C" fn ostmac_schedule_shift_update(
    team_id: *const c_char,
    shift_id: *const c_char,
    start: *const c_char,
    end: *const c_char,
    display_name: *const c_char,
    theme: *const c_char,
    notes: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let id = match cstr_to_string(shift_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let from = opt_cstr_to_string(start).unwrap_or(None);
    let to = opt_cstr_to_string(end).unwrap_or(None);
    let name = opt_cstr_to_string(display_name).unwrap_or(None);
    let theme_s = opt_cstr_to_string(theme).unwrap_or(None);
    let notes_s = opt_cstr_to_string(notes).unwrap_or(None);
    string_to_c(shift_update_json(
        &team, &id, from.as_deref(), to.as_deref(), name.as_deref(), theme_s.as_deref(), notes_s.as_deref(),
    ))
}

fn shift_delete_json(team_id: &str, shift_id: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if shift_id.trim().is_empty() {
        return err_json("arg", "empty shift_id");
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            timed(
                "schedule_shift_delete",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::delete_shift_data(&client, team_id, shift_id),
            )
            .await?;
            Ok(json!({ "ok": true }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_shift_delete", e),
    }
}

/// Delete one shift (manager).
#[no_mangle]
pub extern "C" fn ostmac_schedule_shift_delete(team_id: *const c_char, shift_id: *const c_char) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(shift_id) {
        Ok(id) => string_to_c(shift_delete_json(&team, &id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

fn timeoff_create_json(team_id: &str, user_id: &str, reason_id: &str, start: &str, end: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if user_id.trim().is_empty() {
        return err_json("arg", "empty user_id");
    }
    if reason_id.trim().is_empty() {
        return err_json("arg", "empty reason_id");
    }
    if !ost::api::datetime_ok(start) {
        return err_json("arg", "start must be an ISO-8601 date-time");
    }
    if !ost::api::datetime_ok(end) {
        return err_json("arg", "end must be an ISO-8601 date-time");
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            let id = timed(
                "schedule_timeoff_create",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::create_timeoff_data(&client, team_id, user_id, reason_id, start, end),
            )
            .await?;
            Ok(json!({ "ok": true, "id": id }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_timeoff_create", e),
    }
}

/// Create one draft time-off instance directly (manager).
#[no_mangle]
pub extern "C" fn ostmac_schedule_timeoff_create(
    team_id: *const c_char,
    user_id: *const c_char,
    reason_id: *const c_char,
    start: *const c_char,
    end: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let user = match cstr_to_string(user_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let reason = match cstr_to_string(reason_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let from = match cstr_to_string(start) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(end) {
        Ok(to) => string_to_c(timeoff_create_json(&team, &user, &reason, &from, &to)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

fn share_json(team_id: &str, notify_team: bool, start: Option<&str>, end: Option<&str>) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    for (name, v) in [("start", start), ("end", end)] {
        if let Some(s) = v.filter(|s| !s.trim().is_empty()) {
            if !ost::api::datetime_ok(s) {
                return err_json("arg", format!("{} must be an ISO-8601 date-time", name));
            }
        }
    }
    let run = || -> Result<String, String> {
        let r = rt()?;
        r.block_on(async {
            let client = timed("sign-in", SCHEDULE_CALL_TIMEOUT, ost::api::client::TeamsClient::new()).await?;
            timed(
                "schedule_share",
                SCHEDULE_CALL_TIMEOUT,
                ost::api::share_schedule_data(&client, team_id, notify_team, start, end),
            )
            .await?;
            Ok(json!({ "ok": true }).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => write_err("schedule_share", e),
    }
}

/// Publish drafts (manager). `notify` != 0 notifies the team. Blank
/// bounds share the whole schedule.
#[no_mangle]
pub extern "C" fn ostmac_schedule_share(
    team_id: *const c_char,
    notify: c_int,
    start: *const c_char,
    end: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let from = opt_cstr_to_string(start).unwrap_or(None);
    let to = opt_cstr_to_string(end).unwrap_or(None);
    string_to_c(share_json(&team, notify != 0, from.as_deref(), to.as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_rejects_bad_bounds_pre_network() {
        for (team, start, end) in [
            ("t1", "", "2026-10-05T00:00:00Z"),
            ("t1", "2026-09-28T00:00:00Z", "x&$top=1"),
            (" ", "2026-09-28T00:00:00Z", "2026-10-05T00:00:00Z"),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&schedule_range_json(team, start, end)).unwrap();
            assert_eq!(v["error"], "arg", "{:?}", (team, start, end));
        }
    }

    /// A read slower than the limit fails with a named "timed out"
    /// (the Swift side maps it to the connection hint + Retry); a fast
    /// read and a failed read pass through unchanged.
    #[test]
    fn timed_read_fails_named_instead_of_hanging() {
        let rt = rt().unwrap();
        let limit = std::time::Duration::from_millis(50);
        let slow = rt.block_on(timed("shifts", limit, async {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            Ok::<u32, String>(1)
        }));
        let msg = slow.unwrap_err();
        assert!(msg.contains("shifts timed out"), "{}", msg);
        let fast = rt.block_on(timed("shifts", limit, async { Ok::<u32, String>(7) }));
        assert_eq!(fast.unwrap(), 7);
        let failed = rt.block_on(timed("shifts", limit, async {
            Err::<u32, String>("HTTP 404 for x".into())
        }));
        assert_eq!(failed.unwrap_err(), "HTTP 404 for x");
        assert_eq!(SCHEDULE_CALL_TIMEOUT.as_secs(), 15);
    }

    /// Shifts not set up (live 2026-09-28: `enabled:false`,
    /// `NotStarted`): an ok week with no rows, `enabled` false.
    #[test]
    fn disabled_schedule_is_ok_week_without_rows() {
        let schedule = ost::api::ScheduleInfo {
            enabled: false,
            time_zone: None,
            provision_status: Some("NotStarted".into()),
        };
        let v: serde_json::Value =
            serde_json::from_str(&week_json(" t1 ", &schedule, &[], &[], &[])).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["team_id"], "t1");
        assert_eq!(v["schedule"]["enabled"], false);
        assert_eq!(v["schedule"]["provision_status"], "NotStarted");
        assert_eq!(v["shifts"].as_array().unwrap().len(), 0);
        assert_eq!(v["times_off"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn empty_team_id_rejected_pre_network() {
        for bad in ["", "   "] {
            let v: serde_json::Value = serde_json::from_str(&schedule_week_json(bad)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_null_pointer_yields_arg_error() {
        let p = ostmac_schedule_week(std::ptr::null());
        assert!(!p.is_null());
        let s = unsafe { std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned() };
        unsafe { drop(std::ffi::CString::from_raw(p)) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "arg");
    }

    #[test]
    fn ffi_empty_team_id_yields_arg_error() {
        let arg = std::ffi::CString::new("").unwrap();
        let p = ostmac_schedule_week(arg.as_ptr());
        let s = unsafe { std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned() };
        unsafe { drop(std::ffi::CString::from_raw(p)) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn write_rejects_bad_args_pre_network() {
        for bad in [requests_json("", "swap"), requests_json("t1", "open"), requests_json("  ", "timeoff")] {
            let v: serde_json::Value = serde_json::from_str(&bad).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        let v: serde_json::Value = serde_json::from_str(&sender_request_json(
            "schedule_swap", "t1", "swap", "  ", None, None,
        ))
        .unwrap();
        assert_eq!(v["error"], "arg");
        for bad in [
            timeoff_request_json("t1", "", "2026-12-24T00:00:00Z", "2026-12-26T00:00:00Z", None),
            timeoff_request_json("t1", "r1", "junk", "2026-12-26T00:00:00Z", None),
            timeoff_request_json("t1", "r1", "2026-12-24T00:00:00Z", "junk", None),
        ] {
            let v: serde_json::Value = serde_json::from_str(&bad).unwrap();
            assert_eq!(v["error"], "arg", "{}", bad);
        }
        for bad in [
            decide_json("", "swap", "r1", true, None),
            decide_json("t1", "bogus", "r1", true, None),
            decide_json("t1", "swap", "  ", false, None),
        ] {
            let v: serde_json::Value = serde_json::from_str(&bad).unwrap();
            assert_eq!(v["error"], "arg", "{}", bad);
        }
        for bad in [
            shift_create_json("t1", None, "junk", "2026-11-24T17:00:00Z", None, None, None),
            shift_update_json("t1", "s1", None, None, None, None, None),
            shift_update_json("t1", "  ", Some("2026-11-24T09:00:00Z"), None, None, None, None),
            shift_delete_json("t1", "  "),
            timeoff_create_json("t1", "", "r1", "2026-12-24T00:00:00Z", "2026-12-26T00:00:00Z"),
            share_json("  ", true, None, None),
            share_json("t1", false, Some("junk"), None),
        ] {
            let v: serde_json::Value = serde_json::from_str(&bad).unwrap();
            assert_eq!(v["error"], "arg", "{}", bad);
        }
        // Missing-scope Graph failures map to the scope envelope.
        let e = "HTTP 403 for https://graph.microsoft.com/v1.0/x: {{\"error\":{{\"code\":\"Forbidden\",\"message\":\"Missing scope permissions\"}}}}".to_string();
        let v: serde_json::Value = serde_json::from_str(&write_err("schedule_share", e)).unwrap();
        assert_eq!(v["error"], "scope");
        assert!(v["detail"].as_str().unwrap_or("").contains("Schedule.ReadWrite.All"));
        let e2 = "HTTP 404 for https://graph.microsoft.com/v1.0/x: {{\"error\":{{\"code\":\"NotFound\"}}}}".to_string();
        let v2: serde_json::Value = serde_json::from_str(&write_err("schedule_share", e2)).unwrap();
        assert_eq!(v2["error"], "schedule_share");
        // Request rows map to snake_case for the host.
        let r = ost::api::ChangeRequestInfo {
            id: "q1".into(),
            state: Some("pending".into()),
            sender_shift_id: Some("s1".into()),
            receiver_user_id: None,
            reason_id: None,
            start: None,
            end: None,
            message: Some("swap?".into()),
        };
        let v = request_to_json(&r);
        assert_eq!(v["sender_shift_id"], "s1");
        assert_eq!(v["state"], "pending");
    }

    #[test]
    fn row_mappers_emit_snake_case() {
        let s = ost::api::ShiftInfo {
            id: "s1".into(),
            user_id: Some("u1".into()),
            display_name: "Morning".into(),
            start: Some("2026-09-28T09:00:00".into()),
            end: Some("2026-09-28T17:00:00".into()),
            theme: Some("blue".into()),
            notes: None,
            is_draft: false,
        };
        let v = shift_to_json(&s);
        assert_eq!(v["display_name"], "Morning");
        assert_eq!(v["user_id"], "u1");
        assert_eq!(v["is_draft"], false);

        let t = ost::api::TimeOffInfo {
            id: "o1".into(),
            user_id: None,
            reason_id: Some("r1".into()),
            start: None,
            end: None,
            is_draft: true,
        };
        let v = time_off_to_json(&t);
        assert_eq!(v["reason_id"], "r1");
        assert_eq!(v["is_draft"], true);

        let r = ost::api::TimeOffReason {
            id: "r1".into(),
            name: "Vacation".into(),
            code: Some("V".into()),
        };
        let v = reason_to_json(&r);
        assert_eq!(v["name"], "Vacation");
        assert_eq!(v["code"], "V");
    }
}
