//! Breakout rooms FFI: one dispatcher over the 14 MT ops.
//!
//! Thin JSON-over-C wrappers around `ost::api::breakout` (pure
//! builders/parsers live there, pinned by its tests). Three exports:
//! - `ostmac_breakout_request`: PURE, no network — the exact
//!   `{method, url, body}` a call would send (Swift tests pin verbatim
//!   shapes through it; `args.mt_base` overrides the base, defaulting
//!   to the mapped fallback literal).
//! - `ostmac_breakout_call`: blocking executor (Swift calls off-main);
//!   `{ok:true, ...}` with the parsed answer, or `{ok:false}`.
//! - `ostmac_breakout_encode_coords`: PURE coords → `<C>` path segment.
//!
//! Ops: `list create add get update delete delete-all assign open close
//! get-settings put-settings assignees announce`. Coords arrive as the
//! `MeetingCoords` JSON (`tenant_id`, `organizer_id`, `thread_id`,
//! `message_id`, `additional_message_id?`). Every failed read returns
//! `{ok:false}` with the status in `detail`, never an empty success —
//! Swift shows the live-disabled reason.

use std::os::raw::c_char;

use serde_json::{json, Value};

use crate::{cstr_to_string, err_json, rt, string_to_c};

fn arg_json(raw: &str, what: &str) -> Result<Value, String> {
    serde_json::from_str(raw).map_err(|e| format!("bad {} JSON: {}", what, e))
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(|v| v.as_str())
}

fn arg_arr(args: &Value, key: &str) -> Vec<Value> {
    args.get(key).and_then(|v| v.as_array()).cloned().unwrap_or_default()
}

fn arg_strings(args: &Value, key: &str) -> Vec<String> {
    args.get(key)
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str().map(|s| s.to_string()))
        .collect()
}

/// The 14 op names the dispatcher accepts. Pure so tests pin the set.
pub fn op_names() -> &'static [&'static str] {
    &[
        "list",
        "create",
        "add",
        "get",
        "update",
        "delete",
        "delete-all",
        "assign",
        "open",
        "close",
        "get-settings",
        "put-settings",
        "assignees",
        "announce",
    ]
}

fn mt_base_from(args: &Value) -> String {
    arg_str(args, "mt_base").unwrap_or(ost::api::BREAKOUT_FALLBACK_MT).to_string()
}

