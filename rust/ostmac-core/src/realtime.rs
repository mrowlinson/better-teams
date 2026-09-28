//! Typed realtime feed over raw Trouter events.
//!
//! `trouter_poll_json` yields opaque socket.io payloads. This module turns them
//! into typed chat message/edit events the conversation view can apply:
//! `{chat_id, id, sender, sender_id?, text, time, is_edit, edited_id?,
//! message_type, reactions?, raw}`.
//! `sender_id` is the raw `from` MRI (e.g. `8:orgid:<oid>`) when present —
//! the presence lane resolves it to a Graph user for live chatmate dots.
//!
//! Wire shapes handled (all observed or defensively supported):
//! - socket.io v1 envelope `{"name","args":[...]}` — `args` unwrapped.
//! - `trouter.connected` — handshake marker, skipped (counted).
//! - `trouter.message_loss` with `droppedIndicators[]` — see below.
//! - message resource: `content` + `messagetype`, sender in `imdisplayname`/
//!   `displayname`/`from`, chat id parsed from `conversationlink`
//!   (`.../conversations/<id>/messages/...`) or `threadid`/`conversationid`.
//! - nested envelopes `data` / `resource` / `eventMessages[]` unwrapped.
//! - keys matched case-insensitively (server mixes `composetime`,
//!   `originalarrivaltime`, camelCase variants).
//!
//! Edits: `is_edit` when `messagetype` contains "edit", `skypeeditedid` is
//! present, or the event `type`/`name` mentions an edit. `id` stays the event
//! message id; `edited_id` carries the original message id when known.
//!
//! Reactions (om-reactions): `reactions` / `properties.reactions` arrays
//! (Graph-like `[{reactionType}]`) group into per-emoji counts in picker
//! order. Reaction-only events (no content) yield empty text so the host
//! patches counts onto the known bubble.
//!
//! Typing (om-typing): `messagetype: "Control/Typing"` frames (no content)
//! yield `TypingEvent`s (`typing[]`), never messages. The host holds them
//! per thread with a timeout; frames without an attributable sender are
//! skipped (nothing to show).
//!
//! Roster (om-meet-chat): call-signaling `roster: {participants: [...]}` /
//! `participants[]` frames yield `RosterEvent`s (`roster[]`), one per
//! attributable participant, plus `dominantSpeakerInfo` / `activeSpeaker`
//! markers (speaker id with `speaking: true`). The host upserts each id
//! in place (never a list refresh); entries without any id are skipped.
//! Invitation `participants` are objects (`{from,to}`), never arrays, so
//! the call path never collides.
//!
//! `message_loss` behavior: the server sends `trouter.message_loss` when it
//! dropped queued indicators (backpressure / reconnect gap / stale etag). It
//! means "push is not a complete log — some events were never delivered".
//! Response: set `resync:true` in the typed envelope. The UI must treat that
//! as "re-fetch the visible conversation(s) via the chat API"; the feed does
//! NOT reconnect on it (the socket is healthy, history is not). Repeated
//! `message_loss` with identical etags is the server steady-state, not an
//! error — still surfaced every time so the UI can decide to re-fetch.
//!
//! Id fallback: messages without any id field get `h:<8hex>` over
//! (chat,sender,text,time) so redeliveries still dedupe. Documented, stable.

use serde::Serialize;
use serde_json::Value;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// One chat message (or edit) extracted from a Trouter event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RealtimeMessage {
    pub chat_id: String,
    pub id: String,
    pub sender: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_id: Option<String>,
    pub text: String,
    pub time: String,
    pub is_edit: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_id: Option<String>,
    /// Unstripped server HTML (om-richmedia: streaming `<img>` mining).
    pub raw: String,
    /// Grouped reaction counts (om-reactions). Omitted when empty so old
    /// hosts see the pre-reactions envelope; the host patches counts onto
    /// the known bubble and never appends for reaction-only events.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<ReactionCount>,
    /// Raw `messagetype` field (e.g. `Text`, `RichText/Html`). Empty when
    /// the event carried none — the rules filter treats that as
    /// unclassifiable (type gate passes) for old-core tolerance.
    pub message_type: String,
}

/// One grouped reaction count: picker emoji + number of reactors.
/// Mirrors `ost::api::ReactionCount` on the typed poll envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReactionCount {
    pub emoji: String,
    pub count: usize,
    /// Who reacted (core-a), when the wire names them. Omitted when
    /// empty so the pre-reactors envelope is unchanged.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub reactors: Vec<Reactor>,
}

/// One reactor on the typed poll envelope (mirrors `ost::api::Reactor`):
/// `id` is an MRI or Graph user id, `name` "" when the wire has none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Reactor {
    pub id: String,
    pub name: String,
}

/// One typing indicator extracted from a Trouter event (om-typing).
/// Skype/Teams sends `messagetype: "Control/Typing"` frames (no content);
/// the host holds them per thread with a timeout, never as bubbles.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TypingEvent {
    pub chat_id: String,
    pub sender: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_id: Option<String>,
    pub time: String,
}

/// One meeting-roster snapshot from a Trouter event (om-meet-chat).
/// Call-signaling frames carry `roster: {participants: [...]}` updates
/// plus `dominantSpeakerInfo` markers; the host upserts each participant
/// in place by id (never a list refresh). `speaking`/`muted`/`present`
/// are None when the frame said nothing about that axis (host keeps the
/// last-known value); `name` is "" on speaker-only markers (host keeps
/// the roster name) and "?" on unnamed roster entries (the core's
/// missing-name marker, MeetingDedup parity).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RosterEvent {
    pub meeting_id: String,
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaking: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub present: Option<bool>,
}

