//! Meetings-plus FFI: attendance reports + server capture options.
//!
//! Thin JSON-over-C wrappers around `ost::api::meetings_plus` (pure
//! builders/parsers live there, pinned by its tests). Every failed read
//! returns `{ok:false}` with the status in `detail` (a scope 403 reads
//! the same), never an empty success — Swift shows the live-disabled
//! reason. Blocking FFI + network: Swift calls these off the main thread.

use std::os::raw::c_char;

use serde_json::json;

use crate::{cstr_to_string, err_json, rt, string_to_c};

fn entry_to_json(e: &ost::api::AttendanceEntry) -> serde_json::Value {
    json!({
        "display_name": e.display_name,
        "role": e.role,
        "join_dt": e.join_dt,
        "leave_dt": e.leave_dt,
        "duration_secs": e.duration_secs,
    })
}

fn options_to_json(o: &ost::api::CaptureOptions) -> serde_json::Value {
    json!({
        "allow_recording": o.allow_recording,
        "allow_transcription": o.allow_transcription,
        "record_automatically": o.record_automatically,
    })
}

/// One meeting's attendance (first report's records):
/// `{ok:true, entries:[…]}` or `{ok:false}`. Blank ids rejected
/// before any network.
pub fn meeting_attendance_json(meeting_id: &str) -> String {
    if meeting_id.trim().is_empty() {
        return err_json("arg", "empty meeting id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let entries = ost::api::meeting_attendance_data(&client, meeting_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let rows: Vec<_> = entries.iter().map(entry_to_json).collect();
            Ok(json!({"ok": true, "entries": rows}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("meeting_attendance", e),
    }
}

/// One meeting's server capture toggles: `{ok:true, options:{…}}` or
/// `{ok:false}`. Blank ids rejected before any network.
pub fn meeting_capture_get_json(meeting_id: &str) -> String {
    if meeting_id.trim().is_empty() {
        return err_json("arg", "empty meeting id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let opts = ost::api::meeting_capture_options_data(&client, meeting_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "options": options_to_json(&opts)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("meeting_capture_get", e),
    }
}

/// Write one meeting's server capture toggles. `body` is JSON naming any
/// of `allowRecording`, `allowTranscription`, `recordAutomatically`
/// (booleans; at least one required). Returns `{ok:true, options:{…}}`
/// (the read-back) or `{ok:false}`.
pub fn meeting_capture_set_json(meeting_id: &str, body: &str) -> String {
    if meeting_id.trim().is_empty() {
        return err_json("arg", "empty meeting id");
    }
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return err_json("arg", format!("bad body: {}", e)),
    };
    let b = |k: &str| v.get(k).and_then(|x| x.as_bool());
    let opts = ost::api::CaptureOptions {
        allow_recording: b("allowRecording"),
        allow_transcription: b("allowTranscription"),
        record_automatically: b("recordAutomatically"),
    };
    if opts == ost::api::CaptureOptions::default() {
        return err_json("arg", "no capture option set (nothing to write)");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let back = ost::api::set_meeting_capture_options_data(&client, meeting_id, &opts)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "options": options_to_json(&back)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("meeting_capture_set", e),
    }
}

/// Attendance for one meeting: `{ok,entries}` or `{ok:false}`. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_meeting_attendance(meeting_id: *const c_char) -> *mut c_char {
    match cstr_to_string(meeting_id) {
        Ok(id) => string_to_c(meeting_attendance_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Server capture toggles for one meeting: `{ok,options}` or `{ok:false}`.
/// Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_meeting_capture_get(meeting_id: *const c_char) -> *mut c_char {
    match cstr_to_string(meeting_id) {
        Ok(id) => string_to_c(meeting_capture_get_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Write server capture toggles (`body` JSON, see [`meeting_capture_set_json`]).
/// Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_meeting_capture_set(
    meeting_id: *const c_char,
    body: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(meeting_id) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(body) {
        Ok(b) => string_to_c(meeting_capture_set_json(&id, &b)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_ids_are_arg_errors_before_network() {
        for out in [
            meeting_attendance_json("  "),
            meeting_capture_get_json(""),
            meeting_capture_set_json("", r#"{"allowRecording":true}"#),
        ] {
            let v: serde_json::Value = serde_json::from_str(&out).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn set_rejects_bad_body_and_empty_change() {
        let bad: serde_json::Value =
            serde_json::from_str(&meeting_capture_set_json("M1", "not json")).unwrap();
        assert_eq!(bad["ok"], false);
        let empty: serde_json::Value =
            serde_json::from_str(&meeting_capture_set_json("M1", r#"{"subject":"x"}"#)).unwrap();
        assert_eq!(empty["ok"], false);
        assert_eq!(empty["error"], "arg");
    }

    #[test]
    fn entry_and_options_shapes_pin_swift_contract() {
        let e = ost::api::AttendanceEntry {
            display_name: "Ava Stone".to_string(),
            role: "presenter".to_string(),
            join_dt: Some("2026-11-19T14:00:00Z".to_string()),
            leave_dt: None,
            duration_secs: 1845,
        };
        let j = entry_to_json(&e);
        assert_eq!(j["display_name"], "Ava Stone");
        assert_eq!(j["duration_secs"], 1845);
        assert!(j["leave_dt"].is_null());
        let o = ost::api::CaptureOptions {
            allow_recording: Some(true),
            allow_transcription: None,
            record_automatically: Some(false),
        };
        let k = options_to_json(&o);
        assert_eq!(k["allow_recording"], true);
        assert!(k["allow_transcription"].is_null());
    }

    #[test]
    fn ffi_null_is_arg_error() {
        let out = ostmac_meeting_attendance(std::ptr::null());
        let s = unsafe { std::ffi::CStr::from_ptr(out).to_string_lossy().into_owned() };
        crate::ostmac_free(out);
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
    }
}
