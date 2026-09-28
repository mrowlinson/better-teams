//! Call roster for the placed call (meeting / group video, meetvideo lane).
//!
//! The placed call keeps its own Trouter socket open for the call
//! (`calls::spawn_call_pump`). The Call Controller delivers the roster
//! (`conversation/rosterUpdate/`) and media-controller signals
//! (`call/controlVideoStreaming/`, `call/dominantSpeakerInfo/`,
//! `call/csrcInfo/`) there; each frame lands in [`ingest`].
//!
//! Roster shape (NOT live-verified): `participants` is either an object
//! keyed by MRI or an array of objects carrying `id`; each participant
//! carries `displayName` and `endpoints` (object keyed by endpoint id or
//! array), each endpoint `call.mediaStreams[]` of
//! `{type, label, sourceId, direction, serverMuted}`. The video
//! `sourceId` is the MSI a receiver subscribes to (MS-RTP Video Source
//! Request); the audio `sourceId` is the MSI Dominant Speaker History
//! reports. Both shapes (object/array) and string/number source ids
//! parse; unknown shapes are logged (bounded, sanitized) for the owner's
//! live test through [`roster_json`]'s `log` lines.
//!
//! `type: "Full"` replaces the participant set; anything else upserts in
//! place (order kept, never reordered; a keyed
//! snapshot arrives in key order). A participant whose `state`
//! reads disconnected/left/removed, or whose `endpoints` is empty, leaves.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, OnceLock};

use serde::Serialize;
use serde_json::Value;

/// One roster participant (one person; first endpoint with media wins).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CallParticipant {
    /// MRI (`8:orgid:…`), or the roster key when no MRI is given.
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_msi: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video_msi: Option<u32>,
    /// The participant's camera stream is sending (direction send*, not
    /// server-muted).
    pub video_on: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen_msi: Option<u32>,
    pub screen_on: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
    /// The signed-in user (any of their endpoints).
    pub is_self: bool,
}

#[derive(Default)]
struct RosterState {
    call_id: String,
    self_mri: String,
    participants: Vec<CallParticipant>,
    updates: u64,
    dominant_msi: Option<u32>,
    log: VecDeque<String>,
    excerpts: HashMap<String, u32>,
}

/// Max queued diagnostics lines (oldest dropped).
const LOG_CAP: usize = 200;
/// Max chars of one sanitized payload excerpt.
const EXCERPT_CHARS: usize = 1500;

fn state() -> &'static Mutex<RosterState> {
    static S: OnceLock<Mutex<RosterState>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(RosterState::default()))
}

fn lock() -> std::sync::MutexGuard<'static, RosterState> {
    state().lock().unwrap_or_else(|e| e.into_inner())
}

/// Start a fresh roster for a new placed call.
pub fn reset(call_id: &str, self_mri: &str) {
    let mut s = lock();
    *s = RosterState {
        call_id: call_id.to_string(),
        self_mri: self_mri.to_string(),
        ..Default::default()
    };
}

/// Queue one diagnostics line for the host's log (bounded).
pub fn diag(line: impl Into<String>) {
    let mut s = lock();
    push_log(&mut s, line.into());
}

fn push_log(s: &mut RosterState, line: String) {
    if s.log.len() >= LOG_CAP {
        s.log.pop_front();
    }
    s.log.push_back(line);
}

/// Dominant speaker (MS-RTP DSH, audio RTCP): the speaker's audio MSI,
/// `None` for SOURCE_NONE.
pub fn set_dominant_msi(msi: Option<u32>) {
    let mut s = lock();
    if s.dominant_msi != msi {
        s.dominant_msi = msi;
        let line = match msi {
            Some(m) => format!("dominant speaker msi {}", m),
            None => "dominant speaker none".to_string(),
        };
        push_log(&mut s, line);
    }
}

/// The screen share source (MSI) of the first other participant whose
/// applicationsharing-video stream is sending (the presenter), if any.
pub fn presenter_screen_msi() -> Option<u32> {
    let s = lock();
    s.participants
        .iter()
        .find(|p| !p.is_self && p.screen_on)
        .and_then(|p| p.screen_msi)
}

