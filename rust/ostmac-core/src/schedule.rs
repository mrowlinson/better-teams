//! Team schedule week (Shifts) JSON over the FFI (read-only).
//!
//! One FFI call returns the whole week grid: schedule header + shifts
//! + time-off instances + reasons, so Swift renders with a single
//! round-trip. Balances are host-side counts of approved instances per
//! reason (Graph exposes no balances endpoint). No writes.

use std::ffi::c_char;

use serde_json::json;

use super::{cstr_to_string, err_json, rt, string_to_c};

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