/// Pure request builder: the exact `{method, url, body}` op `op` would
/// send for these coords + args. No network, no token. Unknown ops and
/// bad coords are arg errors.
pub fn breakout_request_json(op: &str, coords_json: &str, args_json: &str) -> String {
    let coords_v = match arg_json(coords_json, "coords") {
        Ok(v) => v,
        Err(e) => return err_json("arg", e),
    };
    let coords = match ost::api::MeetingCoords::from_json(&coords_v) {
        Ok(c) => c,
        Err(e) => return err_json("arg", format!("{:#}", e)),
    };
    let args = match arg_json(args_json, "args") {
        Ok(v) => v,
        Err(e) => return err_json("arg", e),
    };
    let mt = mt_base_from(&args);
    let version = arg_str(&args, "version");
    let total = args.get("total_participants").and_then(|v| v.as_u64());
    let (method, url, body): (&str, String, Value) = match op {
        "list" => ("GET", ost::api::list_url(&mt, &coords), Value::Null),
        "create" => {
            let count = args.get("count").and_then(|v| v.as_u64()).unwrap_or(4) as usize;
            let pre = arg_arr(&args, "preconfiguration");
            let settings = args.get("settings");
            (
                "POST",
                ost::api::create_url(&mt, &coords, version),
                ost::api::create_body(count, &pre, settings),
            )
        }
        "add" => (
            "POST",
            ost::api::add_url(&mt, &coords, version),
            ost::api::add_body(arg_str(&args, "name").unwrap_or(""), &arg_arr(&args, "participants")),
        ),
        "get" => ("GET", ost::api::get_url(&mt, &coords), Value::Null),
        "update" => (
            "PUT",
            ost::api::update_url(&mt, &coords, version),
            ost::api::update_body(
                arg_str(&args, "name").unwrap_or(""),
                &arg_arr(&args, "participants"),
                args.get("restrict_chat_access").and_then(|v| v.as_bool()).unwrap_or(false),
            ),
        ),
        "delete" => ("DELETE", ost::api::delete_url(&mt, &coords, version), Value::Null),
        "delete-all" => (
            "DELETE",
            ost::api::delete_all_url(&mt, &coords, version),
            args.get("rooms_refs").cloned().unwrap_or(Value::Null),
        ),
        "assign" => (
            "PUT",
            ost::api::bulk_url(&mt, &coords, version, total),
            ost::api::bulk_body(&arg_arr(&args, "rooms"), total),
        ),
        "open" => (
            "POST",
            ost::api::open_url(&mt, &coords, version),
            ost::api::open_body(
                &arg_arr(&args, "rooms"),
                args.get("new_timer_flow").and_then(|v| v.as_bool()).unwrap_or(false),
                total,
            ),
        ),
        "close" => (
            "POST",
            ost::api::close_url(&mt, &coords, version),
            ost::api::close_body(&arg_arr(&args, "rooms"), total),
        ),
        "get-settings" => ("GET", ost::api::settings_url(&mt, &coords, None), Value::Null),
        "put-settings" => (
            "PUT",
            ost::api::settings_url(&mt, &coords, version),
            ost::api::settings_body(args.get("settings").unwrap_or(&Value::Null)),
        ),
        "assignees" => {
            let q = ost::api::AssigneeQuery {
                calendar_event_id: arg_str(&args, "calendar_event_id").map(|s| s.to_string()),
                ical_uid: arg_str(&args, "ical_uid").map(|s| s.to_string()),
                event_type: arg_str(&args, "event_type").map(|s| s.to_string()),
                team_id: arg_str(&args, "team_id").map(|s| s.to_string()),
                max_nest_level: arg_str(&args, "max_nest_level").map(|s| s.to_string()),
                user_threshold: arg_str(&args, "user_threshold").map(|s| s.to_string()),
            };
            ("GET", ost::api::assignees_url(&mt, &coords, &q), Value::Null)
        }
        "announce" => (
            "POST",
            ost::api::announce_url(&mt, &coords),
            ost::api::announce_body(&arg_strings(&args, "room_thread_ids"), arg_str(&args, "message").unwrap_or("")),
        ),
        _ => return err_json("arg", format!("unknown breakout op {:?}", op)),
    };
    json!({"ok": true, "op": op, "method": method, "url": url, "body": body}).to_string()
}

/// Pure coords encoder: `{ok:true, encoded:"<C>"}` or `{ok:false}`.
pub fn breakout_encode_coords_json(coords_json: &str) -> String {
    let v = match arg_json(coords_json, "coords") {
        Ok(v) => v,
        Err(e) => return err_json("arg", e),
    };
    match ost::api::MeetingCoords::from_json(&v) {
        Ok(c) => json!({"ok": true, "encoded": ost::api::encode_coords(&c)}).to_string(),
        Err(e) => err_json("arg", format!("{:#}", e)),
    }
}

fn settings_to_json(s: &ost::api::RoomSettings) -> Value {
    json!({
        "allow_users_to_select_breakout_room": s.allow_users_to_select_breakout_room,
        "room_duration": s.room_duration,
        "allow_join_back_to_main_meeting": s.allow_join_back_to_main_meeting,
        "allow_move_participants_automatically": s.allow_move_participants_automatically,
        "managers": s.managers,
    })
}