/// The callback name of a Trouter delivery frame: the last path segment
/// of its `url` (`…/conversation/rosterUpdate/` → `rosterUpdate`). Empty
/// when the frame has no parsable url.
pub fn frame_kind(frame: &str) -> String {
    let Some(at) = frame.find('{') else {
        return String::new();
    };
    let Ok(v) = serde_json::from_str::<Value>(&frame[at..]) else {
        return String::new();
    };
    let url = v.get("url").and_then(|u| u.as_str()).unwrap_or("");
    let path = url.split('?').next().unwrap_or("");
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

/// One call-socket delivery (`kind` from [`frame_kind`], `body` from
/// `extract_call_payload`). Roster frames update the participant set;
/// media-controller signals are logged (and a dominant speaker id is
/// taken when one parses). Returns true when the roster changed.
pub fn ingest(kind: &str, body: &Value) -> bool {
    let mut s = lock();
    let k = if kind.is_empty() { "frame" } else { kind };
    excerpt(&mut s, k, body);
    if k.eq_ignore_ascii_case("dominantSpeakerInfo") {
        if let Some(m) = find_u32(body, &["dominantSpeakerMsi", "dominantSpeaker", "msi", "sourceId"]) {
            s.dominant_msi = Some(m);
        }
        return false;
    }
    let Some(root) = roster_root(k, body) else {
        return false;
    };
    let before = s.participants.clone();
    apply_roster(&mut s, root);
    let changed = s.participants != before;
    s.updates += 1;
    let video = s.participants.iter().filter(|p| p.video_on).count();
    let line = format!(
        "roster #{}: {} participants, {} camera on{}",
        s.updates,
        s.participants.len(),
        video,
        if changed { "" } else { " (no change)" }
    );
    push_log(&mut s, line);
    changed
}

/// Log a sanitized excerpt of the first few frames of each kind.
fn excerpt(s: &mut RosterState, kind: &str, body: &Value) {
    let cap = match kind {
        "rosterUpdate" => 6,
        "controlVideoStreaming" => 10,
        "dominantSpeakerInfo" | "csrcInfo" => 6,
        _ => 3,
    };
    let n = s.excerpts.entry(kind.to_string()).or_insert(0);
    if *n >= cap {
        return;
    }
    *n += 1;
    let mut text = sanitize(body).to_string();
    if text.chars().count() > EXCERPT_CHARS {
        text = text.chars().take(EXCERPT_CHARS).collect::<String>() + "…";
    }
    push_log(s, format!("{}: {}", kind, text));
}

/// Payload copy for logs: `links` dropped, URLs and long strings cut
/// (no callback URLs, tokens or SDP blobs in the log).
pub fn sanitize(v: &Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(
            m.iter()
                .filter(|(k, _)| !k.eq_ignore_ascii_case("links"))
                .map(|(k, v)| (k.clone(), sanitize(v)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().take(20).map(sanitize).collect()),
        Value::String(s) if s.starts_with("http") => Value::String("<url>".to_string()),
        Value::String(s) if s.len() > 120 => Value::String(format!("<{} chars>", s.len())),
        other => other.clone(),
    }
}

/// The roster object inside a body: `{roster:{participants}}`,
/// `{rosterUpdate:{participants}}`, or a bare `{participants}`.
/// Invitation-style `participants: {from, to}` never matches.
fn roster_root<'a>(kind: &str, body: &'a Value) -> Option<&'a Value> {
    for key in ["roster", "rosterUpdate"] {
        if let Some(r) = body.get(key).filter(|r| r.get("participants").is_some()) {
            return Some(r);
        }
    }
    let p = body.get("participants")?;
    let invitation = p.get("from").is_some() || p.get("to").is_some();
    if invitation || !(p.is_object() || p.is_array()) {
        return None;
    }
    if kind.eq_ignore_ascii_case("rosterUpdate") || body.get("sequenceNumber").is_some() {
        Some(body)
    } else {
        None
    }
}

