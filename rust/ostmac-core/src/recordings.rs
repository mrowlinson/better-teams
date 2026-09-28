//! Meeting recordings over FFI — list + search windows.
//!
//! Om-recordings lane. JSON envelopes mirror the om-jb-filesearch
//! lane: `{ok,recordings:[...]}` and `{ok,query,recordings:[...]}`.
//! Rows reuse the Shared tab projection plus `duration_ms` (the
//! driveItem `video` facet) and `source` (OneDrive vs channel label),
//! so playback resolves exactly like a shared file: stream the
//! pre-authenticated `download_url`, else `ostmac_files_download`
//! via `drive_id` + `id`.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

use serde_json::json;

use crate::{cstr_to_string, err_json, rt, string_to_c};

fn recording_to_json(r: &ost::api::RecordingInfo) -> serde_json::Value {
    json!({
        "id": r.id,
        "name": r.name,
        "size": r.size,
        "mime": r.mime,
        "web_url": r.web_url,
        "download_url": r.download_url,
        "drive_id": r.drive_id,
        "created": r.created,
        "modified": r.modified,
        "duration_ms": r.duration_ms,
        "source": r.source.label(),
    })
}

/// Every meeting recording as JSON (OneDrive + channel `Recordings`
/// folders, newest first). Requires sign-in; unsigned yields
/// `{ok:false}`. `limit<=0` means the 50-row window.
pub fn recordings_list_json(limit: usize) -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let rows = ost::api::list_recordings_data(&client, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = rows.iter().map(recording_to_json).collect();
            Ok(json!({"ok": true, "recordings": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("recordings_list", e),
    }
}

/// One recordings search window as JSON. Empty queries are rejected
/// before any network. `limit<=0` means the 50-row window.
pub fn recordings_search_json(query: &str, limit: usize) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let rows = ost::api::search_recordings_data(&client, query, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = rows.iter().map(recording_to_json).collect();
            Ok(json!({"ok": true, "query": query, "recordings": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("recordings_search", e),
    }
}

// ---------------------------------------------------------------------------
// C ABI. Caller frees every return with `ostmac_free`.
// ---------------------------------------------------------------------------

/// Every recording, newest first (requires sign-in).
/// See [`recordings_list_json`].
#[no_mangle]
pub extern "C" fn ostmac_recordings_list(limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 {
        ost::api::RECORDINGS_MAX_LIMIT
    } else {
        limit as usize
    };
    string_to_c(recordings_list_json(lim))
}

/// One recordings search window (requires sign-in).
/// See [`recordings_search_json`].
#[no_mangle]
pub extern "C" fn ostmac_recordings_search(
    query: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 {
        ost::api::RECORDINGS_MAX_LIMIT
    } else {
        limit as usize
    };
    match cstr_to_string(query) {
        Ok(q) => string_to_c(recordings_search_json(&q, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// Read an FFI string return back into JSON, then free it.
    unsafe fn read_and_free(p: *mut c_char) -> serde_json::Value {
        assert!(!p.is_null());
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        crate::ostmac_free(p);
        serde_json::from_str(&s).unwrap()
    }

    #[test]
    fn search_rejects_empty_query_before_network() {
        for q in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&recordings_search_json(q, 10)).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_null_query_is_arg_error() {
        unsafe {
            let v = read_and_free(ostmac_recordings_search(std::ptr::null(), 10));
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn converter_shapes_wire_json() {
        let r = ost::api::RecordingInfo {
            id: "r1".into(),
            name: "Weekly Sync-20260924.mp4".into(),
            size: 48211,
            mime: Some("video/mp4".into()),
            web_url: Some("https://x/r1".into()),
            download_url: Some("https://x/dl1".into()),
            drive_id: Some("d1".into()),
            created: Some("2026-09-24T09:00:00Z".into()),
            modified: Some("2026-09-24T10:00:00Z".into()),
            duration_ms: Some(3723000),
            source: ost::api::RecordingSource::Channel {
                team: "Engineering".into(),
                channel: "general".into(),
            },
        };
        let v = recording_to_json(&r);
        assert_eq!(v["id"], "r1");
        assert_eq!(v["duration_ms"], 3723000);
        assert_eq!(v["download_url"], "https://x/dl1");
        assert_eq!(v["source"], "Engineering > #general");
    }
}