/// Blocking executor for one op. Returns `{ok:true, ...}` (shape per
/// op: `rooms` list for list/create/assign, `room` for add/get/update,
/// `settings` for get/put-settings, `assignees` for assignees, bare ok
/// for delete/delete-all/open/close/announce) or `{ok:false}`.
pub fn breakout_call_json(op: &str, coords_json: &str, args_json: &str) -> String {
    if !op_names().contains(&op) {
        return err_json("arg", format!("unknown breakout op {:?}", op));
    }
    let coords_v = match arg_json(coords_json, "coords") {
        Ok(v) => v,
        Err(e) => return err_json("arg", e),
    };
    let coords = match ost::api::MeetingCoords::from_json(&coords_v) {
        Ok(c) => c,
        Err(e) => return err_json("arg", format!("{:#}", e)),
    };
    let args = match arg_json(args_json, "args") {
        Ok(v) => v,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<Value, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client =
                ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
            let version = arg_str(&args, "version");
            let total = args.get("total_participants").and_then(|v| v.as_u64());
            match op {
                "list" => {
                    let rooms =
                        ost::api::list_rooms_data(&client, &coords).await.map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "rooms": rooms.iter().map(|r| r.to_json()).collect::<Vec<_>>()}))
                }
                "create" => {
                    let count = args.get("count").and_then(|v| v.as_u64()).unwrap_or(4) as usize;
                    let rooms = ost::api::create_rooms_data(
                        &client,
                        &coords,
                        count,
                        &arg_arr(&args, "preconfiguration"),
                        args.get("settings"),
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "rooms": rooms.iter().map(|r| r.to_json()).collect::<Vec<_>>()}))
                }
                "add" => {
                    let room = ost::api::add_room_data(
                        &client,
                        &coords,
                        arg_str(&args, "name").unwrap_or(""),
                        &arg_arr(&args, "participants"),
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "room": room.to_json()}))
                }
                "get" => {
                    let room =
                        ost::api::get_room_data(&client, &coords).await.map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "room": room.to_json()}))
                }
                "update" => {
                    let room = ost::api::update_room_data(
                        &client,
                        &coords,
                        arg_str(&args, "name").unwrap_or(""),
                        &arg_arr(&args, "participants"),
                        args.get("restrict_chat_access").and_then(|v| v.as_bool()).unwrap_or(false),
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "room": room.to_json()}))
                }
                "delete" => {
                    ost::api::delete_room_data(&client, &coords, version).await.map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true}))
                }
                "delete-all" => {
                    ost::api::delete_all_rooms_data(&client, &coords, args.get("rooms_refs"), version)
                        .await
                        .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true}))
                }
                "assign" => {
                    let rooms = ost::api::bulk_assign_data(
                        &client,
                        &coords,
                        &arg_arr(&args, "rooms"),
                        total,
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "rooms": rooms.iter().map(|r| r.to_json()).collect::<Vec<_>>()}))
                }
                "open" => {
                    ost::api::open_rooms_data(
                        &client,
                        &coords,
                        &arg_arr(&args, "rooms"),
                        args.get("new_timer_flow").and_then(|v| v.as_bool()).unwrap_or(false),
                        total,
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true}))
                }
                "close" => {
                    ost::api::close_rooms_data(&client, &coords, &arg_arr(&args, "rooms"), total, version)
                        .await
                        .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true}))
                }
                "get-settings" => {
                    let s = ost::api::get_settings_data(&client, &coords).await.map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "settings": settings_to_json(&s)}))
                }
                "put-settings" => {
                    let s = ost::api::put_settings_data(
                        &client,
                        &coords,
                        args.get("settings").unwrap_or(&Value::Null),
                        version,
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "settings": settings_to_json(&s)}))
                }
                "assignees" => {
                    let q = ost::api::AssigneeQuery {
                        calendar_event_id: arg_str(&args, "calendar_event_id").map(|s| s.to_string()),
                        ical_uid: arg_str(&args, "ical_uid").map(|s| s.to_string()),
                        event_type: arg_str(&args, "event_type").map(|s| s.to_string()),
                        team_id: arg_str(&args, "team_id").map(|s| s.to_string()),
                        max_nest_level: arg_str(&args, "max_nest_level").map(|s| s.to_string()),
                        user_threshold: arg_str(&args, "user_threshold").map(|s| s.to_string()),
                    };
                    let list =
                        ost::api::assignees_data(&client, &coords, &q).await.map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true, "assignees": list.iter().map(|a| {
                        json!({"email": a.email, "mri": a.mri, "membership": a.membership})
                    }).collect::<Vec<_>>()}))
                }
                "announce" => {
                    ost::api::announce_data(
                        &client,
                        &coords,
                        &arg_strings(&args, "room_thread_ids"),
                        arg_str(&args, "message").unwrap_or(""),
                    )
                    .await
                    .map_err(|e| format!("{:#}", e))?;
                    Ok(json!({"ok": true}))
                }
                _ => Err(format!("unknown breakout op {:?}", op)),
            }
        })
    };
    match run() {
        Ok(v) => v.to_string(),
        Err(e) => err_json("breakout_call", e),
    }
}