fn apply_roster(s: &mut RosterState, root: &Value) {
    let full = root
        .get("type")
        .and_then(|t| t.as_str())
        .map(|t| t.eq_ignore_ascii_case("full"))
        .unwrap_or(false);
    let mut seen: Vec<String> = Vec::new();
    let entries: Vec<(String, &Value)> = match root.get("participants") {
        Some(Value::Object(m)) => m.iter().map(|(k, v)| (k.clone(), v)).collect(),
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|v| str_field(v, &["id", "mri"]).map(|id| (id, v)))
            .collect(),
        _ => Vec::new(),
    };
    for (key, pv) in entries {
        let id = str_field(pv, &["mri", "id"]).unwrap_or(key);
        if id.trim().is_empty() {
            continue;
        }
        if leaves(pv) {
            s.participants.retain(|p| p.id != id);
            continue;
        }
        seen.push(id.clone());
        let parsed = parse_participant(&id, pv, &s.self_mri);
        match s.participants.iter_mut().find(|p| p.id == id) {
            Some(cur) => merge(cur, parsed, pv),
            None => s.participants.push(parsed),
        }
    }
    if full {
        s.participants.retain(|p| seen.contains(&p.id));
    }
}

/// Leave markers: null entry, a leave state, or an empty endpoint set.
fn leaves(pv: &Value) -> bool {
    if pv.is_null() {
        return true;
    }
    let state = str_field(pv, &["state", "status"]).unwrap_or_default();
    if ["disconnected", "left", "removed", "terminated", "departed"]
        .iter()
        .any(|k| state.eq_ignore_ascii_case(k))
    {
        return true;
    }
    match pv.get("endpoints") {
        Some(Value::Object(m)) => m.is_empty(),
        Some(Value::Array(a)) => a.is_empty(),
        _ => false,
    }
}

fn parse_participant(id: &str, pv: &Value, self_mri: &str) -> CallParticipant {
    let name = str_field(pv, &["displayName", "name"])
        .or_else(|| pv.get("details").and_then(|d| str_field(d, &["displayName"])))
        .unwrap_or_default();
    let mut p = CallParticipant {
        id: id.to_string(),
        name,
        audio_msi: None,
        video_msi: None,
        video_on: false,
        screen_msi: None,
        screen_on: false,
        muted: None,
        is_self: !self_mri.is_empty() && id.eq_ignore_ascii_case(self_mri),
    };
    let mut endpoints: Vec<&Value> = match pv.get("endpoints") {
        Some(Value::Object(m)) => m.values().collect(),
        Some(Value::Array(a)) => a.iter().collect(),
        _ => Vec::new(),
    };
    // Media on the participant itself (flat shape) counts as one endpoint.
    if pv.get("mediaStreams").is_some() || pv.get("call").is_some() {
        endpoints.push(pv);
    }
    for ep in endpoints {
        let streams = ep
            .get("call")
            .and_then(|c| c.get("mediaStreams"))
            .or_else(|| ep.get("mediaStreams"))
            .and_then(|m| m.as_array());
        for st in streams.into_iter().flatten() {
            let kind = str_field(st, &["type"]).unwrap_or_default().to_ascii_lowercase();
            let Some(msi) = st.get("sourceId").and_then(as_u32) else {
                continue;
            };
            let dir = str_field(st, &["direction"]).unwrap_or_default().to_ascii_lowercase();
            let server_muted = st.get("serverMuted").and_then(|b| b.as_bool()).unwrap_or(false);
            let sending = (dir.is_empty() || dir.starts_with("send")) && !server_muted;
            match kind.as_str() {
                "audio" if p.audio_msi.is_none() => p.audio_msi = Some(msi),
                "video" if p.video_msi.is_none() || (sending && !p.video_on) => {
                    p.video_msi = Some(msi);
                    p.video_on = sending;
                }
                "applicationsharing-video" if p.screen_msi.is_none() || (sending && !p.screen_on) => {
                    p.screen_msi = Some(msi);
                    p.screen_on = sending;
                }
                _ => {}
            }
        }
        if p.muted.is_none() {
            p.muted = ep
                .get("endpointState")
                .and_then(|e| e.get("state"))
                .and_then(|s| s.get("isMuted"))
                .and_then(|b| b.as_bool())
                .or_else(|| {
                    ep.get("endpointMetadata")
                        .and_then(|m| m.get("isMicrophoneOn"))
                        .and_then(|b| b.as_bool())
                        .map(|on| !on)
                });
        }
    }
    p
}

