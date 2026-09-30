//! RECAP2: one meeting's recap, read the way Teams reads it.
//!
//! Mined from the Teams web client (tmp/recap2/mine.md, PROVEN unless
//! noted): the Recap tab asks the meeting-artifacts service (MCPS
//! "collab object") for the meeting's resources (Recording, TranscriptV2,
//! Notes, …), reads the transcript from the recording's SharePoint media
//! transcripts, and the AI notes from Substrate `MeetingCatchUp`. The
//! meeting chat's `RichText/Media_CallRecording` messages (organizer's
//! file uri + driveId + driveItemId) are Teams' own fallback. The old
//! Recap tab only listed the signed-in user's `Recordings` folders, so a
//! meeting someone else recorded never matched.
//!
//! Reads (GET, plus the Substrate query POST Teams itself sends):
//! - sources: chat history walk (≤ `SOURCE_MAX_PAGES`); the meeting
//!   identity from the call's transcript message (keys PROVEN) and the
//!   thread properties (`meeting` iCalUid/organizer — key names INFERRED);
//!   then MCPS `readcollabobject/{me}@{tid}/{organizer}@{tid}/{iCalUid}`
//!   (argument order INFERRED-high), token audience `MCPS_RESOURCE`, at
//!   most one read per distinct identity (two);
//! - recording: Graph driveItem by drive/item id (or `/shares/u!…` by
//!   address; Files.ReadWrite.All granted) → pre-authenticated stream URL;
//! - transcript: SharePoint `_api/v2.0/drives/{d}/items/{i}/media/transcripts`
//!   then `…/{id}/streamContent?format=json` (SharePoint token);
//! - notes: the Loop page service's HTML snapshot of the notes file
//!   (`POST {LOOP_API}/pages/{b64(host,drive,item)}`, token audience
//!   `LOOP_RESOURCE`, both PROVEN), shown read-only;
//! - AI notes: Substrate `search/api/v1/recommendations` by thread.
//! Every failed read returns `{ok:false}` (never an empty success).

use std::os::raw::c_char;

use base64::Engine;
use serde_json::{json, Value};

use crate::{cstr_to_string, err_json, rt, string_to_c};

/// Chat history pages read per meeting (200 messages each).
pub const SOURCE_MAX_PAGES: usize = 8;
pub const SOURCE_PAGE_SIZE: usize = 200;
/// Per-message content cap handed to Swift (recording XML is ~2-6 KB).
pub const CONTENT_CAP: usize = 32 * 1024;
/// Meeting-artifacts service (MCPS collab object) and its token audience.
pub const MCPS_COLLAB: &str = "https://teams.microsoft.com/api/mcps/prod/collab";
pub const MCPS_RESOURCE: &str = "6bc3b958-689b-49f5-9006-36d165f30e00";
/// Substrate MeetingCatchUp (intelligent recap AI notes).
pub const CATCHUP_URL: &str =
    "https://substrate.office.com/search/api/v1/recommendations?&setflight=AiTasksV3,AiNotesV3,PeopleMentionsV2";
pub const SUBSTRATE_RESOURCE: &str = "https://substrate.office.com";
/// Loop page service (meeting notes content snapshot) and its token
/// audience (PROVEN: `loopServiceEndpoint`, default `loopWebServiceResource`).
pub const LOOP_API: &str = "https://prod.api.loop.cloud.microsoft/v0.1";
pub const LOOP_RESOURCE: &str = "https://api.loop.cloud.microsoft/";
/// Notes HTML handed to Swift.
pub const NOTES_CAP: usize = 512 * 1024;

/// Meeting identity from the chat's thread properties. Pure.
/// `meeting` is a JSON string (iCalUid, organizerId, tenantId — names
/// INFERRED); `meetingObjectsConfig.configurations.transcriptConfig`
/// carries `organizerId` (PROVEN) as a fallback.
pub fn meeting_info(thread: &Value) -> Value {
    // The chat service answers `GET /v1/threads/{id}` with `properties`
    // (PROVEN by the RECAP_FIELDS_LIVE probe: no `threadProperties` key).
    let props = if thread["threadProperties"].is_object() { &thread["threadProperties"] } else { &thread["properties"] };
    let parse = |v: &Value| -> Value {
        match v {
            Value::String(s) => serde_json::from_str(s).unwrap_or(Value::Null),
            Value::Object(_) => v.clone(),
            _ => Value::Null,
        }
    };
    let meeting = parse(&props["meeting"]);
    let objects = parse(&props["meetingObjectsConfig"]);
    let metadata = parse(&props["meetingMetadata"]);
    let pick = |v: &Value, keys: &[&str]| -> Option<String> {
        keys.iter().find_map(|k| v[*k].as_str().filter(|s| !s.trim().is_empty()).map(str::to_string))
    };
    let ical = pick(&meeting, &["iCalUid", "iCalUID", "icalUid", "ICalUid"]);
    let organizer = pick(&meeting, &["organizerId", "organizerOid"])
        .or_else(|| pick(&objects["configurations"]["transcriptConfig"], &["organizerId"]));
    let tenant = pick(&meeting, &["tenantId", "organizerTenantId"]);
    let has_recap = match &metadata["hasRecap"] {
        Value::Bool(b) => Some(*b),
        Value::String(s) => Some(s == "true"),
        _ => None,
    };
    json!({"ical_uid": ical, "organizer_id": organizer, "tenant_id": tenant, "has_recap": has_recap})
}

/// Meeting identity from the chat's `RichText/Media_CallTranscript`
/// messages (content JSON keys `iCalUid`, `meetingOrganizerId`,
/// `meetingTenantId` PROVEN), newest message first. Pure.
pub fn meeting_info_from_messages(kept: &[Value]) -> Value {
    let mut rows: Vec<&Value> = kept
        .iter()
        .filter(|m| m["messagetype"].as_str().unwrap_or("").to_ascii_lowercase().contains("media_calltranscript"))
        .collect();
    rows.sort_by(|a, b| b["composetime"].as_str().unwrap_or("").cmp(a["composetime"].as_str().unwrap_or("")));
    for m in rows {
        let raw = m["content"]
            .as_str()
            .unwrap_or("")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&amp;", "&");
        // Live content does not always parse as JSON (probe: 6/6 did not),
        // so the keys are also read straight from the text.
        let v = serde_json::from_str::<Value>(raw.trim()).unwrap_or(Value::Null);
        let pick = |k: &str| {
            v[k].as_str()
                .map(str::to_string)
                .or_else(|| json_text_value(&raw, k))
                .filter(|s| !s.trim().is_empty())
        };
        if let (Some(ical), Some(org)) = (pick("iCalUid"), pick("meetingOrganizerId")) {
            return json!({"ical_uid": ical, "organizer_id": bare_oid(&org), "tenant_id": pick("meetingTenantId"),
                          "has_recap": Value::Null});
        }
    }
    Value::Null
}

/// `"key":"value"` read from text that is not valid JSON (first match). Pure.
pub fn json_text_value(text: &str, key: &str) -> Option<String> {
    let quote = |r: &str| -> Option<usize> {
        let r2 = r.strip_prefix('\\').unwrap_or(r);
        r2.strip_prefix('"').map(|_| r.len() - r2.len() + 1)
    };
    let mut from = 0;
    while let Some(i) = text[from..].find(key) {
        let at = from + i;
        from = at + key.len();
        // Preceded by a quote (plain or escaped) and followed by one.
        if !text[..at].ends_with('"') {
            continue;
        }
        let rest = &text[from..];
        let Some(q) = quote(rest) else { continue };
        let Some(rest) = rest[q..].trim_start().strip_prefix(':') else { continue };
        let rest = rest.trim_start();
        let Some(q) = quote(rest) else { continue };
        let rest = &rest[q..];
        let end = rest.find(|c| c == '"' || c == '\\')?;
        return Some(rest[..end].to_string());
    }
    None
}

/// Object id from an MRI (`8:orgid:{oid}`) or a bare id. Pure.
pub fn bare_oid(s: &str) -> String {
    s.trim().rsplit(':').next().unwrap_or("").to_string()
}

/// `<Name value="…"/>` attribute (or the element text) of the first
/// `Name` element in recording XML (Teams reads the `value` attribute). Pure.
pub fn xml_value(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{}", name);
    let mut from = 0;
    while let Some(i) = xml[from..].find(&open) {
        let start = from + i + open.len();
        from = start;
        let next = xml[start..].chars().next()?;
        if !(next.is_whitespace() || next == '/' || next == '>') {
            continue;
        }
        let end = start + xml[start..].find('>')?;
        let tag = &xml[start..end];
        for attr in [" value=\"", " v=\""] {
            if let Some(a) = tag.find(attr) {
                let v = &tag[a + attr.len()..];
                let v = &v[..v.find('"').unwrap_or(v.len())];
                return Some(v.replace("&amp;", "&")).filter(|s| !s.trim().is_empty());
            }
        }
        if tag.ends_with('/') {
            return None;
        }
        let close = format!("</{}>", name);
        let body = &xml[end + 1..];
        let text = &body[..body.find(&close)?];
        return Some(text.trim().replace("&amp;", "&")).filter(|s| !s.is_empty() && !s.contains('<'));
    }
    None
}