/// Pure request preview (`op`, coords JSON, args JSON — see
/// [`breakout_request_json`]). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_breakout_request(
    op: *const c_char,
    coords: *const c_char,
    args: *const c_char,
) -> *mut c_char {
    let o = match cstr_to_string(op) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let c = match cstr_to_string(coords) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(args) {
        Ok(a) => string_to_c(breakout_request_json(&o, &c, &a)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Blocking executor (`op`, coords JSON, args JSON — see
/// [`breakout_call_json`]). Caller frees. Swift calls off-main.
#[no_mangle]
pub extern "C" fn ostmac_breakout_call(
    op: *const c_char,
    coords: *const c_char,
    args: *const c_char,
) -> *mut c_char {
    let o = match cstr_to_string(op) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let c = match cstr_to_string(coords) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(args) {
        Ok(a) => string_to_c(breakout_call_json(&o, &c, &a)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Pure coords encoder (coords JSON → `{ok, encoded}`). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_breakout_encode_coords(coords: *const c_char) -> *mut c_char {
    match cstr_to_string(coords) {
        Ok(c) => string_to_c(breakout_encode_coords_json(&c)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const COORDS: &str =
        r#"{"tenant_id":"t","organizer_id":"o","thread_id":"19:main@thread.v2","message_id":"1"}"#;
    const MT: &str = "https://mt.example/api/mt/amer";

    fn req(op: &str, args: &Value) -> Value {
        let out = breakout_request_json(op, COORDS, &args.to_string());
        serde_json::from_str(&out).unwrap()
    }

    #[test]
    fn op_set_is_the_mapped_14() {
        assert_eq!(
            op_names(),
            &[
                "list", "create", "add", "get", "update", "delete", "delete-all", "assign", "open",
                "close", "get-settings", "put-settings", "assignees", "announce",
            ]
        );
    }

    #[test]
    fn request_pins_every_op_method_and_path() {
        let mt = json!({"mt_base": MT});
        let c = "t/o/19_main@thread.v2/1";
        for (op, method, tail) in [
            ("list", "GET", format!("beta/breakoutRoom/bulk/{}", c)),
            ("create", "POST", format!("beta/breakoutRoom/{}", c)),
            ("add", "POST", format!("beta/breakoutRoom/add/{}", c)),
            ("get", "GET", format!("beta/breakoutRoom/details/{}", c)),
            ("update", "PUT", format!("beta/breakoutRoom/{}", c)),
            ("delete", "DELETE", format!("beta/breakoutRoom/{}", c)),
            ("delete-all", "DELETE", format!("beta/breakoutRoom/rooms/all/{}", c)),
            ("assign", "PUT", format!("beta/breakoutRoom/bulk/{}", c)),
            ("open", "POST", format!("beta/breakoutRoom/open/{}", c)),
            ("close", "POST", format!("beta/breakoutRoom/close/{}", c)),
            ("get-settings", "GET", format!("beta/breakoutRoom/settings/{}", c)),
            ("put-settings", "PUT", format!("beta/breakoutRoom/settings/{}", c)),
            ("assignees", "GET", format!("beta/breakoutRoom/assignees/{}?", c)),
            ("announce", "POST", format!("beta/breakoutRoom/announce/{}", c)),
        ] {
            let r = req(op, &mt);
            assert_eq!(r["ok"], true, "op {}", op);
            assert_eq!(r["method"], method, "op {}", op);
            assert_eq!(r["url"], format!("{}/{}", MT, tail), "op {}", op);
        }
        // v2 bulk when the total is known; version suffix on writes.
        let v2 = req("assign", &json!({"mt_base": MT, "total_participants": 9, "rooms": []}));
        assert!(v2["url"].as_str().unwrap().contains("bulk/v2/"));
        assert_eq!(v2["body"]["totalParticipantCount"], 9);
        let ver = req("open", &json!({"mt_base": MT, "version": "2", "rooms": []}));
        assert!(ver["url"].as_str().unwrap().ends_with("?newVersion=2"));
        // Reads and announce never take the version.
        let get = req("get-settings", &json!({"mt_base": MT, "version": "2"}));
        assert!(!get["url"].as_str().unwrap().contains('?'));
        let ann = req("announce", &json!({"mt_base": MT, "version": "2"}));
        assert!(!ann["url"].as_str().unwrap().contains('?'));
    }

    #[test]
    fn request_pins_write_bodies() {
        let mt = json!({"mt_base": MT});
        let create = req("create", &json!({"mt_base": MT, "count": 3, "preconfiguration": []}));
        assert_eq!(create["body"]["breakoutRoomConfigurations"]["roomCount"], 3);
        let add = req("add", &json!({"mt_base": MT, "name": "N", "participants": []}));
        assert_eq!(add["body"], json!({"name": "N", "participants": []}));
        let update = req(
            "update",
            &json!({"mt_base": MT, "name": "R", "participants": [], "restrict_chat_access": true}),
        );
        assert_eq!(update["body"]["restrictChatAccess"], true);
        let open = req("open", &json!({"mt_base": MT, "rooms": [], "new_timer_flow": true}));
        assert_eq!(open["body"]["useNewTimerFlow"], true);
        let put = req("put-settings", &json!({"mt_base": MT, "settings": {"room_duration": "PT5M"}}));
        assert_eq!(put["body"]["roomDuration"], "PT5M");
        assert_eq!(put["body"]["extensionData"], json!({}));
        let ann = req(
            "announce",
            &json!({"mt_base": MT, "room_thread_ids": ["19:r"], "message": "Back soon"}),
        );
        assert_eq!(ann["body"], json!({"roomThreadIds": ["19:r"], "message": "Back soon"}));
        // Bodyless ops carry explicit null.
        assert!(req("list", &mt)["body"].is_null());
        assert!(req("delete", &mt)["body"].is_null());
        assert!(req("get-settings", &mt)["body"].is_null());
    }

    #[test]
    fn request_defaults_to_the_mapped_fallback_base() {
        let r = req("list", &json!({}));
        assert!(r["url"].as_str().unwrap().starts_with(ost::api::BREAKOUT_FALLBACK_MT));
    }

    #[test]
    fn encode_coords_pins_the_path_segment() {
        let v: Value = serde_json::from_str(&breakout_encode_coords_json(COORDS)).unwrap();
        assert_eq!(v, json!({"ok": true, "encoded": "t/o/19_main@thread.v2/1"}));
        let bad: Value = serde_json::from_str(&breakout_encode_coords_json(r#"{"thread_id":"x"}"#)).unwrap();
        assert_eq!(bad["ok"], false);
    }

    #[test]
    fn request_rejects_unknown_ops_and_bad_input_before_network() {
        let unknown: Value = serde_json::from_str(&breakout_request_json("nuke", COORDS, "{}")).unwrap();
        assert_eq!(unknown["ok"], false);
        assert_eq!(unknown["error"], "arg");
        let bad_coords: Value = serde_json::from_str(&breakout_request_json("list", "nope", "{}")).unwrap();
        assert_eq!(bad_coords["ok"], false);
        let bad_args: Value = serde_json::from_str(&breakout_request_json("list", COORDS, "nope")).unwrap();
        assert_eq!(bad_args["ok"], false);
        // The executor validates the same way before touching the network.
        let call_bad: Value = serde_json::from_str(&breakout_call_json("nope", COORDS, "{}")).unwrap();
        assert_eq!(call_bad["ok"], false);
        let call_coords: Value = serde_json::from_str(&breakout_call_json("list", "nope", "{}")).unwrap();
        assert_eq!(call_coords["ok"], false);
    }

    #[test]
    fn ffi_null_is_arg_error() {
        let out = ostmac_breakout_request(std::ptr::null(), std::ptr::null(), std::ptr::null());
        let s = unsafe { std::ffi::CStr::from_ptr(out).to_string_lossy().into_owned() };
        crate::ostmac_free(out);
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
        let enc = ostmac_breakout_encode_coords(std::ptr::null());
        let s2 = unsafe { std::ffi::CStr::from_ptr(enc).to_string_lossy().into_owned() };
        crate::ostmac_free(enc);
        let v2: serde_json::Value = serde_json::from_str(&s2).unwrap();
        assert_eq!(v2["ok"], false);
    }
}