/// Delta merge: a field the frame omitted keeps its last value.
fn merge(cur: &mut CallParticipant, new: CallParticipant, pv: &Value) {
    if !new.name.is_empty() {
        cur.name = new.name;
    }
    let has_media = pv.get("endpoints").is_some() || pv.get("mediaStreams").is_some();
    if has_media {
        cur.audio_msi = new.audio_msi.or(cur.audio_msi);
        cur.video_msi = new.video_msi.or(cur.video_msi);
        cur.video_on = new.video_on;
        cur.screen_msi = new.screen_msi.or(cur.screen_msi);
        cur.screen_on = new.screen_on;
    }
    if new.muted.is_some() {
        cur.muted = new.muted;
    }
    cur.is_self = new.is_self;
}

fn str_field(v: &Value, keys: &[&str]) -> Option<String> {
    let m = v.as_object()?;
    for k in keys {
        if let Some(s) = m
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(k))
            .and_then(|(_, v)| v.as_str())
        {
            return Some(s.to_string());
        }
    }
    None
}

fn as_u32(v: &Value) -> Option<u32> {
    match v {
        Value::Number(n) => n.as_u64().and_then(|x| u32::try_from(x).ok()),
        Value::String(s) => s.trim().parse::<u32>().ok(),
        _ => None,
    }
}

/// First u32 under any of `keys`, searched depth-first (bounded depth).
fn find_u32(v: &Value, keys: &[&str]) -> Option<u32> {
    fn walk(v: &Value, keys: &[&str], depth: u8) -> Option<u32> {
        if depth > 4 {
            return None;
        }
        match v {
            Value::Object(m) => {
                for k in keys {
                    if let Some(x) = m
                        .iter()
                        .find(|(key, _)| key.eq_ignore_ascii_case(k))
                        .and_then(|(_, v)| as_u32(v))
                    {
                        return Some(x);
                    }
                }
                m.values().find_map(|c| walk(c, keys, depth + 1))
            }
            Value::Array(a) => a.iter().find_map(|c| walk(c, keys, depth + 1)),
            _ => None,
        }
    }
    walk(v, keys, 0)
}

/// Roster for the host (drains the diagnostics lines): participants in
/// join order, the dominant speaker's audio MSI and the participant it
/// maps to. Empty when `active_call` is not the roster's call.
pub fn roster_json(active_call: Option<&str>) -> String {
    let mut s = lock();
    let log: Vec<String> = s.log.drain(..).collect();
    let current = active_call.map(|c| c == s.call_id).unwrap_or(false);
    let participants: Vec<CallParticipant> = if current { s.participants.clone() } else { Vec::new() };
    let dominant = if current { s.dominant_msi } else { None };
    let dominant_id = dominant.and_then(|m| {
        participants
            .iter()
            .find(|p| p.audio_msi == Some(m) || p.video_msi == Some(m))
            .map(|p| p.id.clone())
    });
    serde_json::json!({
        "ok": true,
        "call_id": if current { s.call_id.clone() } else { String::new() },
        "updates": if current { s.updates } else { 0 },
        "participants": participants,
        "dominant_msi": dominant,
        "dominant_id": dominant_id,
        "log": log,
    })
    .to_string()
}