/// Result of parsing one batch of raw events.
#[derive(Debug, Default)]
pub struct ParsedBatch {
    pub messages: Vec<RealtimeMessage>,
    pub typing: Vec<TypingEvent>,
    pub roster: Vec<RosterEvent>,
    pub resync: bool,
    pub skipped: usize,
}

/// Parse one batch of raw event payloads (already JSON-decoded `Value`s).
pub fn parse_batch(events: &[Value]) -> ParsedBatch {
    let mut batch = ParsedBatch::default();
    for e in events {
        parse_value(e, &mut batch);
    }
    batch
}

fn parse_value(v: &Value, batch: &mut ParsedBatch) {
    match v {
        Value::Array(items) => {
            for it in items {
                parse_value(it, batch);
            }
        }
        Value::Object(map) => {
            // message_loss anywhere in this object => resync signal.
            if has_loss_marker(map) {
                batch.resync = true;
                batch.skipped += 1;
                return;
            }
            // socket.io v1 envelope {"name","args"}.
            if let Some(args) = map.get("args").and_then(|a| a.as_array()) {
                let name = map.get("name").and_then(|n| n.as_str()).unwrap_or("");
                if contains_ci(name, "message_loss") || contains_ci(name, "messageloss") {
                    batch.resync = true;
                    batch.skipped += 1;
                    return;
                }
                if name.eq_ignore_ascii_case("trouter.connected") {
                    batch.skipped += 1;
                    return;
                }
                let edit_hint = contains_ci(name, "edit");
                let typing_hint = contains_ci(name, "typing");
                let roster_hint = contains_ci(name, "roster");
                let speaker_hint = contains_ci(name, "speaker");
                for a in args {
                    // Named typing envelope: the name may be the only
                    // marker, so try typing before the generic path.
                    if typing_hint {
                        if let Value::Object(m) = a {
                            if let Some(t) = typing_from_object_hinted(m, true) {
                                batch.typing.push(t);
                                continue;
                            }
                        }
                    }
                    // Named roster/speaker envelope: the name may be the
                    // only marker, so try roster before the generic path.
                    // A bare participants array under a roster name is
                    // treated as the roster itself.
                    if roster_hint || speaker_hint {
                        if let Value::Object(m) = a {
                            let r = roster_from_object(m);
                            if !r.is_empty() {
                                batch.roster.extend(r);
                                continue;
                            }
                        } else if roster_hint {
                            if let Value::Array(items) = a {
                                let r = roster_from_entries(items, "");
                                if !r.is_empty() {
                                    batch.roster.extend(r);
                                    continue;
                                }
                            }
                        }
                    }
                    parse_value_hint(a, edit_hint, batch);
                }
                return;
            }
            // Skype-style nested envelopes.
            if let Some(inner) = map.get("data").filter(|d| d.is_object() || d.is_array()) {
                parse_value(inner, batch);
                return;
            }
            if let Some(inner) = map.get("resource").filter(|d| d.is_object() || d.is_array()) {
                parse_value(inner, batch);
                return;
            }
            if let Some(list) = map.get("eventMessages").and_then(|e| e.as_array()) {
                for it in list {
                    parse_value(it, batch);
                }
                return;
            }
            // Roster frames first: participant snapshots + speaker
            // markers surface as roster[]; they carry no content, so the
            // message path would only skip them.
            let roster = roster_from_object(map);
            if !roster.is_empty() {
                batch.roster.extend(roster);
                return;
            }
            // Typing frames first: they must surface as indicators,
            // never as bubbles (even if one ever carries content).
            if let Some(t) = typing_from_object_hinted(map, false) {
                batch.typing.push(t);
                return;
            }
            match message_from_object(map, false) {
                Some(m) => batch.messages.push(m),
                None => batch.skipped += 1,
            }
        }
        _ => batch.skipped += 1,
    }
}

fn parse_value_hint(v: &Value, edit_hint: bool, batch: &mut ParsedBatch) {
    if edit_hint {
        if let Value::Object(map) = v {
            if has_loss_marker(map) {
                batch.resync = true;
                batch.skipped += 1;
                return;
            }
            if let Some(t) = typing_from_object_hinted(map, false) {
                batch.typing.push(t);
                return;
            }
            match message_from_object(map, true) {
                Some(m) => batch.messages.push(m),
                None => parse_value(v, batch),
            }
            return;
        }
    }
    parse_value(v, batch);
}

/// ASCII case-insensitive substring search, no allocation.
/// `needle` must already be lowercase ASCII (all call-site markers are).
fn contains_ci(hay: &str, needle: &str) -> bool {
    let (h, n) = (hay.as_bytes(), needle.as_bytes());
    if n.is_empty() {
        return true;
    }
    h.windows(n.len()).any(|w| w.eq_ignore_ascii_case(n))
}

/// Byte index of the first ASCII case-insensitive match, no allocation.
/// `needle` must already be lowercase ASCII.
fn find_ci(hay: &str, needle: &str) -> Option<usize> {
    let (h, n) = (hay.as_bytes(), needle.as_bytes());
    if n.is_empty() {
        return Some(0);
    }
    h.windows(n.len())
        .position(|w| w.eq_ignore_ascii_case(n))
}

/// True when the object itself carries a loss marker.
fn has_loss_marker(map: &serde_json::Map<String, Value>) -> bool {
    // Exact keys first (wire shape is lowercase / camelCase).
    if map.contains_key("message_loss")
        || map.contains_key("messageloss")
        || map.contains_key("droppedindicators")
        || map.contains_key("droppedIndicators")
    {
        return true;
    }
    map.keys().any(|k| {
        k.eq_ignore_ascii_case("message_loss")
            || k.eq_ignore_ascii_case("messageloss")
            || k.eq_ignore_ascii_case("droppedindicators")
    })
}