/// Meeting identities from the newest `RichText/Media_CallRecording`
/// message's XML (`MeetingOrganizerId`, `MeetingOrganizerTenantId`,
/// `InstanceICalUid`, `ICalUid`, `MeetingICalUid` — element names PROVEN by
/// the RECAP_FIELDS_LIVE probe; `value` attribute per the Teams web
/// client). Occurrence first, then the meeting's. Pure.
pub fn meeting_infos_from_recordings(kept: &[Value]) -> Vec<Value> {
    let mut rows: Vec<&Value> = kept
        .iter()
        .filter(|m| m["messagetype"].as_str().unwrap_or("").to_ascii_lowercase().contains("media_callrecording"))
        .collect();
    rows.sort_by(|a, b| b["composetime"].as_str().unwrap_or("").cmp(a["composetime"].as_str().unwrap_or("")));
    for m in rows {
        let xml = m["content"].as_str().unwrap_or("").replace("&quot;", "\"").replace("&lt;", "<").replace("&gt;", ">");
        let Some(org) = xml_value(&xml, "MeetingOrganizerId").map(|o| bare_oid(&o)).filter(|o| !o.is_empty()) else { continue };
        let tenant = xml_value(&xml, "MeetingOrganizerTenantId");
        let mut out: Vec<Value> = Vec::new();
        for k in ["InstanceICalUid", "ICalUid", "MeetingICalUid"] {
            if let Some(ical) = xml_value(&xml, k) {
                if !out.iter().any(|o| o["ical_uid"].as_str() == Some(ical.as_str())) {
                    out.push(json!({"ical_uid": ical, "organizer_id": org, "tenant_id": tenant, "has_recap": Value::Null}));
                }
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    Vec::new()
}

/// Meeting identities to try against the artifacts service, at most two,
/// distinct: the transcript message's (the call's own) first, then the
/// thread properties'. Pure.
pub fn meeting_candidates(from_messages: &Value, from_thread: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    for m in [from_messages, from_thread] {
        let (Some(ical), Some(org)) = (m["ical_uid"].as_str(), m["organizer_id"].as_str()) else { continue };
        if !out.iter().any(|o| o["ical_uid"].as_str() == Some(ical) && o["organizer_id"].as_str() == Some(org)) {
            out.push(m.clone());
        }
    }
    out
}

/// `oid`/`tid` claims of a JWT (never logged). Pure.
pub fn jwt_oid_tid(token: &str) -> Option<(String, String)> {
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    Some((v["oid"].as_str()?.to_string(), v["tid"].as_str()?.to_string()))
}

fn pct(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// MCPS collab-object read for one meeting.
pub fn collab_url(my_oid: &str, my_tid: &str, org_oid: &str, org_tid: &str, ical_uid: &str) -> String {
    format!(
        "{}/readcollabobject/{}@{}/{}@{}/{}",
        MCPS_COLLAB,
        pct(my_oid),
        pct(my_tid),
        pct(org_oid),
        pct(org_tid),
        pct(ical_uid)
    )
}

/// Collab-object resources the recap uses (Recording, TranscriptV2 /
/// Transcript, Notes), type lowercased. Pure.
pub fn collab_resources(v: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for r in v["resources"].as_array().into_iter().flatten() {
        let t = r["type"].as_str().unwrap_or("").to_ascii_lowercase();
        if !matches!(t.as_str(), "recording" | "transcriptv2" | "transcript" | "notes") {
            continue;
        }
        let m = &r["metadata"];
        out.push(json!({
            "type": t,
            "location": r["location"].as_str(),
            "drive_id": m["driveId"].as_str(),
            "drive_item_id": m["driveItemId"].as_str(),
            "web_url": m["webUrl"].as_str(),
            "file_title": m["fileTitle"].as_str(),
            "start_time": m["startTime"].as_str(),
        }));
    }
    out
}

/// Substrate MeetingCatchUp query by meeting thread (PROVEN body shape).
pub fn catchup_body(thread_id: &str, start: &str, end: &str) -> String {
    format!(
        r#"{{"EntityRequests":[{{"Filter":{{"Term":{{"MeetingThreadId":"{}"}}}},"QueryParameters":[{{"EntityType":"MeetingCatchUp","StartDateTime":"{}","EndDateTime":"{}","Top":5}}]}}],"Scenario":{{"Name":"MeetingCatchUp.MeetingRecap.Chiclet"}}}}"#,
        thread_id.replace('"', ""),
        start,
        end
    )
}

/// Known "not processed" statuses → the reason shown (PROVEN enum names).
pub fn catchup_reason(status: &str) -> Option<&'static str> {
    Some(match status {
        "NotProcessedMissingLicense" => "Intelligent recap needs a Teams Premium or Microsoft 365 Copilot license.",
        "NotProcessedMissingTranscript" => "Intelligent recap needs the meeting to be transcribed.",
        "NotProcessedTranscriptTooShort" => "The transcript is too short for an intelligent recap.",
        "NotProcessedNonEnglishTranscript" => "Intelligent recap isn\u{2019}t available for this transcript\u{2019}s language.",
        "NotProcessedFeatureNotAvailable" => "Intelligent recap isn\u{2019}t available in your organization.",
        "NoRecording" => "Intelligent recap needs the meeting to be recorded.",
        "NoPermission" => "You don\u{2019}t have permission to see this meeting\u{2019}s intelligent recap.",
        "InProgress" => "The intelligent recap isn\u{2019}t ready yet.",
        _ => return None,
    })
}

fn texts(v: &Value, out: &mut Vec<String>, depth: usize) {
    if depth > 6 || out.len() >= 40 {
        return;
    }
    match v {
        Value::String(s) => {
            let t = s.trim();
            if t.len() > 3 && t.contains(' ') && !t.starts_with("http") {
                out.push(t.to_string());
            }
        }
        Value::Array(a) => a.iter().for_each(|x| texts(x, out, depth + 1)),
        Value::Object(o) => {
            for k in ["Title", "Text", "Content", "Summary", "Description", "title", "text", "content"] {
                if let Some(x) = o.get(k) {
                    texts(x, out, depth + 1);
                }
            }
            for (k, x) in o {
                if matches!(x, Value::Array(_) | Value::Object(_))
                    && !["Title", "Text", "Content", "Summary", "Description"].contains(&k.as_str())
                {
                    texts(x, out, depth + 1);
                }
            }
        }
        _ => {}
    }
}

fn find_status(v: &Value, depth: usize) -> Option<String> {
    if depth > 6 {
        return None;
    }
    match v {
        Value::String(s) if catchup_reason(s).is_some() => Some(s.clone()),
        Value::Array(a) => a.iter().find_map(|x| find_status(x, depth + 1)),
        Value::Object(o) => o.values().find_map(|x| find_status(x, depth + 1)),
        _ => None,
    }
}

/// MeetingCatchUp answer → `{ok, available, notes, follow_ups, reason}`.
/// Pure. Summary texts from `MeetingSummary`, tasks from
/// `PointsOfInterest` (inner shapes INFERRED: text fields collected).
pub fn catchup_answer(v: &Value) -> Value {
    let results = v["EntitySets"][0]["ResultSets"][0]["Results"].as_array().cloned().unwrap_or_default();
    let mut notes = Vec::new();
    let mut follow = Vec::new();
    let mut status = None;
    for r in &results {
        let src = &r["Source"];
        texts(&src["MeetingSummary"], &mut notes, 0);
        texts(&src["PointsOfInterest"], &mut follow, 0);
        status = status.or_else(|| find_status(src, 0));
        if !notes.is_empty() || !follow.is_empty() {
            break;
        }
    }
    notes.dedup();
    follow.dedup();
    let available = !notes.is_empty() || !follow.is_empty();
    json!({
        "ok": true,
        "available": available,
        "notes": notes,
        "follow_ups": follow,
        "reason": if available { None } else { status.as_deref().and_then(catchup_reason) },
    })
}

/// A message the recap reads: the recording/transcript messages, or any
/// message linking a Loop notes page. Pure (tests pin it).
pub fn recap_message_kept(messagetype: &str, content: &str) -> bool {
    let t = messagetype.to_ascii_lowercase();
    if t.contains("media_callrecording") || t.contains("media_calltranscript") {
        return true;
    }
    if !t.contains("text") {
        return false;
    }
    let c = content.to_ascii_lowercase();
    c.contains(".loop") || c.contains(".fluid") || c.contains("loop.cloud.microsoft")
}

/// Truncate at a char boundary.
fn cap(s: &str, n: usize) -> &str {
    if s.len() <= n {
        return s;
    }
    let mut i = n;
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    &s[..i]
}

/// Recap-bearing messages of one history page. Pure.
pub fn recap_messages_of_page(page: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for m in page["messages"].as_array().into_iter().flatten() {
        let t = m["messagetype"].as_str().unwrap_or("");
        let c = m["content"].as_str().unwrap_or("");
        if !recap_message_kept(t, c) {
            continue;
        }
        let id = m["id"].as_str().map(str::to_string).or_else(|| m["id"].as_i64().map(|v| v.to_string()));
        out.push(json!({
            "id": id.unwrap_or_default(),
            "messagetype": t,
            "content": cap(c, CONTENT_CAP),
            "composetime": m["composetime"].as_str().or(m["originalarrivaltime"].as_str()),
        }));
    }
    out
}

fn bad_id(s: &str) -> bool {
    s.is_empty() || s.contains(['/', '?', '#', ' '])
}

/// `https://host/...` → `host` (lowercased); None for non-https.
pub fn https_host(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    let host = rest.split(['/', '?', '#']).next()?.to_ascii_lowercase();
    if host.is_empty() || host.contains('@') {
        return None;
    }
    Some(host)
}

/// A SharePoint/OneDrive file address (the only hosts the recap reads).
pub fn is_sharepoint_url(url: &str) -> bool {
    https_host(url).map_or(false, |h| h.ends_with(".sharepoint.com"))
}

/// Graph share id for a file address: `u!` + unpadded base64url.
pub fn share_id(url: &str) -> String {
    let b = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(url.trim().as_bytes());
    format!("u!{}", b)
}

/// Graph path resolving a shared file address to its driveItem.
pub fn share_item_path(url: &str) -> String {
    format!("/shares/{}/driveItem", share_id(url))
}

/// SharePoint media transcripts list for a driveItem (PROVEN v2.0 path,
/// Teams' `fetchOdspMediaTranscripts`).
pub fn transcripts_url(host: &str, drive_id: &str, item_id: &str) -> String {
    format!(
        "https://{}/_api/v2.0/drives/{}/items/{}/media/transcripts",
        host, drive_id, item_id
    )
}

/// One transcript's content (Teams transcript JSON), in the form of the
/// artifacts service's TranscriptV2 location (PROVEN).
pub fn transcript_content_url(host: &str, drive_id: &str, item_id: &str, transcript_id: &str) -> String {
    format!(
        "https://{}/_api/v2.1/drives/{}/items/{}/versions/current/media/transcripts/{}/streamContent?format=json",
        host, drive_id, item_id, transcript_id
    )
}

/// Loop page content address for a stored notes file: standard base64 of
/// `host,driveId,driveItemId` (PROVEN `readPageContent`).
pub fn loop_page_url(host: &str, drive_id: &str, item_id: &str) -> String {
    let id = base64::engine::general_purpose::STANDARD.encode(format!("{},{},{}", host, drive_id, item_id));
    format!("{}/pages/{}", LOOP_API, id)
}

/// Loop page answer → notes HTML (`content`, PROVEN field). Pure.
pub fn loop_page_html(v: &Value) -> Option<String> {
    let c = v["content"].as_str()?;
    Some(cap(c, NOTES_CAP).to_string())
}

/// Transcript ids from a media transcripts answer, newest first. Pure.
pub fn transcript_ids(v: &Value) -> Vec<String> {
    let mut rows: Vec<(String, String)> = v["value"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|t| {
            let id = t["id"].as_str()?.to_string();
            let when = t["createdDateTime"].as_str().unwrap_or("").to_string();
            Some((when, id))
        })
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    rows.into_iter().map(|r| r.1).collect()
}

/// The organizer's recording as the app's recording row. Pure.
pub fn recording_row(item: &Value) -> Option<Value> {
    let rows = ost::api::parse_recordings_response(
        &json!({ "value": [item] }),
        ost::api::RecordingSource::OneDrive,
    );
    let r = rows.into_iter().next()?;
    Some(json!({
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
        "source": "Organizer\u{2019}s OneDrive",
    }))
}

async fn resolve_share(client: &ost::api::client::TeamsClient, url: &str) -> Result<Value, String> {
    let resp = client
        .graph_get(&share_item_path(url))
        .await
        .map_err(|e| format!("{:#}", e))?;
    resp.json::<Value>().await.map_err(|e| format!("bad driveItem: {}", e))
}

async fn drive_item(client: &ost::api::client::TeamsClient, drive_id: &str, item_id: &str) -> Result<Value, String> {
    if bad_id(drive_id) || bad_id(item_id) {
        return Err("bad drive or item id".into());
    }
    let resp = client
        .graph_get(&format!("/drives/{}/items/{}", drive_id, item_id))
        .await
        .map_err(|e| format!("{:#}", e))?;
    resp.json::<Value>().await.map_err(|e| format!("bad driveItem: {}", e))
}

async fn bearer(resource: &str) -> Result<String, String> {
    let profile = ost::config::active_profile();
    ost::auth::oauth::token_for_scope_for(&profile, &format!("{}/.default", resource.trim_end_matches('/')))
        .await
        .map(|g| g.access_token)
        .map_err(|e| format!("{:#}", e))
}

fn status_err(status: reqwest::StatusCode, what: &str) -> String {
    if status == reqwest::StatusCode::UNAUTHORIZED {
        format!("401 Unauthorized ({})", what)
    } else {
        format!("HTTP {} ({})", status.as_u16(), what)
    }
}

async fn bearer_get(resource: &str, url: &str, what: &str) -> Result<Value, String> {
    let token = bearer(resource).await?;
    let resp = ost::api::client::shared_http()
        .get(url)
        .bearer_auth(&token)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json;charset=UTF-8")
        .send()
        .await
        .map_err(|e| format!("{} request failed: {}", what, e))?;
    if !resp.status().is_success() {
        return Err(status_err(resp.status(), what));
    }
    resp.json::<Value>().await.map_err(|e| format!("bad {} answer: {}", what, e))
}

/// A file the recap reads: address and/or drive + item ids, or a full
/// transcript content address (`location`, MCPS TranscriptV2).
#[derive(Debug, Default, serde::Deserialize)]
pub struct FileTarget {
    #[serde(default)]
    pub file_url: Option<String>,
    #[serde(default)]
    pub drive_id: Option<String>,
    #[serde(default)]
    pub item_id: Option<String>,
    #[serde(default)]
    pub location: Option<String>,
}

impl FileTarget {
    pub fn parse(raw: &str) -> Result<FileTarget, String> {
        let t: FileTarget = serde_json::from_str(raw).map_err(|e| format!("bad target: {}", e))?;
        let ok = |s: &Option<String>| s.as_deref().map_or(true, |u| is_sharepoint_url(u));
        if !ok(&t.file_url) || !ok(&t.location) {
            return Err("not a SharePoint file address".into());
        }
        if t.file_url.is_none() && t.location.is_none() && (t.drive_id.is_none() || t.item_id.is_none()) {
            return Err("no file address".into());
        }
        Ok(t)
    }

    fn host(&self) -> Option<String> {
        self.location.as_deref().or(self.file_url.as_deref()).and_then(https_host)
    }

    fn ids(&self) -> Option<(String, String)> {
        Some((self.drive_id.clone().filter(|s| !s.is_empty())?, self.item_id.clone().filter(|s| !s.is_empty())?))
    }
}

async fn resolve_target(client: &ost::api::client::TeamsClient, t: &FileTarget) -> Result<Value, String> {
    match (t.ids(), t.file_url.as_deref()) {
        (Some((d, i)), _) => drive_item(client, &d, &i).await,
        (None, Some(u)) => resolve_share(client, u).await,
        _ => Err("no file address".into()),
    }
}

/// `{ok, messages, pages, complete, meeting, collab}`: recap-bearing chat
/// messages, the meeting identity, and the MCPS collab resources
/// (`collab` = `{ok:true,resources}` | `{ok:false,error}` | null when the
/// chat names no meeting identity).
pub fn recap_sources_json(thread_id: &str) -> String {
    let thread = thread_id.trim();
    if bad_id(thread) {
        return err_json("arg", "bad thread id");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
            let base = client.chat_service_url();
            let mut url = format!(
                "{}/v1/users/ME/conversations/{}/messages?pageSize={}",
                base, thread, SOURCE_PAGE_SIZE
            );
            let mut kept = Vec::new();
            let mut pages = 0usize;
            let mut complete = false;
            while pages < SOURCE_MAX_PAGES {
                let page: Value = client
                    .chat_get(&url)
                    .await
                    .map_err(|e| format!("{:#}", e))?
                    .json()
                    .await
                    .map_err(|e| format!("bad messages page: {}", e))?;
                pages += 1;
                kept.extend(recap_messages_of_page(&page));
                let empty = page["messages"].as_array().map_or(true, |a| a.is_empty());
                match page["_metadata"]["backwardLink"].as_str() {
                    Some(b) if !empty && !b.is_empty() => url = b.to_string(),
                    _ => {
                        complete = true;
                        break;
                    }
                }
            }
            // Meeting identity (thread properties) → MCPS collab object.
            let props: Result<Value, String> = async {
                client
                    .chat_get(&format!("{}/v1/threads/{}?view=msnp24Equivalent", base, thread))
                    .await
                    .map_err(|e| format!("{:#}", e))?
                    .json::<Value>()
                    .await
                    .map_err(|e| format!("bad thread: {}", e))
            }
            .await;
            // Identity: the call's transcript message (PROVEN keys) and the
            // thread properties; a failed thread read only loses the latter.
            let from_msgs = meeting_info_from_messages(&kept);
            let (from_thread, props_err) = match props {
                Ok(p) => (meeting_info(&p), None),
                Err(e) => (Value::Null, Some(e)),
            };
            // Order: the transcript message's (the call's own), the newest
            // recording's occurrence/meeting ids, then the thread's; ≤ 4 reads.
            let mut candidates = meeting_candidates(&from_msgs, &Value::Null);
            for m in meeting_infos_from_recordings(&kept).into_iter().chain(meeting_candidates(&Value::Null, &from_thread)) {
                if !candidates.iter().any(|o| o["ical_uid"] == m["ical_uid"] && o["organizer_id"] == m["organizer_id"]) {
                    candidates.push(m);
                }
            }
            candidates.truncate(4);
            let mut collab = match &props_err {
                Some(e) if candidates.is_empty() => json!({"ok": false, "error": e}),
                _ => Value::Null,
            };
            let mut meeting = if from_thread.is_null() { from_msgs.clone() } else { from_thread.clone() };
            for m in &candidates {
                let (Some(ical), Some(org)) = (m["ical_uid"].as_str(), m["organizer_id"].as_str()) else { continue };
                let read: Result<Value, String> = async {
                    let token = bearer(MCPS_RESOURCE).await?;
                    let (oid, tid) = jwt_oid_tid(&token).ok_or("token has no oid/tid")?;
                    let org_tid = m["tenant_id"].as_str().unwrap_or(&tid).to_string();
                    bearer_get(MCPS_RESOURCE, &collab_url(&oid, &tid, org, &org_tid, ical), "meeting artifacts").await
                }
                .await;
                meeting = m.clone();
                match read {
                    Ok(v) => {
                        let resources = collab_resources(&v);
                        let found = !resources.is_empty();
                        collab = json!({"ok": true, "resources": resources});
                        if found {
                            break;
                        }
                    }
                    // A later identity may still answer; an earlier success stands.
                    Err(e) if collab["ok"].as_bool() != Some(true) => collab = json!({"ok": false, "error": e}),
                    Err(_) => {}
                }
            }
            Ok(json!({"ok": true, "messages": kept, "pages": pages, "complete": complete,
                      "meeting": meeting, "collab": collab})
            .to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_sources", e))
}

/// `{ok, item:{recording row}}` for the organizer's recording.
pub fn recap_recording_json(target: &str) -> String {
    let t = match FileTarget::parse(target) {
        Ok(t) => t,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
            let item = resolve_target(&client, &t).await?;
            let row = recording_row(&item).ok_or("the recording file has no id")?;
            Ok(json!({"ok": true, "item": row}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_recording", e))
}

/// `{ok, found, content?}`: the recording's newest transcript (Teams
/// transcript JSON). `found:false` only after the transcripts list read
/// succeeded and was empty.
pub fn recap_transcript_json(target: &str) -> String {
    let t = match FileTarget::parse(target) {
        Ok(t) => t,
        Err(e) => return err_json("arg", e),
    };
    let Some(host) = t.host() else {
        return err_json("arg", "no SharePoint host");
    };
    let resource = format!("https://{}", host);
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            if let Some(loc) = t.location.as_deref().filter(|l| l.contains("/media/transcripts/")) {
                let sep = if loc.contains('?') { '&' } else { '?' };
                let content = bearer_get(&resource, &format!("{}{}format=json", loc, sep), "transcript").await?;
                return Ok(json!({"ok": true, "found": true, "content": content.to_string()}).to_string());
            }
            let (drive_id, item_id) = match t.ids() {
                Some(ids) => ids,
                None => {
                    let client = ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
                    let item = resolve_target(&client, &t).await?;
                    let i = item["id"].as_str().ok_or("the file has no id")?.to_string();
                    let d = item["parentReference"]["driveId"].as_str().ok_or("the file has no drive id")?.to_string();
                    (d, i)
                }
            };
            let list = bearer_get(&resource, &transcripts_url(&host, &drive_id, &item_id), "transcripts").await?;
            let ids = transcript_ids(&list);
            let Some(tid) = ids.first() else {
                return Ok(json!({"ok": true, "found": false}).to_string());
            };
            let content =
                bearer_get(&resource, &transcript_content_url(&host, &drive_id, &item_id, tid), "transcript").await?;
            Ok(json!({"ok": true, "found": true, "content": content.to_string()}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_transcript", e))
}

/// The meeting notes a recap reads: the Loop file's address, with its
/// drive + item ids when the artifacts service named them.
#[derive(Debug, Default, serde::Deserialize)]
pub struct NotesTarget {
    pub url: String,
    #[serde(default)]
    pub drive_id: Option<String>,
    #[serde(default)]
    pub item_id: Option<String>,
}

impl NotesTarget {
    pub fn parse(raw: &str) -> Result<NotesTarget, String> {
        let t: NotesTarget = serde_json::from_str(raw).map_err(|e| format!("bad notes target: {}", e))?;
        if https_host(t.url.trim()).is_none() {
            return Err("not an https address".into());
        }
        Ok(t)
    }

    fn ids(&self) -> Option<(String, String)> {
        let d = self.drive_id.clone().filter(|s| !bad_id(s))?;
        let i = self.item_id.clone().filter(|s| !bad_id(s))?;
        Some((d, i))
    }
}

/// `{ok, html}`: the meeting notes' content, read-only, as the Loop page
/// service's HTML snapshot (the read Teams' notes pane sends). A Loop page
/// address that is not a stored file answers `{ok, html:null}` (it opens
/// in the window); a failed read is `{ok:false}`.
pub fn recap_notes_json(target: &str) -> String {
    let t = match NotesTarget::parse(target) {
        Ok(t) => t,
        Err(e) => return err_json("arg", e),
    };
    let url = t.url.trim().to_string();
    let Some(host) = https_host(&url).filter(|_| is_sharepoint_url(&url)) else {
        return json!({"ok": true, "html": Value::Null}).to_string();
    };
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let (drive_id, item_id) = match t.ids() {
                Some(ids) => ids,
                None => {
                    let client = ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
                    let item = resolve_share(&client, &url).await?;
                    let i = item["id"].as_str().ok_or("the notes file has no id")?.to_string();
                    let d = item["parentReference"]["driveId"].as_str().ok_or("the notes file has no drive id")?.to_string();
                    (d, i)
                }
            };
            let token = bearer(LOOP_RESOURCE).await?;
            let cid = format!("{:032x}", rand::random::<u128>());
            let resp = ost::api::client::shared_http()
                .post(loop_page_url(&host, &drive_id, &item_id))
                .bearer_auth(&token)
                .header("Accept", "application/json")
                .header("Content-Type", "application/json")
                .header("x-ms-correlation-id", &cid)
                .body(r#"{"options":{"type":"html"}}"#)
                .send()
                .await
                .map_err(|e| format!("meeting notes request failed: {}", e))?;
            if !resp.status().is_success() {
                return Err(status_err(resp.status(), "meeting notes"));
            }
            let v: Value = resp.json().await.map_err(|e| format!("bad meeting notes answer: {}", e))?;
            let html = loop_page_html(&v).ok_or("the meeting notes answer has no content")?;
            Ok(json!({"ok": true, "html": html}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_notes", e))
}

/// Teams' AI-notes `EntityId` for a recording drive item (PROVEN,
/// r_data-resolvers-meeting-intelligence): `SPO_{b64url(site,web,list
/// GUIDs)}_{itemId}`, the GUIDs decoded from the `b!…` drive id (48 bytes,
/// .NET byte order). Pure.
pub fn recording_entity_id(drive_id: &str, item_id: &str) -> Option<String> {
    use base64::engine::general_purpose::{URL_SAFE_NO_PAD, STANDARD_NO_PAD};
    let b64 = drive_id.trim().strip_prefix("b!")?;
    let item = item_id.trim();
    if item.is_empty() {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(b64.trim_end_matches('='))
        .or_else(|_| STANDARD_NO_PAD.decode(b64.trim_end_matches('=')))
        .ok()?;
    if bytes.len() < 48 {
        return None;
    }
    let guid = |b: &[u8]| {
        format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        )
    };
    let joined = format!("{},{},{}", guid(&bytes[0..16]), guid(&bytes[16..32]), guid(&bytes[32..48]));
    Some(format!("SPO_{}_{}", URL_SAFE_NO_PAD.encode(joined), item))
}

/// Substrate MeetingCatchUp query for one recording (PROVEN body shape:
/// services-meeting-recap `u(t)`, Scenario `MeetingCatchUp.MeetingRecap`).
pub fn catchup_entity_body(entity_id: &str) -> String {
    format!(
        r#"{{"EntityRequests":[{{"Context":{{"EntityId":"{}"}},"QueryParameters":[{{"EntityType":"MeetingCatchUp"}}]}}],"Scenario":{{"Name":"MeetingCatchUp.MeetingRecap"}}}}"#,
        entity_id.replace('"', "")
    )
}

/// The recording to ask about: a JSON file target (`{file_url?,drive_id?,
/// item_id?}`) or a bare SharePoint address. Pure.
pub fn ai_target(raw: &str) -> Option<FileTarget> {
    let r = raw.trim();
    if r.starts_with('{') {
        FileTarget::parse(r).ok()
    } else if is_sharepoint_url(r) {
        Some(FileTarget { file_url: Some(r.to_string()), drive_id: None, item_id: None, location: None })
    } else {
        None
    }
}

/// Intelligent recap (Substrate MeetingCatchUp): by the recording's
/// EntityId (the query Teams' Recap tab sends), falling back to the
/// by-thread query (Teams' chiclet list): `{ok, available, notes,
/// follow_ups, reason}`.
pub fn recap_ai_json(thread_id: &str, file_target: &str) -> String {
    let thread = thread_id.trim();
    if bad_id(thread) {
        return err_json("arg", "bad thread id");
    }
    let target = ai_target(file_target);
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let token = bearer(SUBSTRATE_RESOURCE).await?;
            let (oid, tid) = jwt_oid_tid(&token).ok_or("token has no oid/tid")?;
            let post = |body: String| {
                let token = token.clone();
                let anchor = format!("Oid:{}@{}", oid, tid);
                async move {
                    let cid = format!("{:032x}", rand::random::<u128>());
                    let resp = ost::api::client::shared_http()
                        .post(CATCHUP_URL)
                        .bearer_auth(&token)
                        .header("Accept", "application/json")
                        .header("Content-Type", "application/json")
                        .header("client-request-id", &cid)
                        .header("x-ms-correlation-id", &cid)
                        .header("X-AnchorMailbox", anchor)
                        .body(body)
                        .send()
                        .await
                        .map_err(|e| format!("intelligent recap request failed: {}", e))?;
                    if !resp.status().is_success() {
                        return Err(status_err(resp.status(), "intelligent recap"));
                    }
                    resp.json::<Value>().await.map_err(|e| format!("bad intelligent recap answer: {}", e))
                }
            };
            // 1. By recording (drive ids from the target, else its drive item).
            if let Some(t) = &target {
                let ids = match t.ids() {
                    Some(ids) => Some(ids),
                    None => match ost::api::client::TeamsClient::new().await {
                        Ok(client) => resolve_target(&client, t).await.ok().and_then(|item| {
                            let d = item["parentReference"]["driveId"].as_str()?.to_string();
                            let i = item["id"].as_str()?.to_string();
                            Some((d, i))
                        }),
                        Err(_) => None,
                    },
                };
                if let Some(entity) = ids.and_then(|(d, i)| recording_entity_id(&d, &i)) {
                    if let Ok(v) = post(catchup_entity_body(&entity)).await {
                        let a = catchup_answer(&v);
                        if a["available"].as_bool() == Some(true) || a["reason"].is_string() {
                            return Ok(a.to_string());
                        }
                    }
                }
            }
            // 2. By meeting thread.
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let iso = |secs: u64| -> String {
                let days = (secs / 86_400) as i64;
                let (y, m, d) = civil_from_days(days);
                let rem = secs % 86_400;
                format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
            };
            let v = post(catchup_body(thread, &iso(now.saturating_sub(400 * 86_400)), &iso(now))).await?;
            Ok(catchup_answer(&v).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_ai", e))
}

// MARK: field-shape probe (RECAP_FIELDS_LIVE)

/// A key name safe to report: schema-like (letters, digits, `_ . $ -`),
/// ≤ 48 chars, no id-like hex/digit run. Anything else → `<dyn>`. Pure.
pub fn shape_name(k: &str) -> String {
    let ok_chars = !k.is_empty()
        && k.len() <= 48
        && k.chars().next().map_or(false, |c| c.is_ascii_alphabetic() || c == '_' || c == '$')
        && k.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '$' | '-'));
    let mut run = 0usize;
    let mut digits = 0usize;
    let mut max_run = 0usize;
    for c in k.chars() {
        if c.is_ascii_hexdigit() { run += 1; } else { run = 0; }
        if c.is_ascii_digit() { digits += 1; }
        max_run = max_run.max(run);
    }
    if ok_chars && max_run < 8 && digits < 6 { k.to_string() } else { "<dyn>".to_string() }
}

fn shape_unescape(s: &str) -> String {
    s.replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

/// Dotted key paths of a JSON value (names only, depth ≤ 3, ≤ 60 paths);
/// a string value that is itself a JSON object is walked too (`name{}`). Pure.
pub fn shape_keys(v: &Value) -> Vec<String> {
    fn walk(v: &Value, prefix: &str, depth: usize, out: &mut Vec<String>) {
        if depth > 3 || out.len() >= 60 {
            return;
        }
        match v {
            Value::Object(o) => {
                for (k, x) in o {
                    let name = if prefix.is_empty() { shape_name(k) } else { format!("{}.{}", prefix, shape_name(k)) };
                    match x {
                        Value::String(s) if s.trim_start().starts_with('{') => {
                            if let Ok(inner @ Value::Object(_)) = serde_json::from_str::<Value>(s.trim()) {
                                out.push(format!("{}{{}}", name));
                                walk(&inner, &name, depth + 1, out);
                                continue;
                            }
                            out.push(name);
                        }
                        Value::Object(_) => {
                            out.push(format!("{}{{}}", name));
                            walk(x, &name, depth + 1, out);
                        }
                        Value::Array(a) => {
                            out.push(format!("{}[{}]", name, a.len().min(999)));
                            if let Some(first) = a.first() {
                                walk(first, &format!("{}[]", name), depth + 1, out);
                            }
                        }
                        _ => out.push(name),
                    }
                    if out.len() >= 60 {
                        return;
                    }
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(v, "", 0, &mut out);
    out.dedup();
    out
}

/// XML element and attribute names of a content string (≤ 40). Pure.
pub fn shape_xml_names(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() && out.len() < 40 {
        if b[i] == b'<' && i + 1 < b.len() && b[i + 1].is_ascii_alphabetic() {
            let start = i + 1;
            let mut j = start;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || matches!(b[j], b'_' | b'-' | b':' | b'.')) {
                j += 1;
            }
            let n = format!("<{}>", shape_name(&s[start..j].replace(':', "_")));
            if !out.contains(&n) { out.push(n); }
            // attributes up to '>'
            let mut k = j;
            while k < b.len() && b[k] != b'>' {
                if b[k] == b'=' {
                    let mut a = k;
                    while a > j && (b[a - 1].is_ascii_alphanumeric() || matches!(b[a - 1], b'_' | b'-' | b':')) {
                        a -= 1;
                    }
                    if a < k {
                        let n = format!("@{}", shape_name(&s[a..k].replace(':', "_")));
                        if !out.contains(&n) { out.push(n); }
                    }
                    // skip quoted value
                    if k + 1 < b.len() && (b[k + 1] == b'"' || b[k + 1] == b'\'') {
                        let q = b[k + 1];
                        k += 2;
                        while k < b.len() && b[k] != q { k += 1; }
                    }
                }
                k += 1;
            }
            i = k;
        }
        i += 1;
    }
    out
}

/// Content form + names of one message content. Pure.
pub fn shape_content(content: &str) -> Value {
    let raw = shape_unescape(content);
    let t = raw.trim();
    if t.starts_with('{') {
        match serde_json::from_str::<Value>(t) {
            Ok(v) => json!({"form": "json", "keys": shape_keys(&v)}),
            Err(_) => json!({"form": "jsonBad", "len": t.len(),
                             "mentionsICalUid": t.contains("iCalUid"), "mentionsOrganizer": t.contains("rganizer")}),
        }
    } else if t.starts_with('<') {
        json!({"form": "xml", "names": shape_xml_names(t), "mentionsICalUid": t.to_ascii_lowercase().contains("icaluid")})
    } else {
        json!({"form": if t.is_empty() { "empty" } else { "text" }, "len": t.len()})
    }
}

/// First string value under a key whose lowercased name contains any of
/// `needles` (depth ≤ 4, JSON-in-string walked). Returns (key name, value). Pure.
pub fn shape_find(v: &Value, needles: &[&str], depth: usize) -> Option<(String, String)> {
    if depth > 4 {
        return None;
    }
    match v {
        Value::Object(o) => {
            for (k, x) in o {
                let lk = k.to_ascii_lowercase();
                if needles.iter().any(|n| lk.contains(n)) {
                    if let Some(s) = x.as_str().filter(|s| !s.trim().is_empty() && !s.trim_start().starts_with('{')) {
                        return Some((shape_name(k), s.to_string()));
                    }
                }
            }
            for x in o.values() {
                let inner = match x {
                    Value::String(s) if s.trim_start().starts_with('{') => serde_json::from_str(s.trim()).ok(),
                    Value::Object(_) | Value::Array(_) => Some(x.clone()),
                    _ => None,
                };
                if let Some(r) = inner.and_then(|i| shape_find(&i, needles, depth + 1)) {
                    return Some(r);
                }
            }
            None
        }
        Value::Array(a) => a.iter().take(20).find_map(|x| shape_find(x, needles, depth + 1)),
        _ => None,
    }
}

fn shape_err(e: &str) -> String {
    let b = e.as_bytes();
    for i in 0..b.len().saturating_sub(4) {
        if &b[i..i + 5] == b"HTTP " && i + 8 <= b.len() && b[i + 5..i + 8].iter().all(u8::is_ascii_digit) {
            return e[i..i + 8].to_string();
        }
    }
    if e.contains("401") { "401".into() } else { "error".into() }
}

/// RECAP_FIELDS_LIVE probe: field NAMES, counts and status codes only for
/// one meeting chat (never values). Read-only GETs: one messages page, the
/// thread, and the MCPS collab object when an identity is found.
pub fn recap_field_shape_json(thread_id: &str) -> String {
    let thread = thread_id.trim();
    if bad_id(thread) {
        return err_json("arg", "bad thread id");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new().await.map_err(|e| shape_err(&format!("{:#}", e)))?;
            let base = client.chat_service_url();
            let mut out = serde_json::Map::new();
            // Messages page 1.
            let page: Result<Value, String> = async {
                client
                    .chat_get(&format!("{}/v1/users/ME/conversations/{}/messages?pageSize={}", base, thread, SOURCE_PAGE_SIZE))
                    .await
                    .map_err(|e| shape_err(&format!("{:#}", e)))?
                    .json::<Value>()
                    .await
                    .map_err(|_| "badJson".to_string())
            }
            .await;
            let mut kept = Vec::new();
            let mut msg_identity: Option<(String, String, String, String)> = None; // (icalKey, ical, orgKey, org)
            match &page {
                Ok(p) => {
                    let msgs = p["messages"].as_array().cloned().unwrap_or_default();
                    let mut types: std::collections::BTreeMap<String, usize> = Default::default();
                    let mut samples = Vec::new();
                    let (mut nt, mut nr) = (0, 0);
                    for m in &msgs {
                        let t = m["messagetype"].as_str().unwrap_or("").to_string();
                        *types.entry(shape_name(&t.replace('/', "."))).or_default() += 1;
                        let lt = t.to_ascii_lowercase();
                        let take = (lt.contains("media_calltranscript") && nt < 2) || (lt.contains("media_callrecording") && nr < 1);
                        if take {
                            if lt.contains("transcript") { nt += 1 } else { nr += 1 }
                            let c = m["content"].as_str().unwrap_or("");
                            let mut top: Vec<String> = m.as_object().map(|o| o.keys().map(|k| shape_name(k)).collect()).unwrap_or_default();
                            top.sort();
                            samples.push(json!({"type": shape_name(&t.replace('/', ".")), "messageKeys": top,
                                                "propertiesKeys": shape_keys(&m["properties"]), "content": shape_content(c)}));
                            if msg_identity.is_none() {
                                if let Ok(v) = serde_json::from_str::<Value>(shape_unescape(c).trim()) {
                                    if let (Some((ik, iv)), Some((ok, ov))) =
                                        (shape_find(&v, &["icaluid"], 0), shape_find(&v, &["organizer"], 0))
                                    {
                                        msg_identity = Some((ik, iv, ok, ov));
                                    }
                                }
                            }
                        }
                    }
                    kept.extend(recap_messages_of_page(p));
                    out.insert("messages".into(), json!({"count": msgs.len(), "types": types, "samples": samples}));
                }
                Err(e) => { out.insert("messages".into(), json!({"error": e})); }
            }
            // Thread properties.
            let props: Result<Value, String> = async {
                client
                    .chat_get(&format!("{}/v1/threads/{}?view=msnp24Equivalent", base, thread))
                    .await
                    .map_err(|e| shape_err(&format!("{:#}", e)))?
                    .json::<Value>()
                    .await
                    .map_err(|_| "badJson".to_string())
            }
            .await;
            let mut thread_identity: Option<(String, String, String, String)> = None;
            match &props {
                Ok(p) => {
                    let mut top: Vec<String> = p.as_object().map(|o| o.keys().map(|k| shape_name(k)).collect()).unwrap_or_default();
                    top.sort();
                    out.insert("thread".into(), json!({"keys": top, "threadProperties": shape_keys(&p["threadProperties"])}));
                    if let (Some((ik, iv)), Some((ok, ov))) =
                        (shape_find(&p["threadProperties"], &["icaluid"], 0), shape_find(&p["threadProperties"], &["organizer"], 0))
                    {
                        thread_identity = Some((ik, iv, ok, ov));
                    }
                }
                Err(e) => { out.insert("thread".into(), json!({"error": e})); }
            }
            // Current parser vs generic key search.
            let cur_msgs = meeting_info_from_messages(&kept);
            let cur_thread = props.as_ref().map(meeting_info).unwrap_or(Value::Null);
            out.insert("identity".into(), json!({
                "currentFromMessages": !cur_msgs.is_null(),
                "currentFromThread": cur_thread["ical_uid"].is_string() && cur_thread["organizer_id"].is_string(),
                "threadIcal": cur_thread["ical_uid"].is_string(), "threadOrganizer": cur_thread["organizer_id"].is_string(),
                "threadHasRecap": cur_thread["has_recap"].clone(),
                "genericMessageKeys": msg_identity.as_ref().map(|(a, _, b, _)| vec![a.clone(), b.clone()]),
                "genericThreadKeys": thread_identity.as_ref().map(|(a, _, b, _)| vec![a.clone(), b.clone()]),
                "organizerLooksLikeMri": msg_identity.as_ref().or(thread_identity.as_ref()).map(|(_, _, _, o)| o.contains(':')),
            }));
            // MCPS with the first identity found.
            if let Some((_, ical, _, org)) = msg_identity.or(thread_identity) {
                let org = org.rsplit(':').next().unwrap_or(&org).to_string();
                let read: Result<Value, String> = async {
                    let token = bearer(MCPS_RESOURCE).await.map_err(|e| shape_err(&e))?;
                    let (oid, tid) = jwt_oid_tid(&token).ok_or("noClaims")?;
                    bearer_get(MCPS_RESOURCE, &collab_url(&oid, &tid, &org, &tid, &ical), "meeting artifacts")
                        .await
                        .map_err(|e| shape_err(&e))
                }
                .await;
                match read {
                    Ok(v) => {
                        let res = collab_resources(&v);
                        let mut types: Vec<String> = res.iter().map(|r| shape_name(r["type"].as_str().unwrap_or(""))).collect();
                        types.sort();
                        out.insert("mcps".into(), json!({"ok": true, "keys": shape_keys(&v), "resources": res.len(), "types": types}));
                    }
                    Err(e) => { out.insert("mcps".into(), json!({"ok": false, "error": e})); }
                }
            } else {
                out.insert("mcps".into(), json!("skipped"));
            }
            out.insert("ok".into(), json!(true));
            Ok(Value::Object(out).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("recap_field_shape", shape_err(&e)))
}

/// Days since 1970-01-01 → (year, month, day) (Howard Hinnant). Pure.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn arg(p: *const c_char) -> Result<String, String> {
    cstr_to_string(p)
}

#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_sources(thread_id: *const c_char) -> *mut c_char {
    string_to_c(match arg(thread_id) {
        Ok(t) => recap_sources_json(&t),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_recording(file_url: *const c_char) -> *mut c_char {
    string_to_c(match arg(file_url) {
        Ok(u) => recap_recording_json(&u),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_transcript(file_url: *const c_char) -> *mut c_char {
    string_to_c(match arg(file_url) {
        Ok(u) => recap_transcript_json(&u),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_notes(target: *const c_char) -> *mut c_char {
    string_to_c(match arg(target) {
        Ok(u) => recap_notes_json(&u),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_ai(thread_id: *const c_char, file_url: *const c_char) -> *mut c_char {
    let t = match arg(thread_id) {
        Ok(t) => t,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let f = if file_url.is_null() { String::new() } else { cstr_to_string(file_url).unwrap_or_default() };
    string_to_c(recap_ai_json(&t, &f))
}

/// Field-shape probe (names/counts/status codes only; see `recap_field_shape_json`).
#[no_mangle]
pub extern "C" fn ostmac_meeting_recap_field_shape(thread_id: *const c_char) -> *mut c_char {
    string_to_c(match arg(thread_id) {
        Ok(t) => recap_field_shape_json(&t),
        Err(e) => err_json("arg", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_recording_transcript_and_loop_messages_only() {
        assert!(recap_message_kept("RichText/Media_CallRecording", ""));
        assert!(recap_message_kept("RichText/Media_CallTranscript", "{}"));
        assert!(recap_message_kept("RichText/Html", "<a href=\"https://c-my.sharepoint.com/x/Meeting.loop\">n</a>"));
        assert!(!recap_message_kept("RichText/Html", "hello"));
        assert!(!recap_message_kept("ThreadActivity/AddMember", ".loop"));
        assert!(!recap_message_kept("Event/Call", ""));
    }

    #[test]
    fn page_filter_caps_and_keeps_ids() {
        let big = "x".repeat(CONTENT_CAP + 10);
        let page = json!({"messages": [
            {"id": "1", "messagetype": "RichText/Media_CallRecording", "content": big, "composetime": "2026-09-01T10:00:00Z"},
            {"id": "2", "messagetype": "RichText/Html", "content": "hi"},
            {"id": 3, "messagetype": "RichText/Media_CallTranscript", "content": "{}", "originalarrivaltime": "t"}
        ]});
        let kept = recap_messages_of_page(&page);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0]["content"].as_str().unwrap().len(), CONTENT_CAP);
        assert_eq!(kept[1]["id"], "3");
        assert_eq!(kept[1]["composetime"], "t");
    }

    #[test]
    fn share_ids_and_urls() {
        assert_eq!(share_id("https://a.sharepoint.com/x"), "u!aHR0cHM6Ly9hLnNoYXJlcG9pbnQuY29tL3g");
        assert_eq!(https_host("https://Contoso-my.sharepoint.com/personal/x"), Some("contoso-my.sharepoint.com".into()));
        assert_eq!(https_host("http://a.sharepoint.com/x"), None);
        assert!(is_sharepoint_url("https://contoso-my.sharepoint.com/p"));
        assert!(!is_sharepoint_url("https://evil.com/sharepoint.com"));
        assert_eq!(
            transcript_content_url("h.sharepoint.com", "d", "i", "t"),
            "https://h.sharepoint.com/_api/v2.1/drives/d/items/i/versions/current/media/transcripts/t/streamContent?format=json"
        );
    }

    #[test]
    fn transcript_ids_newest_first() {
        let v = json!({"value": [
            {"id": "old", "createdDateTime": "2026-01-01T00:00:00Z"},
            {"id": "new", "createdDateTime": "2026-02-01T00:00:00Z"},
            {"noid": true}
        ]});
        assert_eq!(transcript_ids(&v), vec!["new", "old"]);
        assert!(transcript_ids(&json!({"value": []})).is_empty());
    }

    #[test]
    fn recording_row_from_drive_item() {
        let item = json!({"id": "I", "name": "M.mp4", "size": 5, "file": {"mimeType": "video/mp4"},
            "parentReference": {"driveId": "D"}, "video": {"durationMillis": 1000},
            "@microsoft.graph.downloadUrl": "https://x.sharepoint.com/dl"});
        let r = recording_row(&item).unwrap();
        assert_eq!(r["drive_id"], "D");
        assert_eq!(r["duration_ms"], 1000);
        assert_eq!(r["download_url"], "https://x.sharepoint.com/dl");
    }

    #[test]
    fn bad_args_fail_before_network() {
        let v: Value = serde_json::from_str(&recap_sources_json("a/b")).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&recap_recording_json(r#"{"file_url":"https://evil.com/x.mp4"}"#)).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&recap_transcript_json("nope")).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&recap_transcript_json("{}")).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&recap_ai_json("a b", "")).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn meeting_identity_from_thread_properties() {
        let t = json!({"threadProperties": {
            "meeting": "{\"iCalUid\":\"040000008200E0\",\"organizerId\":\"org-oid\",\"tenantId\":\"ten\"}",
            "meetingMetadata": "{\"hasRecap\":\"true\"}"}});
        let m = meeting_info(&t);
        assert_eq!(m["ical_uid"], "040000008200E0");
        assert_eq!(m["organizer_id"], "org-oid");
        assert_eq!(m["tenant_id"], "ten");
        assert_eq!(m["has_recap"], true);
        let t = json!({"threadProperties": {"meetingObjectsConfig":
            "{\"configurations\":{\"transcriptConfig\":{\"hasTranscript\":\"true\",\"organizerId\":\"o2\"}}}"}});
        assert_eq!(meeting_info(&t)["organizer_id"], "o2");
        assert!(meeting_info(&json!({}))["ical_uid"].is_null());
    }

    #[test]
    fn collab_object_url_and_resources() {
        assert_eq!(
            collab_url("me", "t1", "org", "t2", "04 00"),
            "https://teams.microsoft.com/api/mcps/prod/collab/readcollabobject/me@t1/org@t2/04%2000"
        );
        let v = json!({"id": "x", "resources": [
            {"type": "Recording", "location": "https://c-my.sharepoint.com/r.mp4", "metadata": {"driveId": "b!d", "driveItemId": "i1"}},
            {"type": "TranscriptV2", "location": "https://c-my.sharepoint.com/_api/v2.1/drives/b!d/items/i1/versions/current/media/transcripts/t/streamContent"},
            {"type": "Notes", "location": "https://c-my.sharepoint.com/n.loop"},
            {"type": "RecapCrux", "location": "x"}
        ]});
        let r = collab_resources(&v);
        assert_eq!(r.len(), 3);
        assert_eq!(r[0]["type"], "recording");
        assert_eq!(r[0]["drive_item_id"], "i1");
        assert_eq!(r[2]["type"], "notes");
    }

    #[test]
    fn jwt_claims_decode_without_printing() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"oid":"o","tid":"t"}"#);
        assert_eq!(jwt_oid_tid(&format!("h.{}.s", payload)), Some(("o".into(), "t".into())));
        assert_eq!(jwt_oid_tid("nope"), None);
    }

    #[test]
    fn catchup_body_and_answers() {
        let b: Value = serde_json::from_str(&catchup_body("19:meeting_x@thread.v2", "s", "e")).unwrap();
        assert_eq!(b["EntityRequests"][0]["Filter"]["Term"]["MeetingThreadId"], "19:meeting_x@thread.v2");
        assert_eq!(b["EntityRequests"][0]["QueryParameters"][0]["EntityType"], "MeetingCatchUp");
        assert_eq!(b["Scenario"]["Name"], "MeetingCatchUp.MeetingRecap.Chiclet");
        let ok = json!({"EntitySets": [{"ResultSets": [{"Results": [{"Source": {
            "MeetingSummary": {"Notes": [{"Title": "Budget", "Text": "The budget was approved for Q4."}]},
            "PointsOfInterest": [{"Type": "Task", "Text": "Send the minutes to finance."}]}}]}]}]});
        let a = catchup_answer(&ok);
        assert_eq!(a["available"], true);
        assert_eq!(a["notes"][0], "The budget was approved for Q4.");
        assert_eq!(a["follow_ups"][0], "Send the minutes to finance.");
        let lic = json!({"EntitySets": [{"ResultSets": [{"Results": [{"Source": {"Status": "NotProcessedMissingLicense"}}]}]}]});
        let a = catchup_answer(&lic);
        assert_eq!(a["available"], false);
        assert!(a["reason"].as_str().unwrap().contains("license"));
        assert_eq!(catchup_answer(&json!({}))["available"], false);
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_725), (2026, 9, 29));
    }

    #[test]
    fn file_targets() {
        assert!(FileTarget::parse(r#"{"file_url":"https://c-my.sharepoint.com/a.mp4","drive_id":"d","item_id":"i"}"#).is_ok());
        assert!(FileTarget::parse(r#"{"drive_id":"d","item_id":"i"}"#).is_ok());
        assert!(FileTarget::parse(r#"{"drive_id":"d"}"#).is_err());
        assert!(FileTarget::parse(r#"{"location":"https://evil.com/x"}"#).is_err());
    }

    #[test]
    fn identity_from_recording_xml_properties_and_loose_json() {
        // Recording XML (element names PROVEN by the live field probe; value attributes).
        let xml = r#"<URIObject type="Video.2/CallRecording.1"><Title>T</Title><MeetingOrganizerId value="8:orgid:org-oid"/><MeetingOrganizerTenantId value="org-tid"/><ICalUid value="series-uid"/><InstanceICalUid value="inst-uid"/><MeetingICalUid value="series-uid"/></URIObject>"#;
        let old = json!({"messagetype": "RichText/Media_CallRecording", "composetime": "2026-01-01T00:00:00Z",
                         "content": r#"<URIObject><MeetingOrganizerId value="old-org"/><ICalUid value="old-uid"/></URIObject>"#});
        let new = json!({"messagetype": "RichText/Media_CallRecording", "composetime": "2026-02-01T00:00:00Z", "content": xml});
        let ids = meeting_infos_from_recordings(&[old, new]);
        assert_eq!(ids.len(), 2, "{:?}", ids);
        assert_eq!(ids[0]["ical_uid"], "inst-uid");
        assert_eq!(ids[1]["ical_uid"], "series-uid");
        assert_eq!(ids[0]["organizer_id"], "org-oid");
        assert_eq!(ids[0]["tenant_id"], "org-tid");
        // Element-text form.
        assert_eq!(xml_value("<a><ICalUid>u1</ICalUid></a>", "ICalUid").as_deref(), Some("u1"));
        assert_eq!(xml_value("<a><ICalUidX value=\"n\"/></a>", "ICalUid"), None);
        // Thread answer uses `properties` (live), not `threadProperties`.
        let t = json!({"properties": {"meeting": "{\"iCalUid\":\"U\",\"organizerId\":\"O\"}"}});
        assert_eq!(meeting_info(&t)["ical_uid"], "U");
        assert_eq!(meeting_info(&t)["organizer_id"], "O");
        // Transcript content that is not valid JSON still yields its keys.
        let bad = json!({"messagetype": "RichText/Media_CallTranscript", "composetime": "1",
                         "content": r#"{&quot;callId&quot;:&quot;c&quot;,&quot;iCalUid&quot;:&quot;U2&quot;,&quot;meetingOrganizerId&quot;:&quot;8:orgid:O2&quot;,&quot;meetingTenantId&quot;:&quot;T2&quot;,&quot;url&quot;:&quot;x"y&quot;"#});
        let m = meeting_info_from_messages(&[bad]);
        assert_eq!(m["ical_uid"], "U2");
        assert_eq!(m["organizer_id"], "O2");
        assert_eq!(m["tenant_id"], "T2");
        assert_eq!(json_text_value(r#"{\"iCalUid\":\"E\"}"#, "iCalUid").as_deref(), Some("E"));
    }

    #[test]
    fn ai_recording_entity_id_and_body() {
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let raw: Vec<u8> = (0u8..48).collect();
        let drive = format!("b!{}", URL_SAFE_NO_PAD.encode(&raw));
        let id = recording_entity_id(&drive, "ITEM1").unwrap();
        let joined = "03020100-0504-0706-0809-0a0b0c0d0e0f,13121110-1514-1716-1819-1a1b1c1d1e1f,23222120-2524-2726-2829-2a2b2c2d2e2f";
        assert_eq!(id, format!("SPO_{}_ITEM1", URL_SAFE_NO_PAD.encode(joined)));
        assert_eq!(recording_entity_id("not-a-drive", "x"), None);
        assert_eq!(recording_entity_id("b!AAAA", "x"), None);
        let b: Value = serde_json::from_str(&catchup_entity_body("SPO_a_b")).unwrap();
        assert_eq!(b["EntityRequests"][0]["Context"]["EntityId"], "SPO_a_b");
        assert_eq!(b["Scenario"]["Name"], "MeetingCatchUp.MeetingRecap");
        assert!(ai_target(r#"{"drive_id":"b!x","item_id":"y"}"#).is_some());
        assert!(ai_target("https://contoso.sharepoint.com/a.mp4").is_some());
        assert!(ai_target("").is_none());
    }

    #[test]
    fn field_shape_reports_names_never_values() {
        assert_eq!(shape_name("iCalUid"), "iCalUid");
        assert_eq!(shape_name("meetingOrganizerId"), "meetingOrganizerId");
        assert_eq!(shape_name("8:orgid:0f1e2d3c-aaaa"), "<dyn>");
        assert_eq!(shape_name("0f1e2d3c4b5a"), "<dyn>");
        assert_eq!(shape_name("a@b.com"), "<dyn>");
        let c = r#"{&quot;callId&quot;:&quot;secret-call&quot;,&quot;iCalUid&quot;:&quot;SECRETUID&quot;,&quot;meta&quot;:&quot;{\&quot;organizerId\&quot;:\&quot;SECRETORG\&quot;}&quot;}"#;
        let v = shape_content(c);
        let s = v.to_string();
        assert!(s.contains("\"json\"") && s.contains("iCalUid") && s.contains("callId"), "{}", s);
        assert!(!s.contains("SECRET") && !s.contains("secret"), "{}", s);
        let x = shape_content(r#"<URIObject type="Video.2/CallRecording.1" uri="https://x/y"><Title>Secret title</Title></URIObject>"#);
        let xs = x.to_string();
        assert!(xs.contains("<URIObject>") && xs.contains("@type") && xs.contains("@uri"), "{}", xs);
        assert!(!xs.contains("Secret") && !xs.contains("https"), "{}", xs);
        let raw: Value = serde_json::from_str(r#"{"a":{"meetingOrganizerId":"ORG"},"iCalUID":"UID"}"#).unwrap();
        assert_eq!(shape_find(&raw, &["icaluid"], 0), Some(("iCalUID".into(), "UID".into())));
        assert_eq!(shape_find(&raw, &["organizer"], 0), Some(("meetingOrganizerId".into(), "ORG".into())));
    }

    #[test]
    fn meeting_identity_from_transcript_message_and_candidates() {
        let kept = vec![
            json!({"messagetype": "richtext/media_calltranscript", "composetime": "2026-09-01T10:00:00Z",
                   "content": "{&quot;callId&quot;:&quot;c1&quot;,&quot;iCalUid&quot;:&quot;OLD&quot;,&quot;meetingOrganizerId&quot;:&quot;o1&quot;}"}),
            json!({"messagetype": "richtext/media_calltranscript", "composetime": "2026-09-08T10:00:00Z",
                   "content": "{\"callId\":\"c2\",\"iCalUid\":\"NEW\",\"meetingOrganizerId\":\"o1\",\"meetingTenantId\":\"t1\"}"}),
            json!({"messagetype": "richtext/media_callrecording", "composetime": "2026-09-09T10:00:00Z", "content": "<URIObject/>"}),
        ];
        let m = meeting_info_from_messages(&kept);
        assert_eq!(m["ical_uid"], "NEW");
        assert_eq!(m["organizer_id"], "o1");
        assert_eq!(m["tenant_id"], "t1");
        assert!(meeting_info_from_messages(&kept[2..]).is_null());
        let thread = json!({"ical_uid": "SERIES", "organizer_id": "o1", "tenant_id": "t1"});
        let c = meeting_candidates(&m, &thread);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0]["ical_uid"], "NEW");
        assert_eq!(meeting_candidates(&thread, &thread).len(), 1);
        assert!(meeting_candidates(&Value::Null, &json!({"ical_uid": "x"})).is_empty());
    }

    #[test]
    fn loop_notes_page_and_target() {
        let u = loop_page_url("contoso-my.sharepoint.com", "b!d", "01I");
        let id = base64::engine::general_purpose::STANDARD.encode("contoso-my.sharepoint.com,b!d,01I");
        assert_eq!(u, format!("https://prod.api.loop.cloud.microsoft/v0.1/pages/{}", id));
        assert_eq!(loop_page_html(&json!({"content": "<p>Hi</p>"})).as_deref(), Some("<p>Hi</p>"));
        assert!(loop_page_html(&json!({"page": {}})).is_none());
        assert!(NotesTarget::parse(r#"{"url":"http://x.sharepoint.com/a.loop"}"#).is_err());
        let t = NotesTarget::parse(r#"{"url":"https://x.sharepoint.com/a.loop","drive_id":"b!d","item_id":"01/x"}"#).unwrap();
        assert!(t.ids().is_none(), "an id with a slash is never put in a path");
        // A Loop page address (not a stored file) answers without a read.
        let v: Value = serde_json::from_str(&recap_notes_json(r#"{"url":"https://loop.cloud.microsoft/p/abc"}"#)).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["html"].is_null());
    }
}