#[cfg(test)]
pub(crate) fn test_guard() -> std::sync::MutexGuard<'static, ()> {
    static G: OnceLock<Mutex<()>> = OnceLock::new();
    G.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Captured-shape fixture: MRI-keyed participants, endpoint maps,
    /// string and number source ids, then a delta (camera off, a leave).
    #[test]
    fn roster_full_then_delta() {
        let _g = test_guard();
        reset("c1", "8:orgid:me");
        let full = serde_json::json!({
            "participants": {
                "8:orgid:me": {"displayName": "Me", "endpoints": {"e0": {"call": {"mediaStreams": [
                    {"type": "audio", "label": "main-audio", "sourceId": 10, "direction": "sendrecv"},
                    {"type": "video", "label": "main-video", "sourceId": 11, "direction": "sendrecv"}]}}}},
                "8:orgid:ann": {"displayName": "Ann Baker", "endpoints": {"e1": {
                    "call": {"mediaStreams": [
                        {"type": "audio", "label": "main-audio", "sourceId": "20", "direction": "sendrecv", "serverMuted": false},
                        {"type": "video", "label": "main-video", "sourceId": "21", "direction": "sendrecv"},
                        {"type": "applicationsharing-video", "sourceId": 22, "direction": "recvonly"}]},
                    "endpointState": {"state": {"isMuted": true}}}}},
                "8:orgid:bob": {"displayName": "Bob Carter", "endpoints": {"e2": {"call": {"mediaStreams": [
                    {"type": "audio", "sourceId": 30, "direction": "sendrecv"},
                    {"type": "video", "sourceId": 31, "direction": "recvonly"}]}}}}
            },
            "type": "Full", "sequenceNumber": 1
        });
        assert!(ingest("rosterUpdate", &full));
        let v: Value = serde_json::from_str(&roster_json(Some("c1"))).unwrap();
        let ps = v["participants"].as_array().unwrap();
        assert_eq!(ps.len(), 3);
        let ann = ps.iter().find(|p| p["id"] == "8:orgid:ann").unwrap();
        assert_eq!(ann["video_msi"], 21);
        assert_eq!(ann["video_on"], true);
        assert_eq!(ann["audio_msi"], 20);
        assert_eq!(ann["screen_msi"], 22);
        assert_eq!(ann["screen_on"], false);
        assert_eq!(ann["muted"], true);
        let bob = ps.iter().find(|p| p["id"] == "8:orgid:bob").unwrap();
        assert_eq!(bob["video_on"], false, "recvonly camera is off");
        assert!(ps.iter().any(|p| p["is_self"] == true && p["id"] == "8:orgid:me"));
        assert!(!v["log"].as_array().unwrap().is_empty(), "excerpt + summary logged");

        // Delta: Ann's camera off, Bob leaves, Cara joins (array shape).
        let delta = serde_json::json!({
            "participants": [
                {"id": "8:orgid:ann", "endpoints": [{"call": {"mediaStreams": [
                    {"type": "video", "sourceId": 21, "direction": "recvonly"}]}}]},
                {"id": "8:orgid:bob", "state": "disconnected"},
                {"id": "8:orgid:cara", "displayName": "Cara Diaz", "endpoints": [{"mediaStreams": [
                    {"type": "video", "sourceId": 41, "direction": "sendonly"}]}]}
            ],
            "type": "Delta", "sequenceNumber": 2
        });
        assert!(ingest("rosterUpdate", &delta));
        set_dominant_msi(Some(20));
        let v: Value = serde_json::from_str(&roster_json(Some("c1"))).unwrap();
        let ids: Vec<&str> = v["participants"].as_array().unwrap().iter()
            .map(|p| p["id"].as_str().unwrap()).collect();
        // Stable order: the snapshot's (sorted-key) order, joiners appended.
        assert_eq!(ids, vec!["8:orgid:ann", "8:orgid:me", "8:orgid:cara"], "order kept");
        let ann = &v["participants"][0];
        assert_eq!(ann["name"], "Ann Baker", "delta keeps the name");
        assert_eq!(ann["video_on"], false);
        assert_eq!(ann["audio_msi"], 20, "delta keeps omitted streams");
        assert_eq!(v["participants"][2]["video_on"], true);
        assert_eq!(v["dominant_id"], "8:orgid:ann");
        // Another call's roster never leaks.
        let other: Value = serde_json::from_str(&roster_json(Some("c2"))).unwrap();
        assert!(other["participants"].as_array().unwrap().is_empty());
        // Invitation participants {from,to} are not a roster.
        let invite = serde_json::json!({"participants": {"from": {"id": "8:orgid:x"}, "to": []}});
        assert!(!ingest("", &invite));
        // Sanitized log: no URLs survive.
        let s = sanitize(&serde_json::json!({"links": {"a": "https://x"}, "u": "https://y", "n": 1}));
        assert_eq!(s, serde_json::json!({"u": "<url>", "n": 1}));
        assert_eq!(frame_kind(r#"3:::{"id":1,"url":"https://t/x/conversation/rosterUpdate/?a=1","body":"{}"}"#), "rosterUpdate");
    }
}