/// Case-insensitive object lookup.
fn get_ci<'a>(map: &'a serde_json::Map<String, Value>, key: &str) -> Option<&'a Value> {
    if let Some(v) = map.get(key) {
        return Some(v);
    }
    map.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v)
}

/// Case-insensitive multi-key lookup with one exact pass, then at most
/// one fallback scan. Key priority (slice order) preserved: the scan
/// keeps the value whose key ranks first.
fn get_ci_multi<'a>(
    map: &'a serde_json::Map<String, Value>,
    keys: &[&str],
) -> Option<&'a Value> {
    for k in keys {
        if let Some(v) = map.get(*k) {
            return Some(v);
        }
    }
    let mut best: Option<(usize, &'a Value)> = None;
    for (mk, v) in map.iter() {
        for (i, k) in keys.iter().enumerate() {
            if mk.eq_ignore_ascii_case(k) {
                if best.map_or(true, |(bi, _)| i < bi) {
                    best = Some((i, v));
                }
                break;
            }
        }
        if best.map_or(false, |(bi, _)| bi == 0) {
            break;
        }
    }
    best.map(|(_, v)| v)
}

/// Borrowed string view: no clone. Numbers stringify, so they are
/// skipped — no call-site predicate can match a numeric rendering.
fn str_ref_ci<'a>(map: &'a serde_json::Map<String, Value>, key: &str) -> Option<&'a str> {
    get_ci(map, key)?.as_str()
}

fn str_ref_multi<'a>(
    map: &'a serde_json::Map<String, Value>,
    keys: &[&str],
) -> Option<&'a str> {
    get_ci_multi(map, keys)?.as_str()
}

