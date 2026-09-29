//! Meeting transcripts over FFI — list + search windows.
//!
//! Om-transcripts-build lane. JSON envelopes mirror the recordings
//! lane: `{ok,transcripts:[...]}` and `{ok,query,transcripts:[...]}`.
//! Rows reuse the recordings projection minus the video facet (no
//! `duration_ms`, no `download_url`): VTT bytes download via the
//! existing files download (`drive_id` + `id`), and cue parsing is
//! pure Swift (`TranscriptsParser.swift`).

use std::os::raw::{c_char, c_int};

use serde_json::json;

use crate::{cstr_to_string, err_json, rt, string_to_c};

fn transcript_to_json(t: &ost::api::TranscriptInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "name": t.name,
        "size": t.size,
        "mime": t.mime,
        "web_url": t.web_url,
        "drive_id": t.drive_id,
        "created": t.created,
        "modified": t.modified,
        "source": t.source.label(),
    })
}

/// Every meeting transcript as JSON (OneDrive + channel `Recordings`
/// folders, newest first). Requires sign-in; unsigned yields
/// `{ok:false}`. `limit<=0` means the 100-row window.
pub fn transcripts_list_json(limit: usize) -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let rows = ost::api::list_transcripts_data(&client, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = rows.iter().map(transcript_to_json).collect();
            Ok(json!({"ok": true, "transcripts": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("transcripts_list", e),
    }
}

/// One transcripts search window as JSON. Empty queries are rejected
/// before any network. `limit<=0` means the 100-row window.
pub fn transcripts_search_json(query: &str, limit: usize) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let rows = ost::api::search_transcripts_data(&client, query, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = rows.iter().map(transcript_to_json).collect();
            Ok(json!({"ok": true, "query": query, "transcripts": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("transcripts_search", e),
    }
}

// ---------------------------------------------------------------------------
// C ABI. Caller frees every return with `ostmac_free`.
// ---------------------------------------------------------------------------

/// Every transcript, newest first (requires sign-in).
/// See [`transcripts_list_json`].
#[no_mangle]
pub extern "C" fn ostmac_transcripts_list(limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 {
        ost::api::TRANSCRIPTS_MAX_LIMIT
    } else {
        limit as usize
    };
    string_to_c(transcripts_list_json(lim))
}

/// One transcripts search window (requires sign-in).
/// See [`transcripts_search_json`].
#[no_mangle]
pub extern "C" fn ostmac_transcripts_search(
    query: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 {
        ost::api::TRANSCRIPTS_MAX_LIMIT
    } else {
        limit as usize
    };
    match cstr_to_string(query) {
        Ok(q) => string_to_c(transcripts_search_json(&q, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

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
                serde_json::from_str(&transcripts_search_json(q, 10)).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_null_query_is_arg_error() {
        unsafe {
            let v = read_and_free(ostmac_transcripts_search(std::ptr::null(), 10));
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn converter_shapes_wire_json() {
        let t = ost::api::TranscriptInfo {
            id: "t1".into(),
            name: "Weekly Sync-20260924.vtt".into(),
            size: 4211,
            mime: Some("text/vtt".into()),
            web_url: Some("https://x/t1".into()),
            drive_id: Some("d1".into()),
            created: Some("2026-09-24T09:00:00Z".into()),
            modified: Some("2026-09-24T10:00:00Z".into()),
            source: ost::api::TranscriptSource::Channel {
                team: "Engineering".into(),
                channel: "general".into(),
            },
        };
        let v = transcript_to_json(&t);
        assert_eq!(v["id"], "t1");
        assert_eq!(v["name"], "Weekly Sync-20260924.vtt");
        assert_eq!(v["source"], "Engineering > #general");
        assert!(v.get("duration_ms").is_none());
        assert!(v.get("download_url").is_none());
    }
}