fn first_str(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    let v = get_ci_multi(map, keys)?;
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// True when the object is a typing indicator, not a message.
/// Skype/Teams sends `messagetype: "Control/Typing"` frames (no content).
/// Matched case-insensitively; `type`/`resourceType` covered defensively.
fn is_typing_frame(map: &serde_json::Map<String, Value>) -> bool {
    // Every present key is tested (borrowed, no clone): a `type`
    // marker counts even when `messagetype` says otherwise.
    for key in ["messagetype", "messageType", "type", "resourceType"] {
        if let Some(s) = str_ref_ci(map, key) {
            if contains_ci(s, "typing") {
                return true;
            }
        }
    }
    false
}

/// Build a typing indicator from a flat resource object. None = not a
/// typing frame, or one with no attributable sender (nothing to show).
/// When `hinted` (named typing envelope), the envelope name itself is
/// the marker, so attributed sender + thread suffice without a type field.
fn typing_from_object_hinted(
    map: &serde_json::Map<String, Value>,
    hinted: bool,
) -> Option<TypingEvent> {
    if !hinted && !is_typing_frame(map) {
        return None;
    }
    let sender = first_str(
        map,
        &["imdisplayname", "displayname", "displayName", "from"],
    )
    .unwrap_or_default();
    let sender_id = str_ref_ci(map, "from")
        .filter(|f| f.starts_with("8:"))
        .map(str::to_string);
    if sender.is_empty() && sender_id.is_none() {
        return None;
    }
    if hinted && !is_typing_frame(map) && chat_id_from(map).is_empty() {
        return None; // named envelope, but no thread and no marker
    }
    let time = first_str(
        map,
        &[
            "originalarrivaltime",
            "composetime",
            "createddatetime",
            "arrivaltime",
            "timestamp",
        ],
    )
    .unwrap_or_default();
    Some(TypingEvent {
        chat_id: chat_id_from(map),
        sender: if sender.is_empty() {
            "?".to_string()
        } else {
            sender
        },
        sender_id,
        time,
    })
}

/// Roster snapshots from one flat object: `participants[]` arrays
/// (top level or under `roster`) plus `dominantSpeakerInfo` /
/// `activeSpeaker` markers. Empty = not a roster frame (fall through
/// to typing/message). Invitation `participants` are objects
/// (`{from,to}`), never arrays, so the call path is untouched.
fn roster_from_object(map: &serde_json::Map<String, Value>) -> Vec<RosterEvent> {
    let meeting_id = chat_id_from(map);
    let mut out = Vec::new();
    if let Some(items) = participants_array(map) {
        out.extend(roster_from_entries(items, &meeting_id));
    }
    if let Some(id) = dominant_speaker_id(map) {
        out.push(RosterEvent {
            meeting_id: meeting_id.clone(),
            id,
            name: dominant_speaker_name(map),
            speaking: Some(true),
            muted: None,
            present: None,
        });
    }
    out
}

/// The `participants[]` array of a roster frame: top level, or nested
/// under `roster`. Non-array `participants` (invitation `{from,to}`)
/// never match.
fn participants_array(map: &serde_json::Map<String, Value>) -> Option<&Vec<Value>> {
    if let Some(items) = get_ci(map, "participants").and_then(|v| v.as_array()) {
        return Some(items);
    }
    get_ci(map, "roster")
        .and_then(|r| r.as_object())
        .and_then(|o| get_ci(o, "participants"))
        .and_then(|v| v.as_array())
}

/// One roster event per attributable participant entry. Entries without
/// any id are skipped (nothing to upsert, same rule as typing).
fn roster_from_entries(items: &[Value], meeting_id: &str) -> Vec<RosterEvent> {
    let mut out = Vec::new();
    for e in items {
        let Value::Object(m) = e else { continue };
        let Some(id) = participant_id(m) else { continue };
        let name = participant_name(m);
        out.push(RosterEvent {
            meeting_id: meeting_id.to_string(),
            id,
            name,
            speaking: bool_ci(m, &["speaking", "isspeaking", "activespeaker", "active_speaker", "dominantspeaker"]),
            muted: bool_ci(m, &["ismuted", "servermuted", "muted", "audiomuted", "audio_muted"]),
            present: presence_of(m),
        });
    }
    out
}

/// Stable participant identity: MRI / participant / user ids first,
/// `from` next, then one `user`/`participant` nest. Endpoint ids are
/// per-device (churn across rejoins), so they never qualify.
fn participant_id(map: &serde_json::Map<String, Value>) -> Option<String> {
    if let Some(id) = first_str(
        map,
        &[
            "mri",
            "id",
            "participantid",
            "participant_id",
            "userid",
            "user_id",
            "objectid",
            "from",
        ],
    )
    .filter(|s| !s.trim().is_empty())
    {
        return Some(id);
    }
    for nest in ["user", "participant"] {
        if let Some(inner) = get_ci(map, nest).and_then(|v| v.as_object()) {
            if let Some(id) =
                first_str(inner, &["mri", "id", "userid", "user_id", "objectid"])
                    .filter(|s| !s.trim().is_empty())
            {
                return Some(id);
            }
        }
    }
    None
}

/// Display name for a roster entry: "" becomes "?" (the core's
/// missing-name marker); nested `user` covered defensively.
fn participant_name(map: &serde_json::Map<String, Value>) -> String {
    if let Some(n) = first_str(
        map,
        &["displayname", "display_name", "name", "imdisplayname"],
    )
    .filter(|s| !s.trim().is_empty())
    {
        return n;
    }
    for nest in ["user", "participant"] {
        if let Some(inner) = get_ci(map, nest).and_then(|v| v.as_object()) {
            if let Some(n) = first_str(inner, &["displayname", "display_name", "name"])
                .filter(|s| !s.trim().is_empty())
            {
                return n;
            }
        }
    }
    "?".to_string()
}

/// Present-axis from leave markers / join states. None when the entry
/// says nothing (host keeps the last-known row).
fn presence_of(map: &serde_json::Map<String, Value>) -> Option<bool> {
    if bool_ci(map, &["removed", "left", "departed"]) == Some(true) {
        return Some(false);
    }
    let s = str_ref_multi(map, &["state", "status"]).unwrap_or("");
    if ["joined", "active", "connected", "admitted", "present", "inlobby", "in_lobby"]
        .iter()
        .any(|k| s.eq_ignore_ascii_case(k))
    {
        Some(true)
    } else if ["left", "removed", "departed", "disconnected", "declined"]
        .iter()
        .any(|k| s.eq_ignore_ascii_case(k))
    {
        Some(false)
    } else {
        None
    }
}

/// Dominant/active speaker identity: string MRI or an object carrying
/// one. None = no speaker marker on this frame.
fn dominant_speaker_id(map: &serde_json::Map<String, Value>) -> Option<String> {
    for key in [
        "dominantspeakerinfo",
        "dominantspeaker",
        "activespeaker",
        "active_speaker",
    ] {
        let Some(v) = get_ci(map, key) else {
            continue;
        };
        match v {
            Value::String(s) if !s.trim().is_empty() => return Some(s.clone()),
            Value::Object(m) => {
                if let Some(id) = first_str(
                    m,
                    &[
                        "mri",
                        "id",
                        "participantid",
                        "participant_id",
                        "userid",
                        "user_id",
                        "from",
                    ],
                )
                .filter(|s| !s.trim().is_empty())
                {
                    return Some(id);
                }
            }
            _ => {}
        }
    }
    None
}

/// Display name riding a speaker marker, or "" (host keeps the roster
/// name — speaker-only markers must never blank it).
fn dominant_speaker_name(map: &serde_json::Map<String, Value>) -> String {
    for key in [
        "dominantspeakerinfo",
        "dominantspeaker",
        "activespeaker",
        "active_speaker",
    ] {
        if let Some(m) = get_ci(map, key).and_then(|v| v.as_object()) {
            if let Some(n) = first_str(m, &["displayname", "display_name", "name"])
                .filter(|s| !s.trim().is_empty())
            {
                return n;
            }
        }
    }
    String::new()
}

/// Case-insensitive boolean lookup: JSON bools, 1/0 numbers, and
/// true/false/1/0/yes/no strings. Unknown shapes fall through to the
/// next key (never a wrong value).
fn bool_ci(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<bool> {
    for k in keys {
        let Some(v) = get_ci(map, k) else {
            continue;
        };
        match v {
            Value::Bool(b) => return Some(*b),
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    return Some(i != 0);
                }
            }
            Value::String(s) => {
                let t = s.trim();
                if t.eq_ignore_ascii_case("true") || t == "1" || t.eq_ignore_ascii_case("yes") {
                    return Some(true);
                }
                if t.eq_ignore_ascii_case("false") || t == "0" || t.eq_ignore_ascii_case("no") {
                    return Some(false);
                }
            }
            _ => {}
        }
    }
    None
}

/// Build a typed message from a flat resource object. None = not a message.
/// Reaction-only events (no content, but a `reactions` array) still
/// produce a message with empty text so the host can patch counts.
fn message_from_object(
    map: &serde_json::Map<String, Value>,
    edit_hint: bool,
) -> Option<RealtimeMessage> {
    let reactions = reactions_from(map);
    let content = match first_str(map, &["content", "text"]) {
        Some(c) => c,
        None if !reactions.is_empty() => String::new(),
        None => return None,
    };
    let msgtype = first_str(map, &["messagetype", "messageType"]).unwrap_or_default();
    // Must look like a message: has content plus some message-ish marker.
    let from = first_str(
        map,
        &["imdisplayname", "displayname", "displayName", "from"],
    )
    .unwrap_or_default();
    if from.is_empty() && msgtype.is_empty() && get_ci(map, "conversationlink").is_none() {
        return None;
    }
    let text = strip_html(&content);
    let chat_id = chat_id_from(map);
    let sender = if from.is_empty() { "?".to_string() } else { from };
    // Raw sender MRI for presence resolution. `from` doubles as the
    // display-name fallback above, so re-read it raw: only `8:`-prefixed
    // values (orgid/skypeids/teamsvisitor/...) qualify; display names
    // must never leak into this field.
    let sender_id = str_ref_ci(map, "from")
        .filter(|f| f.starts_with("8:"))
        .map(str::to_string);
    let time = first_str(
        map,
        &[
            "originalarrivaltime",
            "composetime",
            "createddatetime",
            "arrivaltime",
            "timestamp",
        ],
    )
    .unwrap_or_default();
    let edited_id = first_str(map, &["skypeeditedid"]);
    let type_field = str_ref_multi(map, &["type", "resourceType"]).unwrap_or("");
    let is_edit = edit_hint
        || contains_ci(&msgtype, "edit")
        || contains_ci(type_field, "edit")
        || edited_id.is_some();
    let id = first_str(
        map,
        &[
            "id",
            "clientmessageid",
            "messageid",
            "skypemessageid",
            "messageId",
        ],
    )
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| fallback_id(&chat_id, &sender, &text, &time));
    Some(RealtimeMessage {
        chat_id,
        id,
        sender,
        sender_id,
        text,
        time,
        is_edit,
        edited_id,
        raw: content,
        reactions,
        message_type: msgtype,
    })
}

/// Grouped reaction counts from `reactions` / `properties.reactions`
/// (Graph-like `[{reactionType, user?}]`) or native
/// `properties.emotions` (`[{key, users:[{mri}]}]`), parsed by the
/// shared ost helper so history and realtime agree (core-a reactors).
/// Unknown/missing types are dropped; canonical picker order. Empty
/// when the event carries none.
fn reactions_from(map: &serde_json::Map<String, Value>) -> Vec<ReactionCount> {
    let props = get_ci(map, "properties").and_then(|p| p.as_object());
    let graph = get_ci(map, "reactions")
        .filter(|v| !v.is_null())
        .or_else(|| props.and_then(|o| get_ci(o, "reactions")).filter(|v| !v.is_null()));
    let emotions = props.and_then(|o| get_ci(o, "emotions"));
    ost::api::reaction_counts_from_values(graph, emotions)
        .into_iter()
        .map(|r| ReactionCount {
            emoji: r.emoji,
            count: r.count,
            reactors: r
                .reactors
                .into_iter()
                .map(|x| Reactor { id: x.id, name: x.name })
                .collect(),
        })
        .collect()
}

/// Chat id from conversation/resource links or explicit fields.
fn chat_id_from(map: &serde_json::Map<String, Value>) -> String {
    for key in ["conversationlink", "resourcelink", "conversationLink"] {
        if let Some(link) = str_ref_ci(map, key) {
            if let Some(id) = parse_conversation_link(link) {
                return id;
            }
        }
    }
    first_str(
        map,
        &[
            "threadid",
            "conversationid",
            "chatid",
            "threadId",
            "conversationId",
        ],
    )
    .unwrap_or_default()
}

/// `.../conversations/<id>/messages/...` -> `<id>`.
fn parse_conversation_link(link: &str) -> Option<String> {
    // Index from the original bytes: the old lowercased copy could
    // shift offsets on non-ASCII links (and panicked on some).
    let marker = "/conversations/";
    let start = find_ci(link, marker)? + marker.len();
    let rest = link.get(start..)?;
    let end = rest.find('/').unwrap_or(rest.len());
    let id = &rest[..end];
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

/// Stable content-hash id for messages that carry no id field.
fn fallback_id(chat: &str, sender: &str, text: &str, time: &str) -> String {
    let mut h = DefaultHasher::new();
    chat.hash(&mut h);
    sender.hash(&mut h);
    text.hash(&mut h);
    time.hash(&mut h);
    format!("h:{:08x}", (h.finish() & 0xffff_ffff) as u32)
}

/// Block-level tags whose boundaries separate words (mirrors
/// `ost::api::chat` strip_html; keep the two lists in sync).
const BLOCK_TAGS: &[&str] = &[
    "p", "div", "br", "section", "article", "header", "footer", "h1", "h2", "h3", "h4",
    "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "tr", "td", "th",
    "blockquote", "pre", "hr",
];

/// Strip HTML tags + decode common entities (mirrors chat API display
/// text). Spacing-aware (om-chatnames): block boundaries become one
/// space so live previews never glue words; no leading/trailing space.
fn strip_html(html: &str) -> String {
    let b = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    let mut pending_space = false;
    let mut saw_entity = false;
    while i < b.len() {
        if b[i] == b'<' {
            match b[i..].iter().position(|&c| c == b'>') {
                Some(rel) => {
                    let mut body = &b[i + 1..i + rel];
                    if let Some(rest) = body.strip_prefix(b"/") {
                        body = rest;
                    }
                    let end = body
                        .iter()
                        .position(|&c| c == b'/' || c.is_ascii_whitespace())
                        .unwrap_or(body.len());
                    let name = &body[..end];
                    if BLOCK_TAGS
                        .iter()
                        .any(|t| name.eq_ignore_ascii_case(t.as_bytes()))
                    {
                        pending_space = true;
                    }
                    i += rel + 1;
                }
                None => break, // unterminated '<': swallow rest, as before
            }
            continue;
        }
        // b[i] != b'<': copy one char (tags/entities are ASCII, so a
        // multi-byte char can never open either).
        let ch = html[i..].chars().next().unwrap_or('\u{FFFD}');
        if ch == '&' {
            saw_entity = true;
        }
        if pending_space {
            pending_space = false;
            if !out.is_empty() && !out.ends_with(char::is_whitespace) && !ch.is_whitespace() {
                out.push(' ');
            }
        }
        out.push(ch);
        i += ch.len_utf8().max(1);
    }
    if saw_entity {
        decode_entities(&out)
    } else {
        out
    }
}

/// Single-pass entity decode over the stripped text (was: six chained
/// full-string `replace` passes). Unknown entities pass through
/// untouched. One deliberate fix: `&amp;lt;` now decodes once to
/// `&lt;` (correct HTML); the old chain re-scanned and double-decoded
/// it to `<`.
fn decode_entities(s: &str) -> String {
    const ENTS: &[(&str, char)] = &[
        ("&amp;", '&'),
        ("&lt;", '<'),
        ("&gt;", '>'),
        ("&quot;", '"'),
        ("&#39;", '\''),
        ("&nbsp;", ' '),
    ];
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'&' {
            let rest = &b[i..];
            let mut hit: Option<(usize, char)> = None;
            for (ent, ch) in ENTS {
                if rest.starts_with(ent.as_bytes()) {
                    hit = Some((ent.len(), *ch));
                    break;
                }
            }
            if let Some((len, ch)) = hit {
                out.push(ch);
                i += len;
                continue;
            }
        }
        let ch = s[i..].chars().next().unwrap_or('\u{FFFD}');
        out.push(ch);
        i += ch.len_utf8().max(1);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn batch_of(v: Value) -> ParsedBatch {
        parse_batch(std::slice::from_ref(&v))
    }

    #[test]
    fn reactions_group_on_message_events() {
        let batch = batch_of(json!({
            "content": "<p>hi</p>",
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m1",
            "threadid": "19:x",
            "reactions": [
                {"reactionType": "laugh"},
                {"reactionType": "like"},
                {"reactionType": "like"},
                {"reactionType": "party"},
            ],
        }));
        assert_eq!(batch.messages.len(), 1);
        let m = &batch.messages[0];
        assert_eq!(m.text, "hi");
        assert_eq!(
            m.reactions,
            vec![
                ReactionCount {
                    emoji: "👍".to_string(),
                    count: 2,
                    reactors: vec![]
                },
                ReactionCount {
                    emoji: "😂".to_string(),
                    count: 1,
                    reactors: vec![]
                },
            ]
        );
        // Envelope carries counts; empty counts are omitted.
        let env = serde_json::to_value(m).unwrap();
        assert_eq!(env["reactions"][0]["emoji"], "👍");
        let bare = batch_of(json!({
            "content": "<p>hi</p>",
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m2",
            "threadid": "19:x",
        }));
        assert!(bare.messages[0].reactions.is_empty());
        assert!(serde_json::to_value(&bare.messages[0]).unwrap()
            .get("reactions")
            .is_none());
    }

    #[test]
    fn strip_html_block_boundaries_space_words() {
        assert_eq!(strip_html("<p>hi</p>"), "hi");
        assert_eq!(strip_html("<p>Hello</p><p>World</p>"), "Hello World");
        assert_eq!(strip_html("a<br>b"), "a b");
        assert_eq!(strip_html("a<b>x</b>b"), "axb");
        assert_eq!(strip_html("<p>a &amp; b</p>"), "a & b");
    }

    #[test]
    fn native_emotions_carry_reactors_on_envelope() {
        let batch = batch_of(json!({
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m1",
            "threadid": "19:x",
            "properties": {"emotions": [
                {"key": "like", "users": [{"mri": "8:orgid:a"}, {"mri": "8:orgid:b"}]}
            ]},
        }));
        assert_eq!(batch.messages.len(), 1);
        let m = &batch.messages[0];
        assert_eq!(m.reactions.len(), 1);
        assert_eq!(m.reactions[0].count, 2);
        let env = serde_json::to_value(m).unwrap();
        assert_eq!(env["reactions"][0]["reactors"][1]["id"], "8:orgid:b");
    }

    #[test]
    fn reaction_only_event_yields_empty_text() {
        let batch = batch_of(json!({
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m1",
            "threadid": "19:x",
            "properties": {"reactions": [{"reactionType": "heart"}]},
        }));
        assert_eq!(batch.messages.len(), 1);
        let m = &batch.messages[0];
        assert_eq!(m.text, "");
        assert_eq!(
            m.reactions,
            vec![ReactionCount {
                emoji: "❤️".to_string(),
                count: 1,
                reactors: vec![]
            }]
        );
        // No content and no reactions is still not a message.
        let skipped = batch_of(json!({
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m9",
            "threadid": "19:x",
        }));
        assert!(skipped.messages.is_empty());
        assert_eq!(skipped.skipped, 1);
    }

    #[test]
    fn message_type_carried_through() {
        let v = json!({
            "content": "hi",
            "messagetype": "RichText/Html",
            "from": "8:orgid:abc",
            "conversationlink": "https://x/conversations/19:abc/messages/1",
        });
        let b = parse_batch(&[v]);
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].message_type, "RichText/Html");
    }

    #[test]
    fn message_type_defaults_empty() {
        let v = json!({"content": "hi", "from": "Bob"});
        let b = parse_batch(&[v]);
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].message_type, "");
    }

    #[test]
    fn sender_id_only_for_mri_from() {
        // Display-name `from` doubles as the sender fallback but must
        // never leak into sender_id (borrow-first refactor pin).
        let b = batch_of(json!({
            "content": "hi",
            "messagetype": "Text",
            "from": "Doe, Jane",
            "threadid": "19:x",
        }));
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].sender, "Doe, Jane");
        assert_eq!(b.messages[0].sender_id, None);
        // Numeric `from` likewise yields no sender id.
        let b = batch_of(json!({
            "content": "hi",
            "messagetype": "Text",
            "from": 12345,
            "imdisplayname": "Num",
            "threadid": "19:x",
        }));
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].sender_id, None);
        // MRI `from` still attributes.
        let b = batch_of(json!({
            "content": "hi",
            "messagetype": "Text",
            "from": "8:orgid:aaa",
            "threadid": "19:x",
        }));
        assert_eq!(b.messages[0].sender_id.as_deref(), Some("8:orgid:aaa"));
    }

    #[test]
    fn edit_flag_reads_type_field() {
        // is_edit via `type`/`resourceType` (borrowed-lookup refactor pin).
        let b = batch_of(json!({
            "content": "v2",
            "messagetype": "Text",
            "type": "Edit",
            "from": "8:orgid:aaa",
            "threadid": "19:x",
        }));
        assert_eq!(b.messages.len(), 1);
        assert!(b.messages[0].is_edit);
        let b = batch_of(json!({
            "content": "v1",
            "messagetype": "Text",
            "resourceType": "NewMessage",
            "from": "8:orgid:aaa",
            "threadid": "19:x",
        }));
        assert_eq!(b.messages.len(), 1);
        assert!(!b.messages[0].is_edit);
    }

    #[test]
    fn control_typing_frame_yields_typing_not_message() {
        let b = batch_of(json!({
            "messagetype": "Control/Typing",
            "from": "8:orgid:aaa",
            "imdisplayname": "Doe, Jane",
            "conversationlink": "https://x/conversations/19:abc/messages/1",
            "originalarrivaltime": "2026-09-22T14:25:45.000Z",
        }));
        assert!(b.messages.is_empty());
        assert_eq!(b.skipped, 0);
        assert_eq!(b.typing.len(), 1);
        let t = &b.typing[0];
        assert_eq!(t.chat_id, "19:abc");
        assert_eq!(t.sender, "Doe, Jane");
        assert_eq!(t.sender_id.as_deref(), Some("8:orgid:aaa"));
        assert_eq!(t.time, "2026-09-22T14:25:45.000Z");
        let env = serde_json::to_value(t).unwrap();
        assert_eq!(env["chat_id"], "19:abc");
        assert_eq!(env["sender_id"], "8:orgid:aaa");
    }

    #[test]
    fn typing_matches_case_insensitively_and_named_envelope() {
        let b = batch_of(json!({
            "name": "typing",
            "args": [{
                "messageType": "control/typing",
                "displayname": "Bob",
                "threadid": "19:x",
            }],
        }));
        assert!(b.messages.is_empty());
        assert_eq!(b.typing.len(), 1);
        assert_eq!(b.typing[0].sender, "Bob");
        assert_eq!(b.typing[0].chat_id, "19:x");
        assert!(b.typing[0].sender_id.is_none());
        // sender_id omitted when absent (old-host envelope shape).
        assert!(serde_json::to_value(&b.typing[0])
            .unwrap()
            .get("sender_id")
            .is_none());
    }

    #[test]
    fn typing_without_sender_is_skipped() {
        let b = batch_of(json!({
            "messagetype": "Control/Typing",
            "threadid": "19:x",
        }));
        assert!(b.typing.is_empty());
        assert!(b.messages.is_empty());
        assert_eq!(b.skipped, 1);
    }

    #[test]
    fn typing_frame_with_content_is_still_not_a_message() {
        let b = batch_of(json!({
            "content": "stray",
            "messagetype": "Control/Typing",
            "imdisplayname": "A",
            "threadid": "19:x",
        }));
        assert!(b.messages.is_empty());
        assert_eq!(b.typing.len(), 1);
        assert_eq!(b.typing[0].sender, "A");
    }

    #[test]
    fn roster_participants_parse_with_mute_and_speaking() {
        let b = batch_of(json!({
            "threadid": "19:meeting_abc@thread.v2",
            "roster": {
                "sequenceNumber": 3,
                "participants": [
                    {"mri": "8:orgid:aaa", "displayName": "Doe, Jane",
                     "isMuted": false, "speaking": true, "state": "joined"},
                    {"mri": "8:orgid:bbb", "displayName": "Smith, Bob",
                     "serverMuted": true, "state": "active"},
                    {"endpointId": "device-only", "displayName": "Ghost"},
                ],
            },
        }));
        assert!(b.messages.is_empty());
        assert!(b.typing.is_empty());
        assert_eq!(b.skipped, 0);
        assert_eq!(b.roster.len(), 2); // device-only entry unattributable
        let a = &b.roster[0];
        assert_eq!(a.meeting_id, "19:meeting_abc@thread.v2");
        assert_eq!(a.id, "8:orgid:aaa");
        assert_eq!(a.name, "Doe, Jane");
        assert_eq!(a.speaking, Some(true));
        assert_eq!(a.muted, Some(false));
        assert_eq!(a.present, Some(true));
        let c = &b.roster[1];
        assert_eq!(c.id, "8:orgid:bbb");
        assert_eq!(c.speaking, None); // frame said nothing: host keeps
        assert_eq!(c.muted, Some(true));
        assert_eq!(c.present, Some(true));
        // Envelope shape: set axes serialize, missing axes omit.
        let env = serde_json::to_value(a).unwrap();
        assert_eq!(env["meeting_id"], "19:meeting_abc@thread.v2");
        assert_eq!(env["speaking"], true);
        assert!(serde_json::to_value(c)
            .unwrap()
            .get("speaking")
            .is_none());
    }

    #[test]
    fn roster_top_level_participants_and_leave_states() {
        let b = batch_of(json!({
            "conversationLink": "https://h/v1/users/ME/conversations/19:m@thread.v2/messages/1",
            "participants": [
                {"id": "8:orgid:gone", "name": "Gone, Gail", "removed": true},
                {"user": {"id": "8:orgid:nested", "displayName": "Nested, Ned"},
                 "audioMuted": "1", "status": "left"},
            ],
        }));
        assert_eq!(b.roster.len(), 2);
        assert_eq!(b.roster[0].meeting_id, "19:m@thread.v2");
        assert_eq!(b.roster[0].present, Some(false));
        assert_eq!(b.roster[1].id, "8:orgid:nested");
        assert_eq!(b.roster[1].name, "Nested, Ned");
        assert_eq!(b.roster[1].muted, Some(true)); // "1" string bool
        assert_eq!(b.roster[1].present, Some(false)); // status left
    }

    #[test]
    fn roster_dominant_speaker_marks_speaking_only() {
        let b = batch_of(json!({
            "threadid": "19:m@thread.v2",
            "dominantSpeakerInfo": {"mri": "8:orgid:aaa", "displayName": "Doe, Jane"},
        }));
        assert_eq!(b.roster.len(), 1);
        let r = &b.roster[0];
        assert_eq!(r.id, "8:orgid:aaa");
        assert_eq!(r.name, "Doe, Jane");
        assert_eq!(r.speaking, Some(true));
        assert_eq!(r.muted, None);
        assert_eq!(r.present, None);
        // String-marker form keeps an empty name (host keeps roster name).
        let b2 = batch_of(json!({
            "threadid": "19:m@thread.v2",
            "activeSpeaker": "8:orgid:bbb",
        }));
        assert_eq!(b2.roster.len(), 1);
        assert_eq!(b2.roster[0].id, "8:orgid:bbb");
        assert_eq!(b2.roster[0].name, "");
        assert_eq!(b2.roster[0].speaking, Some(true));
    }

    #[test]
    fn roster_named_envelope_and_bare_array() {
        let b = batch_of(json!({
            "name": "conversation/rosterUpdate",
            "args": [{
                "threadid": "19:m@thread.v2",
                "participants": [
                    {"mri": "8:orgid:aaa", "isMuted": 0},
                ],
            }],
        }));
        assert_eq!(b.roster.len(), 1);
        assert_eq!(b.roster[0].muted, Some(false)); // 0 number bool
        let bare = batch_of(json!({
            "name": "rosterUpdate",
            "args": [[
                {"mri": "8:orgid:aaa", "displayName": "A"},
            ]],
        }));
        assert_eq!(bare.roster.len(), 1);
        assert_eq!(bare.roster[0].name, "A");
        assert_eq!(bare.roster[0].meeting_id, "");
    }

    #[test]
    fn ci_helpers_match_without_alloc_semantics() {
        assert!(contains_ci("Control/TYPING", "typing"));
        assert!(contains_ci("trouter.MESSAGE_loss", "message_loss"));
        assert!(!contains_ci("Text", "typing"));
        assert!(!contains_ci("ty", "typing"));
        assert_eq!(find_ci("/CONVERSATIONS/19:z/x", "/conversations/"), Some(0));
        assert_eq!(find_ci("https://h/a/Conversations/19:z", "/conversations/"), Some(11));
        assert_eq!(find_ci("nope", "/conversations/"), None);
    }

    #[test]
    fn entities_decode_single_pass() {
        assert_eq!(strip_html("<p>a &amp; b</p>"), "a & b");
        assert_eq!(strip_html("x&nbsp;y"), "x y");
        assert_eq!(strip_html("&lt;&gt;&quot;&#39;"), "<>\"'");
        assert_eq!(strip_html("plain"), "plain"); // fast path: no '&'
        assert_eq!(strip_html("a &foo; b"), "a &foo; b"); // unknown kept
        assert_eq!(strip_html("a&amp"), "a&amp"); // missing ';' kept
        // Single pass: no double-decode of &amp;lt; (old chain gave "<").
        assert_eq!(strip_html("<p>&amp;lt;</p>"), "&lt;");
    }

    #[test]
    fn mixed_case_keys_and_link_parse() {
        let b = batch_of(json!({
            "content": "<P>Hi</P>",
            "MessageType": "RichText/Html",
            "DisplayName": "Zed",
            "MessageId": "m7",
            "ConversationLink": "https://h/V1/CONVERSATIONS/19:z/Messages/1",
            "OriginalArrivalTime": "2026-01-01T00:00:00.000Z",
        }));
        assert_eq!(b.messages.len(), 1);
        let m = &b.messages[0];
        assert_eq!((m.text.as_str(), m.id.as_str(), m.chat_id.as_str()), ("Hi", "m7", "19:z"));
        assert_eq!(m.message_type, "RichText/Html");
        // all-caps key spellings resolve through the fallback scan
        let b2 = batch_of(json!({
            "CONTENT": "yo",
            "MESSAGETYPE": "Text",
            "FROM": "8:orgid:q",
            "THREADID": "19:q",
        }));
        assert_eq!(b2.messages.len(), 1);
        assert_eq!(b2.messages[0].chat_id, "19:q");
        assert_eq!(b2.messages[0].sender_id.as_deref(), Some("8:orgid:q"));
    }

    #[test]
    fn type_marker_still_flags_typing_when_messagetype_plain() {
        // is_typing_frame tests every present key, not just the first.
        let b = batch_of(json!({
            "messagetype": "Text",
            "type": "threadTyping",
            "from": "8:orgid:aaa",
            "threadid": "19:x",
        }));
        assert!(b.messages.is_empty());
        assert_eq!(b.typing.len(), 1);
    }

    #[test]
    fn roster_ignores_invitation_participant_objects() {
        // Invitation frames carry participants as {from,to} objects —
        // never roster arrays — so they must not yield roster events.
        let b = batch_of(json!({
            "participants": {
                "from": {"id": "8:orgid:aaa", "displayName": "A"},
                "to": [{"id": "8:orgid:bbb"}],
            },
        }));
        assert!(b.roster.is_empty());
        assert!(b.messages.is_empty());
        assert_eq!(b.skipped, 1);
    }
}
