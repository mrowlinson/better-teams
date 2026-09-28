//! Call signaling for embedders — place/accept/end + echo-bot + recorder inject.
//!
//! Signaling only, no audio/video: this mirrors the `ost` CLI flows in
//! `calling::{signaling,call_test,recording}` up to the media boundary:
//! - outgoing: Trouter negotiate + AV SDP offer + epconv place + invite,
//!   wait for the media answer, acknowledge + register CC callbacks.
//!   No sockets are kept, no RTP flows; the call is signaling-connected.
//! - incoming: invitations arrive on the background Trouter feed and are
//!   surfaced via `trouter_poll_typed` (`calls[]`); accept posts the SDP
//!   media answer (generated, never streamed) then the acceptance.
//! - end posts the stored end URL either way.
//! - recorder inject posts `add_recorder_bot` on the outgoing leg.
//!
//! Wire quirks mirrored from ost (private there, reimplemented here so
//! `ost` stays untouched): epconv derivation, JWT MRI extraction, 1:1
//! callee-OID extraction, `/add` URL derivation, callEnd/rejection text.
//!
//! Single-call model: one `StoredCall` slot. A new incoming invitation
//! replaces the slot only when no call is placing/ringing/connected.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde::Serialize;

use ost::calling::{
    ice, parse_call_notification, recording, sdp, signaling, video, CallNotification,
};
use ost::config::Config;
use ost::trouter::{registrar, session, websocket};

use crate::{err_json, http, now_secs, rt, whoami_json};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// UI-facing call record. `state` is one of
/// placing|ringing|connected|ended|failed. `dir` is in|out.
#[derive(Debug, Clone, Serialize)]
pub struct CallInfo {
    pub id: String,
    pub dir: String,
    pub peer: String,
    pub peer_name: String,
    pub thread: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub controller: Option<String>,
    pub started_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// True once the live media engine (ICE/SRTP/RTP) is attached.
    #[serde(default)]
    pub live_media: bool,
    /// Unix seconds the call reached `connected` (accept / callee
    /// answered). The call-duration origin; `started_at` is the ring or
    /// placement time. None until connected.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected_at: Option<u64>,
}

impl CallInfo {
    fn active(&self) -> bool {
        matches!(self.state.as_str(), "placing" | "ringing" | "connected")
    }
}

/// One typed call event for the `calls[]` typed-poll field.
/// `kind` is incoming|end|rejected.
#[derive(Debug, Clone, Serialize)]
pub struct CallEvent {
    pub kind: String,
    pub call_id: String,
    pub peer: String,
    pub peer_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

struct StoredCall {
    info: CallInfo,
    end_url: Option<String>,
    notification: Option<CallNotification>,
    // Outgoing leg ids (recorder inject reuses them).
    caller_mri: String,
    participant_id: String,
    endpoint_id: String,
    thread_id: String,
    display_name: String,
    trouter_surl: String,
}

fn current() -> &'static Mutex<Option<StoredCall>> {
    static C: OnceLock<Mutex<Option<StoredCall>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(None))
}

fn lock_current() -> std::sync::MutexGuard<'static, Option<StoredCall>> {
    current().lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
fn clear_current() {
    *lock_current() = None;
}

// Tests run threaded but the call slot is global: slot-touching tests
// hold this guard so they never interleave.
#[cfg(test)]
pub(crate) fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static T: OnceLock<Mutex<()>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

static ID_COUNTER: AtomicU64 = AtomicU64::new(1);

// Opaque unique ids (endpoint/participant/chain/message/call). The server
// treats them as opaque; uuid would add a dependency for no wire gain.
fn gen_id() -> String {
    let n = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut h = DefaultHasher::new();
    (now_secs(), std::process::id(), n).hash(&mut h);
    format!("{:016x}{:016x}", now_secs(), h.finish())
}

// ---------------------------------------------------------------------------
// Small mirrors of ost-private helpers (no new dependencies)
// ---------------------------------------------------------------------------

fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits = 0u32;
    for c in s.chars() {
        if c == '=' {
            break;
        }
        let v = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32 + 26,
            '0'..='9' => c as u32 - '0' as u32 + 52,
            '-' | '+' => 62,
            '_' | '/' => 63,
            _ => return None,
        };
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// User MRI from a Skype-token JWT (`skypeid` claim, else `oid`).
/// Mirrors `call_test::extract_mri_from_skype_token`.
fn extract_mri(token: &str) -> Option<String> {
    let payload = token.split('.').nth(1)?;
    let decoded = b64url_decode(payload)?;
    let json: serde_json::Value = serde_json::from_slice(&decoded).ok()?;
    if let Some(skypeid) = json.get("skypeid").and_then(|v| v.as_str()) {
        if skypeid.starts_with("orgid:") || skypeid.starts_with("teamsvisitor:") {
            return Some(format!("8:{}", skypeid));
        }
        return Some(skypeid.to_string());
    }
    json.get("oid")
        .and_then(|v| v.as_str())
        .map(|oid| format!("8:orgid:{}", oid))
}

/// Callee OID from a 1:1 thread (`19:{a}_{b}@unq.gbl.spaces`).
/// Mirrors `call_test::extract_callee_oid_from_thread`.
fn extract_callee_oid(thread_id: &str, caller_oid: &str) -> Option<String> {
    let inner = thread_id
        .strip_prefix("19:")
        .and_then(|s| s.strip_suffix("@unq.gbl.spaces"))?;
    let mut parts = inner.split('_');
    let (a, b) = (parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    if a == caller_oid {
        Some(b.to_string())
    } else if b == caller_oid {
        Some(a.to_string())
    } else {
        Some(b.to_string())
    }
}

/// epconv base from region GTMS. Mirrors `call_test::derive_epconv_url`.
fn derive_epconv_url(region_gtms: &serde_json::Value) -> Option<String> {
    if let Ok(url) = std::env::var("TEAMS_EPCONV_URL") {
        return Some(url);
    }
    if let Some(url) = region_gtms
        .get("calling_conversationServiceUrl")
        .and_then(|v| v.as_str())
    {
        return Some(url.to_string());
    }
    let potential_url = region_gtms
        .get("calling_potentialCallRequestUrl")
        .and_then(|v| v.as_str())?;
    if let Some(idx) = potential_url.find("/api/v2/") {
        Some(format!("{}/api/v2/epconv", &potential_url[..idx]))
    } else {
        Some(potential_url.replace("/cc/v1/potentialcall", "/epconv"))
    }
}

/// Append a leaf (`add`, `addParticipant`) to a conversationController
/// URL, preserving the query string. Mirrors ost's invite/derive fns.
fn derive_add_url(conversation_controller: &str, leaf: &str) -> String {
    if let Some(idx) = conversation_controller.find('?') {
        let (path, query) = conversation_controller.split_at(idx);
        format!("{}/{}{}", path.trim_end_matches('/'), leaf, query)
    } else {
        format!(
            "{}/{}",
            conversation_controller.trim_end_matches('/'),
            leaf
        )
    }
}

/// Conversation id from a controller URL (`/conv/<b64>` segment,
/// base64url GUID decoded like ost, else the raw segment).
fn extract_conversation_id(url: &str) -> String {
    let marker = "/conv/";
    let seg = url
        .find(marker)
        .map(|i| &url[i + marker.len()..])
        .map(|after| {
            let end = after
                .find(|c| c == '/' || c == '?')
                .unwrap_or(after.len());
            &after[..end]
        })
        .unwrap_or("");
    if seg.is_empty() {
        return "unknown".to_string();
    }
    decode_base64_uuid(seg).unwrap_or_else(|| seg.to_string())
}

fn decode_base64_uuid(b64: &str) -> Option<String> {
    let bytes = b64url_decode(b64)?;
    if bytes.len() != 16 {
        return None;
    }
    Some(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[3], bytes[2], bytes[1], bytes[0],
        bytes[5], bytes[4],
        bytes[7], bytes[6],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    ))
}

fn invitation_summary(n: &CallNotification) -> (String, String, String, Vec<String>) {
    let call_id = n
        .debug_content
        .as_ref()
        .and_then(|d| d.call_id.clone())
        .unwrap_or_default();
    let (peer, peer_name) = n
        .participants
        .as_ref()
        .and_then(|p| p.from.clone())
        .map(|f| {
            (
                f.id.unwrap_or_default(),
                f.display_name.unwrap_or_default(),
            )
        })
        .unwrap_or_default();
    let modalities = n
        .call_invitation
        .as_ref()
        .and_then(|i| i.call_modalities.clone())
        .unwrap_or_default();
    (call_id, peer, peer_name, modalities)
}

fn end_text(v: &serde_json::Value) -> Option<String> {
    let e = v.get("callEnd")?;
    Some(format!(
        "Call ended: {} (code={}, subCode={})",
        e.get("phrase").and_then(|s| s.as_str()).unwrap_or("unknown"),
        e.get("code").and_then(|c| c.as_u64()).unwrap_or(0),
        e.get("subCode").and_then(|c| c.as_u64()).unwrap_or(0),
    ))
}

fn rejection_text(v: &serde_json::Value) -> Option<String> {
    let r = v.get("sessionRejection")?;
    Some(format!(
        "Call rejected: {} (code={}, subCode={})",
        r.get("phrase").and_then(|s| s.as_str()).unwrap_or("unknown"),
        r.get("code").and_then(|c| c.as_u64()).unwrap_or(0),
        r.get("subCode").and_then(|c| c.as_u64()).unwrap_or(0),
    ))
}

fn display_name_or(fallback: &str) -> String {
    serde_json::from_str::<serde_json::Value>(&whoami_json())
        .ok()
        .and_then(|v| {
            v.get("display_name")
                .and_then(|n| n.as_str())
                .map(str::to_string)
        })
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

// ---------------------------------------------------------------------------
// Status + incoming scan (local, no network)
// ---------------------------------------------------------------------------

/// Current call slot: `{ok:true, call:{...}|null}`. Never touches network.
pub fn call_status_json() -> String {
    let call = lock_current().as_ref().map(|s| s.info.clone());
    serde_json::json!({"ok": true, "call": call}).to_string()
}

/// Record an incoming invitation. Returns the stored info plus whether
/// this is a new ring (false = duplicate or an active call is in the way,
/// slot left untouched).
fn note_incoming(n: CallNotification) -> (CallInfo, bool) {
    let (mut call_id, peer, peer_name, modalities) = invitation_summary(&n);
    if call_id.is_empty() {
        call_id = gen_id();
    }
    let mut guard = lock_current();
    if let Some(cur) = guard.as_ref() {
        if cur.info.active() {
            return (cur.info.clone(), false);
        }
    }
    let info = CallInfo {
        id: call_id,
        dir: "in".to_string(),
        peer,
        peer_name,
        thread: String::new(),
        state: "ringing".to_string(),
        controller: None,
        started_at: now_secs(),
        live_media: false,
        connected_at: None,
        detail: if modalities.is_empty() {
            None
        } else {
            Some(format!("modalities: {}", modalities.join(",")))
        },
    };
    *guard = Some(StoredCall {
        info: info.clone(),
        end_url: n
            .call_invitation
            .as_ref()
            .and_then(|i| i.links.as_ref())
            .and_then(|l| l.end.clone()),
        notification: Some(n),
        caller_mri: String::new(),
        participant_id: String::new(),
        endpoint_id: String::new(),
        thread_id: String::new(),
        display_name: String::new(),
        trouter_surl: String::new(),
    });
    (info, true)
}

/// Mark the active call ended (remote callEnd frame). Returns the call id.
fn note_end(detail: Option<String>) -> Option<String> {
    crate::live::stop_engine();
    let mut guard = lock_current();
    let cur = guard.as_mut()?;
    if !cur.info.active() {
        return None;
    }
    crate::live::reset_call_mute(); // mute is per call
    cur.info.state = "ended".to_string();
    cur.info.detail = detail;
    Some(cur.info.id.clone())
}

fn note_failed(detail: String) -> Option<String> {
    crate::live::stop_engine();
    let mut guard = lock_current();
    let cur = guard.as_mut()?;
    if !cur.info.active() {
        return None;
    }
    crate::live::reset_call_mute(); // mute is per call
    cur.info.state = "failed".to_string();
    cur.info.detail = Some(detail);
    Some(cur.info.id.clone())
}

/// Scan drained Trouter event strings for call frames. Called from the
/// typed poll (same drain, no stealing): invitations update the call slot
/// and surface as `{kind:"incoming"}`; callEnd/rejection frames close it.
/// Parses each string once, then delegates to [`scan_values`].
pub fn scan_events(raw: &[String]) -> Vec<CallEvent> {
    let values: Vec<serde_json::Value> = raw
        .iter()
        .filter_map(|e| serde_json::from_str(e).ok())
        .collect();
    scan_values(&values)
}

/// Scan already-parsed Trouter event values for call frames. Same output
/// as [`scan_events`] with zero re-parses: object nests are matched in
/// place; only genuinely stringified nests are parsed (once each).
pub fn scan_values(values: &[serde_json::Value]) -> Vec<CallEvent> {
    let mut out = Vec::new();
    for v in values {
        if let Some(n) = find_invitation_value(v) {
            let (call_id, peer, peer_name, _) = invitation_summary(&n);
            let (info, fresh) = note_incoming(n);
            if fresh {
                out.push(CallEvent {
                    kind: "incoming".to_string(),
                    call_id: if call_id.is_empty() { info.id } else { call_id },
                    peer,
                    peer_name,
                    detail: info.detail,
                });
            }
            continue;
        }
        // Non-invitation call frames: args[] first, then top level.
        // Inline loops, no Vec: this runs per tick event.
        // Borrows only: no clones, no re-parse.
        let mut done = false;
        if let Some(args) = v.get("args").and_then(|a| a.as_array()) {
            for a in args {
                if scan_candidate(a, &mut out) {
                    done = true;
                    break;
                }
            }
        }
        if !done {
            scan_candidate(v, &mut out);
        }
    }
    out
}

/// End/reject check for one candidate frame. True = hit, stop scanning
/// (a text hit stops the scan even when the slot is untouched, as before).
fn scan_candidate(v: &serde_json::Value, out: &mut Vec<CallEvent>) -> bool {
    if let Some(t) = end_text(v) {
        if let Some(id) = note_end(Some(t.clone())) {
            out.push(CallEvent {
                kind: "end".to_string(),
                call_id: id,
                peer: String::new(),
                peer_name: String::new(),
                detail: Some(t),
            });
        }
        return true;
    }
    if let Some(t) = rejection_text(v) {
        if let Some(id) = note_failed(t.clone()) {
            out.push(CallEvent {
                kind: "rejected".to_string(),
                call_id: id,
                peer: String::new(),
                peer_name: String::new(),
                detail: Some(t),
            });
        }
        return true;
    }
    false
}

/// Invitation hunt on a parsed frame: whole value, then
/// args[]/body/data/resource nests (5::: event JSON wraps the payload in
/// several observed shapes). Object nests match in place; string nests
/// parse once. Same hits as the old string form, minus re-serializes.
fn find_invitation_value(v: &serde_json::Value) -> Option<CallNotification> {
    if let Some(n) = notification_from_value(v) {
        return Some(n);
    }
    if let Some(args) = v.get("args").and_then(|a| a.as_array()) {
        for a in args {
            let hit = match a.as_str() {
                Some(s) => parse_call_notification(s),
                None => notification_from_value(a),
            };
            if hit.is_some() {
                return hit;
            }
        }
    }
    for key in ["body", "data", "resource"] {
        if let Some(inner) = v.get(key) {
            let hit = match inner.as_str() {
                Some(s) => parse_call_notification(s),
                None => notification_from_value(inner),
            };
            if hit.is_some() {
                return hit;
            }
        }
    }
    None
}

/// Value form of `ost::calling::parse_call_notification` (kept local so
/// `ost` stays untouched): top-level `callInvitation`, or a stringified
/// (`parse` once) or object `body` nest carrying one.
fn notification_from_value(v: &serde_json::Value) -> Option<CallNotification> {
    if v.get("callInvitation").is_some() {
        return serde_json::from_value(v.clone()).ok();
    }
    if let Some(body) = v.get("body") {
        if let Some(s) = body.as_str() {
            return parse_call_notification(s);
        }
        if body.get("callInvitation").is_some() {
            return serde_json::from_value(body.clone()).ok();
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Accept / end / recorder inject
// ---------------------------------------------------------------------------

fn skype_token_string() -> Result<String, String> {
    let cfg = Config::load_cached().map_err(|e| e.to_string())?;
    cfg.get_skype_token()
        .filter(|t| !t.is_expired())
        .map(|t| t.token)
        .ok_or_else(|| "no usable skype token; sign in first".to_string())
}

async fn post_empty(http: &reqwest::Client, skype_token: &str, url: &str) -> Result<(), String> {
    let resp = http
        .post(url)
        .header("X-Skypetoken", skype_token)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({}))
        .send()
        .await
        .map_err(|e| format!("POST {}: {}", url, e))?;
    let status = resp.status();
    if status.is_success() {
        Ok(())
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(format!("POST {} -> {}: {}", url, status, body))
    }
}

/// Accept the ringing incoming call: SDP media answer first (generated,
/// never streamed — ost order), then the acceptance POST.
pub fn call_accept_json() -> String {
    accept_inner(false)
}

/// Accept the ringing incoming call with live media: the SDP answer carries
/// real ports + candidates, then the media engine (ICE/SRTP/RTP) attaches.
pub fn call_accept_live_json() -> String {
    accept_inner(true)
}

fn accept_inner(live: bool) -> String {
    let (notification, id) = {
        let guard = lock_current();
        match guard.as_ref() {
            Some(s) if s.info.state == "ringing" && s.info.dir == "in" => {
                (s.notification.clone(), s.info.id.clone())
            }
            Some(s) => {
                return err_json(
                    "no_incoming",
                    format!("no ringing incoming call (slot: {})", s.info.state),
                )
            }
            None => return err_json("no_incoming", "no ringing incoming call"),
        }
    };
    let notification = match notification {
        Some(n) => n,
        None => return err_json("no_incoming", "invitation links missing"),
    };
    let skype = match skype_token_string() {
        Ok(t) => t,
        Err(e) => return err_json("auth", e),
    };
    let run = || -> Result<(bool, String, Option<crate::live::EngineParams>), String> {
        let rt = rt()?;
        rt.block_on(async {
            let http = http();
            // Live: bind real media ports (+ bounded srflx) before answering.
            let live_socks = if live {
                let audio_sock = tokio::net::UdpSocket::bind("0.0.0.0:0")
                    .await
                    .map_err(|e| format!("udp bind: {}", e))?;
                let video_sock = tokio::net::UdpSocket::bind("0.0.0.0:0")
                    .await
                    .map_err(|e| format!("udp bind: {}", e))?;
                let srflx = async {
                    let a = ice::gather_srflx_candidate(&audio_sock, ice::DEFAULT_STUN_SERVER).await;
                    let v = ice::gather_srflx_candidate(&video_sock, ice::DEFAULT_STUN_SERVER).await;
                    (a, v)
                };
                let (a_srflx, v_srflx) = tokio::time::timeout(Duration::from_secs(10), srflx)
                    .await
                    .unwrap_or((None, None));
                Some((audio_sock, video_sock, a_srflx, v_srflx))
            } else {
                None
            };
            // Media answer first (best-effort: ost still accepts without).
            let mut answered = false;
            let mut warn = String::new();
            let mut handoff: Option<crate::live::EngineParams> = None;
            if let Some(blob) = notification
                .call_invitation
                .as_ref()
                .and_then(|i| i.media_content.as_ref())
                .and_then(|m| m.blob.as_ref())
            {
                match sdp::parse_sdp_offer(blob) {
                    Ok(offer) => {
                        let local_ip = sdp::get_local_ip();
                        let (answer, socks) = match live_socks {
                            Some((ref a, ref v, ref a_srflx, ref v_srflx)) => {
                                let ap = a.local_addr().map(|x| x.port()).unwrap_or(0);
                                let vp = v.local_addr().map(|x| x.port()).unwrap_or(0);
                                let host = |port: u16| ice::IceCandidate {
                                    foundation: "1".to_string(),
                                    component: 1,
                                    transport: ice::Transport::Udp,
                                    priority: 2130706431,
                                    address: local_ip.clone(),
                                    port,
                                    candidate_type: ice::CandidateType::Host,
                                    raddr: None,
                                    rport: None,
                                };
                                let mut ac = vec![host(ap)];
                                ac.extend(a_srflx.clone());
                                let mut vc = vec![host(vp)];
                                vc.extend(v_srflx.clone());
                                (
                                    sdp::generate_sdp_answer_full(
                                        &local_ip, ap, vp, &offer, &ac, &vc,
                                    ),
                                    true,
                                )
                            }
                            None => (
                                sdp::generate_sdp_answer_full(&local_ip, 0, 0, &offer, &[], &[]),
                                false,
                            ),
                        };
                        match signaling::send_media_answer(&http, &skype, &notification, &answer.sdp)
                            .await
                        {
                            Ok(()) => {
                                answered = true;
                                if socks {
                                    // live_socks is Some exactly when the
                                    // real-port branch ran.
                                    let (a, v, _, _) = live_socks.unwrap();
                                    handoff = Some(crate::live::EngineParams {
                                        audio_sock: a
                                            .into_std()
                                            .map_err(|e| format!("audio sock: {}", e))?,
                                        video_sock: v
                                            .into_std()
                                            .map_err(|e| format!("video sock: {}", e))?,
                                        local_audio_crypto: answer.audio_crypto_line.clone(),
                                        local_video_crypto: answer.video_crypto_line.clone(),
                                        local_audio_ufrag: answer.audio_ice_ufrag.clone(),
                                        local_audio_pwd: answer.audio_ice_pwd.clone(),
                                        local_video_ufrag: answer.video_ice_ufrag.clone(),
                                        local_video_pwd: answer.video_ice_pwd.clone(),
                                        remote_sdp: blob.clone(),
                                        controlling: false,
                                        video_ssrc: video::generate_ssrc(),
                                        cname: extract_mri(&skype)
                                            .unwrap_or_else(|| "ostmac".to_string()),
                                    });
                                }
                            }
                            Err(e) => warn = format!("media answer failed: {:#}", e),
                        }
                    }
                    Err(e) => warn = format!("SDP offer unparseable: {:#}", e),
                }
            } else {
                warn = "invitation carries no SDP offer".to_string();
            }
            signaling::accept_call(&http, &skype, &notification)
                .await
                .map_err(|e| format!("accept: {:#}", e))?;
            Ok((answered, warn, handoff))
        })
    };
    match run() {
        Ok((answered, warn, handoff)) => {
            let mut warn = warn;
            let mut live_on = false;
            if let Some(params) = handoff {
                match crate::live::start_engine(params) {
                    Ok(()) => live_on = true,
                    Err(e) => {
                        warn = if warn.is_empty() {
                            format!("live media failed: {}", e)
                        } else {
                            format!("{}; live media failed: {}", warn, e)
                        };
                    }
                }
            } else if live {
                warn = if warn.is_empty() {
                    "no media answer; signaling only".to_string()
                } else {
                    warn
                };
            }
            let mut guard = lock_current();
            if let Some(s) = guard.as_mut().filter(|s| s.info.id == id) {
                s.info.state = "connected".to_string();
                s.info.connected_at = Some(now_secs());
                s.info.live_media = live_on;
                s.info.detail = if warn.is_empty() { None } else { Some(warn) };
            }
            let call = guard.as_ref().map(|s| s.info.clone());
            serde_json::json!({"ok": true, "accepted": true,
                "media_answered": answered, "live_media": live_on, "call": call})
            .to_string()
        }
        Err(e) => {
            note_failed(e.clone());
            err_json("accept", e)
        }
    }
}


/// End/decline the active call via its stored end URL.
/// Stops the live media engine first when one is attached.
pub fn call_end_json() -> String {
    crate::live::stop_engine();
    let (url, id) = {
        let guard = lock_current();
        match guard.as_ref() {
            Some(s) if s.info.active() => (s.end_url.clone(), s.info.id.clone()),
            Some(s) => {
                let call = s.info.clone();
                return serde_json::json!({"ok": true, "ended": false, "call": call}).to_string();
            }
            None => return err_json("no_call", "no active call"),
        }
    };
    let url = match url {
        Some(u) => u,
        None => {
            // Outgoing leg placed but never answered: nothing to hang up
            // server-side; just close the slot.
            note_end(Some("no end URL (unanswered leg)".to_string()));
            let call = lock_current().as_ref().map(|s| s.info.clone());
            return serde_json::json!({"ok": true, "ended": true, "call": call}).to_string();
        }
    };
    let skype = match skype_token_string() {
        Ok(t) => t,
        Err(e) => return err_json("auth", e),
    };
    let run = || -> Result<(), String> {
        let rt = rt()?;
        rt.block_on(async {
            let http = http();
            post_empty(&http, &skype, &url).await
        })
    };
    match run() {
        Ok(()) => {
            note_end(None);
            let call = lock_current().as_ref().map(|s| s.info.clone());
            let _ = id;
            serde_json::json!({"ok": true, "ended": true, "call": call}).to_string()
        }
        Err(e) => err_json("end", e),
    }
}

/// Inject the recorder bot into the connected outgoing call
/// (`recording::add_recorder_bot`; transcription/recording start is out
/// of scope — inject only).
pub fn call_record_inject_json() -> String {
    let stored = {
        let guard = lock_current();
        match guard.as_ref() {
            Some(s)
                if s.info.dir == "out"
                    && s.info.state == "connected"
                    && s.info.controller.is_some() =>
            {
                (
                    s.info.id.clone(),
                    s.info.controller.clone().unwrap_or_default(),
                    s.caller_mri.clone(),
                    s.participant_id.clone(),
                    s.endpoint_id.clone(),
                    s.thread_id.clone(),
                    s.display_name.clone(),
                    s.trouter_surl.clone(),
                )
            }
            Some(s) => {
                return err_json(
                    "no_call",
                    format!(
                        "recorder inject needs a connected outgoing call (slot: {} {})",
                        s.info.dir, s.info.state
                    ),
                )
            }
            None => return err_json("no_call", "no active call"),
        }
    };
    let (id, controller, caller_mri, participant_id, endpoint_id, thread_id, display_name, surl) =
        stored;
    let cfg = Config::load_cached().map_err(|e| e.to_string());
    let cfg = match cfg {
        Ok(c) => c,
        Err(e) => return err_json("auth", e),
    };
    let get = |t: Option<ost::auth::StoredToken>| t.filter(|x| !x.is_expired()).map(|x| x.token);
    let (ic3, recorder_tok, skype) = (
        get(cfg.get_ic3_token()),
        get(cfg.get_recorder_token()),
        get(cfg.get_skype_token()),
    );
    let (ic3, recorder_tok, skype) = match (ic3, recorder_tok, skype) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return err_json("auth", "need usable ic3 + recorder + skype tokens"),
    };
    let conv_id = extract_conversation_id(&controller);
    let add_url = derive_add_url(&controller, "addParticipant");
    let chain_id = gen_id();
    let message_id = gen_id();
    let run = || -> Result<usize, String> {
        let rt = rt()?;
        rt.block_on(async {
            let http = http();
            let region = signaling::TeamsRegion::from_config_or_env(&cfg);
            let params = recording::RecordingParams {
                caller_mri: &caller_mri,
                participant_id: &participant_id,
                endpoint_id: &endpoint_id,
                chain_id: &chain_id,
                message_id: &message_id,
                thread_id: &thread_id,
                display_name: &display_name,
                trouter_surl: &surl,
                ic3_token: &ic3,
                recorder_token: &recorder_tok,
                skype_token: &skype,
                conversation_id: &conv_id,
                add_participant_url: &add_url,
                region: &region,
            };
            recording::add_recorder_bot(&http, &params)
                .await
                .map(|b| b.len())
                .map_err(|e| format!("inject: {:#}", e))
        })
    };
    match run() {
        Ok(n) => {
            let mut guard = lock_current();
            if let Some(s) = guard.as_mut().filter(|s| s.info.id == id) {
                s.info.detail = Some("recorder injected".to_string());
            }
            serde_json::json!({"ok": true, "injected": true, "response_bytes": n}).to_string()
        }
        Err(e) => err_json("record", e),
    }
}

// ---------------------------------------------------------------------------
// Outgoing place (+ echo bot)
// ---------------------------------------------------------------------------

struct Acceptance {
    sdp: Option<String>,
    end_url: Option<String>,
    ack_url: Option<String>,
    leg_url: Option<String>,
    rejection: Option<String>,
}

/// Wait for the media answer / callAcceptance on a place-call socket.
/// Trimmed mirror of `call_test::wait_for_call_acceptance` (no logging).
async fn wait_acceptance(
    ws: &mut websocket::TrouterSocket,
    timeout: Duration,
) -> Result<Acceptance, String> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            frame = ws.recv_frame() => {
                let text = frame
                    .map_err(|e| format!("trouter recv: {:#}", e))?
                    .ok_or_else(|| "trouter closed while waiting for answer".to_string())?;
                if text.starts_with("2::") {
                    ws.send_text("2::").await.ok();
                    continue;
                }
                let v = match ost::calling::call_test::extract_call_payload(&text) {
                    Some(v) => v,
                    None => continue,
                };
                if let Some(t) = rejection_text(&v) {
                    return Ok(Acceptance { sdp: None, end_url: None,
                        ack_url: None, leg_url: None, rejection: Some(t) });
                }
                if let Some(t) = end_text(&v) {
                    return Ok(Acceptance { sdp: None, end_url: None,
                        ack_url: None, leg_url: None, rejection: Some(t) });
                }
                if let Some(blob) = v
                    .pointer("/callAcceptance/mediaContent/blob")
                    .or_else(|| v.pointer("/mediaContent/blob"))
                    .or_else(|| v.pointer("/mediaAnswer/mediaContent/blob"))
                    .and_then(|b| b.as_str())
                {
                    let base = if v.get("callAcceptance").is_some() {
                        "/callAcceptance/links"
                    } else {
                        "/links"
                    };
                    let link = |name: &str| {
                        v.pointer(&format!("{}/{}", base, name))
                            .and_then(|u| u.as_str())
                            .map(str::to_string)
                    };
                    return Ok(Acceptance { sdp: Some(blob.to_string()),
                        end_url: link("end"), ack_url: link("acknowledgement"),
                        leg_url: link("callLeg"), rejection: None });
                }
                if v.get("callAcceptance").is_some() {
                    return Ok(Acceptance { sdp: None,
                        end_url: v.pointer("/callAcceptance/links/end")
                            .and_then(|u| u.as_str()).map(str::to_string),
                        ack_url: None, leg_url: None,
                        rejection: Some("accepted without SDP".to_string()) });
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                return Err(format!(
                    "timeout waiting for answer ({}s)", timeout.as_secs()));
            }
        }
    }
}

fn clamp_timeout(secs: i32) -> Duration {
    Duration::from_secs((secs.max(5).min(120)) as u64)
}

/// Place an outgoing call to a thread id (1:1 or channel). Signaling
/// only: epconv place + invite + answer wait + CC ack. No media is set up.
pub fn call_place_json(thread_id: &str, timeout_secs: i32) -> String {
    if thread_id.trim().is_empty() {
        return err_json("arg", "empty thread_id");
    }
    place_inner(
        Some(thread_id.trim()),
        false,
        clamp_timeout(timeout_secs),
        false,
    )
}

/// Place an outgoing call with live media: same signaling as
/// [`call_place_json`], then the media engine (ICE/SRTP/RTP, mic + camera
/// send, speaker + incoming-video queues) attaches to the accepted leg.
pub fn call_place_live_json(thread_id: &str, timeout_secs: i32) -> String {
    if thread_id.trim().is_empty() {
        return err_json("arg", "empty thread_id");
    }
    place_inner(
        Some(thread_id.trim()),
        false,
        clamp_timeout(timeout_secs),
        true,
    )
}

/// Place the echo-bot test call (`UserInitiatedTestCall` via 1:1 epconv
/// + `invite_echo_bot`, same as `ost call --echo` up to the media leg).
pub fn call_echo_json(timeout_secs: i32) -> String {
    place_inner(None, true, clamp_timeout(timeout_secs), false)
}

/// Place the echo-bot test call with live media attached on acceptance.
pub fn call_echo_live_json(timeout_secs: i32) -> String {
    place_inner(None, true, clamp_timeout(timeout_secs), true)
}

fn place_inner(
    thread_override: Option<&str>,
    echo: bool,
    timeout: Duration,
    live: bool,
) -> String {
    {
        let guard = lock_current();
        if let Some(s) = guard.as_ref().filter(|s| s.info.active()) {
            return err_json(
                "busy",
                format!("call {} already active", s.info.id),
            );
        }
    }
    let cfg = match Config::load_cached() {
        Ok(c) => c,
        Err(e) => return err_json("auth", format!("config: {}", e)),
    };
    let get = |t: Option<ost::auth::StoredToken>| t.filter(|x| !x.is_expired()).map(|x| x.token);
    let (skype, ic3) = (get(cfg.get_skype_token()), get(cfg.get_ic3_token()));
    let (skype, ic3) = match (skype, ic3) {
        (Some(s), Some(i)) => (s, i),
        _ => return err_json("auth", "need usable skype + ic3 tokens; sign in first"),
    };
    let region_gtms = match cfg.get_region_gtms() {
        Some(g) => g,
        None => return err_json("auth", "no region_gtms; sign in first"),
    };
    let tenant_id = match cfg.tenant_id.clone() {
        Some(t) => t,
        None => return err_json("auth", "no tenant_id; sign in first"),
    };
    let caller_mri = match extract_mri(&skype) {
        Some(m) => m,
        None => return err_json("auth", "cannot read MRI from skype token"),
    };
    let caller_oid = match caller_mri.strip_prefix("8:orgid:") {
        Some(o) => o.to_string(),
        None => return err_json("auth", "MRI has no 8:orgid: prefix"),
    };
    // Resolve thread + callee before any network.
    let thread_id = if echo {
        signaling::echo_thread_id(&caller_oid)
    } else if let Some(t) = thread_override {
        t.to_string()
    } else {
        return err_json("arg", "empty thread_id");
    };
    let callee_mri = if echo {
        None
    } else {
        extract_callee_oid(&thread_id, &caller_oid).map(|o| format!("8:orgid:{}", o))
    };
    // 1:1 shape only when the thread actually names the caller (else the
    // "callee" guess is junk and this is a channel call).
    let is_1to1 = echo
        || thread_id
            .strip_prefix("19:")
            .and_then(|s| s.strip_suffix("@unq.gbl.spaces"))
            .map(|inner| {
                let mut p = inner.split('_');
                matches!((p.next(), p.next(), p.next()), (Some(a), Some(b), None)
                    if a == caller_oid || b == caller_oid)
            })
            .unwrap_or(false);
    let display_name = display_name_or("(unknown)");
    let epconv_url = match derive_epconv_url(&region_gtms) {
        Some(u) => u,
        None => return err_json("auth", "cannot derive epconv URL from region_gtms"),
    };

    // Mark placing so a racing incoming scan or second place backs off.
    let call_id = gen_id();
    {
        let mut guard = lock_current();
        *guard = Some(StoredCall {
            info: CallInfo {
                id: call_id.clone(),
                dir: "out".to_string(),
                peer: callee_mri.clone().unwrap_or_else(|| {
                    if echo {
                        signaling::ECHO_BOT_MRI.to_string()
                    } else {
                        thread_id.clone()
                    }
                }),
                peer_name: if echo { "Echo (Test Call)".to_string() } else { String::new() },
                thread: thread_id.clone(),
                state: "placing".to_string(),
                controller: None,
                started_at: now_secs(),
                detail: None,
                live_media: false,
                connected_at: None,
            },
            end_url: None,
            notification: None,
            caller_mri: caller_mri.clone(),
            participant_id: String::new(),
            endpoint_id: String::new(),
            thread_id: thread_id.clone(),
            display_name: display_name.clone(),
            trouter_surl: String::new(),
        });
    }

    let run = || -> Result<
        (
            String,
            Option<String>,
            String,
            Option<crate::live::EngineParams>,
        ),
        String,
    > {
        let r = rt()?;
        r.block_on(async {
            let http = http();
            // Trouter leg for the answer wait.
            let (sess, epid) = session::negotiate(&http, &skype)
                .await
                .map_err(|e| format!("trouter negotiate: {:#}", e))?;
            let surl = sess.surl.clone();
            let session_id = session::get_session_id(&http, &sess, &skype, &epid)
                .await
                .map_err(|e| format!("trouter session: {:#}", e))?;
            let mut ws = websocket::TrouterSocket::connect(&sess, &session_id, &epid)
                .await
                .map_err(|e| format!("trouter ws: {:#}", e))?;
            let frame = ws
                .recv_frame()
                .await
                .map_err(|e| format!("trouter handshake: {:#}", e))?;
            if frame.as_deref().map(|f| !f.starts_with("1::")).unwrap_or(true) {
                return Err("trouter handshake failed".to_string());
            }
            if let Some(ref reg_url) = sess.registrar_url {
                registrar::register(&http, &skype, reg_url, &surl)
                    .await
                    .map_err(|e| format!("trouter register: {:#}", e))?;
            }
            // SDP offer (ports bound, never streamed).
            let audio_sock = tokio::net::UdpSocket::bind("0.0.0.0:0")
                .await
                .map_err(|e| format!("udp bind: {}", e))?;
            let video_sock = tokio::net::UdpSocket::bind("0.0.0.0:0")
                .await
                .map_err(|e| format!("udp bind: {}", e))?;
            let audio_port = audio_sock.local_addr().map(|a| a.port()).unwrap_or(0);
            let video_port = video_sock.local_addr().map(|a| a.port()).unwrap_or(0);
            let local_ip = sdp::get_local_ip();
            let host = |port: u16| ice::IceCandidate {
                foundation: "1".to_string(),
                component: 1,
                transport: ice::Transport::Udp,
                priority: 2130706431,
                address: local_ip.clone(),
                port,
                candidate_type: ice::CandidateType::Host,
                raddr: None,
                rport: None,
            };
            let mut audio_cands = vec![host(audio_port)];
            let mut video_cands = vec![host(video_port)];
            // srflx: best-effort, bounded (STUN has its own 2s tries).
            let srflx = async {
                if let Some(c) =
                    ice::gather_srflx_candidate(&audio_sock, ice::DEFAULT_STUN_SERVER).await
                {
                    audio_cands.push(c);
                }
                if let Some(c) =
                    ice::gather_srflx_candidate(&video_sock, ice::DEFAULT_STUN_SERVER).await
                {
                    video_cands.push(c);
                }
            };
            let _ = tokio::time::timeout(Duration::from_secs(10), srflx).await;
            let our_audio_ufrag = sdp::generate_ice_ufrag();
            let our_audio_pwd = sdp::generate_ice_pwd();
            let our_video_ufrag = sdp::generate_ice_ufrag();
            let our_video_pwd = sdp::generate_ice_pwd();
            let video_ssrc = video::generate_ssrc();
            let offer = sdp::generate_av_sdp_offer(&sdp::AvSdpParams {
                local_ip: &local_ip,
                audio_port,
                video_port,
                audio_ufrag: &our_audio_ufrag,
                audio_pwd: &our_audio_pwd,
                video_ufrag: &our_video_ufrag,
                video_pwd: &our_video_pwd,
                audio_candidates: &audio_cands,
                video_candidates: &video_cands,
                video_ssrc_base: video_ssrc,
                audio_ssrc: video::generate_ssrc(),
            });
            // Place.
            let endpoint_id = gen_id();
            let participant_id = gen_id();
            let chain_id = gen_id();
            let message_id = gen_id();
            let region = signaling::TeamsRegion::from_config_or_env(&cfg);
            let params = signaling::ConversationCallParams {
                ic3_token: &ic3,
                trouter_surl: &surl,
                caller_mri: &caller_mri,
                caller_display_name: &display_name,
                endpoint_id: &endpoint_id,
                participant_id: &participant_id,
                thread_id: &thread_id,
                chain_id: &chain_id,
                message_id: &message_id,
                caller_oid: &caller_oid,
                tenant_id: &tenant_id,
                region: &region,
            };
            let controller = if is_1to1 {
                let (created, _) =
                    signaling::create_1to1_call(&http, &epconv_url, &params, &offer.sdp)
                        .await
                        .map_err(|e| format!("place: {:#}", e))?;
                if echo {
                    signaling::invite_echo_bot(&http, &created.conversation_controller, &params)
                        .await
                        .map_err(|e| format!("echo invite: {:#}", e))?;
                } else if let Some(ref mri) = callee_mri {
                    signaling::invite_user(
                        &http,
                        &created.conversation_controller,
                        &params,
                        mri,
                        false,
                    )
                    .await
                    .map_err(|e| format!("invite: {:#}", e))?;
                }
                created.conversation_controller
            } else {
                let created = signaling::create_conversation(&http, &epconv_url, &params)
                    .await
                    .map_err(|e| format!("place phase1: {:#}", e))?;
                signaling::join_conversation_with_sdp(
                    &http,
                    &created.conversation_controller,
                    &params,
                    &offer.sdp,
                )
                .await
                .map_err(|e| format!("place phase2: {:#}", e))?;
                created.conversation_controller
            };
            // Answer wait on our own socket (bg feed has another epid).
            let acc = wait_acceptance(&mut ws, timeout).await?;
            if let Some(rej) = acc.rejection {
                return Err(rej);
            }
            // Phase 3 signaling: ack + CC callbacks (best-effort).
            let mut warns = Vec::new();
            if let Some(ref ack) = acc.ack_url {
                if let Err(e) =
                    signaling::acknowledge_call_acceptance(&http, ack, &params).await
                {
                    warns.push(format!("ack: {:#}", e));
                }
            }
            if let Some(ref leg) = acc.leg_url {
                if let Err(e) = signaling::register_cc_callbacks(&http, leg, &params).await {
                    warns.push(format!("cc callbacks: {:#}", e));
                }
            }
            // Stash leg ids for recorder inject.
            {
                let mut guard = lock_current();
                if let Some(s) = guard.as_mut().filter(|s| s.info.id == call_id) {
                    s.participant_id = participant_id;
                    s.endpoint_id = endpoint_id;
                    s.trouter_surl = surl;
                }
            }
            // Live handoff: sockets (as std, runtime-free) + offer crypto /
            // ICE creds + the answer SDP for the media engine thread.
            let mut warns = warns;
            let handoff = if live {
                match acc.sdp {
                    Some(ref answer) => Some(crate::live::EngineParams {
                        audio_sock: audio_sock
                            .into_std()
                            .map_err(|e| format!("audio sock: {}", e))?,
                        video_sock: video_sock
                            .into_std()
                            .map_err(|e| format!("video sock: {}", e))?,
                        local_audio_crypto: offer.audio_crypto_line.clone(),
                        local_video_crypto: Some(offer.video_crypto_line.clone()),
                        local_audio_ufrag: our_audio_ufrag,
                        local_audio_pwd: our_audio_pwd,
                        local_video_ufrag: Some(our_video_ufrag),
                        local_video_pwd: Some(our_video_pwd),
                        remote_sdp: answer.clone(),
                        controlling: true,
                        video_ssrc,
                        cname: caller_mri.clone(),
                    }),
                    None => {
                        warns.push("accepted without SDP; no live media".to_string());
                        None
                    }
                }
            } else {
                None
            };
            Ok((controller, acc.end_url, warns.join("; "), handoff))
        })
    };

    match run() {
        Ok((controller, end_url, warns, handoff)) => {
            let mut warns = warns;
            let mut live_on = false;
            if let Some(params) = handoff {
                match crate::live::start_engine(params) {
                    Ok(()) => live_on = true,
                    Err(e) => {
                        if warns.is_empty() {
                            warns = format!("live media failed: {}", e);
                        } else {
                            warns = format!("{}; live media failed: {}", warns, e);
                        }
                    }
                }
            }
            let mut guard = lock_current();
            if let Some(s) = guard.as_mut().filter(|s| s.info.id == call_id) {
                s.info.state = "connected".to_string();
                s.info.connected_at = Some(now_secs());
                s.info.controller = Some(controller);
                s.end_url = end_url;
                s.info.live_media = live_on;
                s.info.detail = if warns.is_empty() { None } else { Some(warns) };
            }
            let call = guard.as_ref().map(|s| s.info.clone());
            serde_json::json!({"ok": true, "placed": true, "accepted": true,
                "live_media": live_on, "call": call})
                .to_string()
        }
        Err(e) => {
            // Rejection (callee said no) vs failure (transport/auth): the
            // wait maps both through here; rejections read as failed legs.
            let mut guard = lock_current();
            if let Some(s) = guard.as_mut().filter(|s| s.info.id == call_id) {
                if s.info.active() {
                    crate::live::reset_call_mute(); // mute is per call
                }
                s.info.state = "failed".to_string();
                s.info.detail = Some(e.clone());
            }
            serde_json::json!({"ok": true, "placed": true, "accepted": false,
                "rejection": e,
                "call": guard.as_ref().map(|s| s.info.clone())})
            .to_string()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network, slot isolated per test)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const INVITE: &str = r#"{
        "callInvitation": {
            "callModalities": ["Audio"],
            "links": {
                "acceptance": "https://c.example/accept",
                "end": "https://c.example/end",
                "mediaAnswer": "https://c.example/answer"
            },
            "mediaContent": {"blob": "v=0", "contentType": "application/sdp"}
        },
        "participants": {"from": {
            "id": "8:orgid:aaa", "displayName": "Doe, Jane",
            "endpointId": "ep1", "languageId": "en-US"}},
        "debugContent": {"callId": "call-1"}
    }"#;

    #[test]
    fn status_empty_slot_is_null() {
        let _t = test_lock();
        clear_current();
        let v: serde_json::Value = serde_json::from_str(&call_status_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["call"].is_null());
    }

    #[test]
    fn scan_incoming_rings_and_parks_duplicate() {
        let _t = test_lock();
        clear_current();
        let ev = scan_events(&[INVITE.to_string()]);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].kind, "incoming");
        assert_eq!(ev[0].call_id, "call-1");
        assert_eq!(ev[0].peer_name, "Doe, Jane");
        let v: serde_json::Value = serde_json::from_str(&call_status_json()).unwrap();
        assert_eq!(v["call"]["state"], "ringing");
        assert_eq!(v["call"]["dir"], "in");
        // Duplicate invite while ringing: no second event, slot kept.
        let ev2 = scan_events(&[INVITE.to_string()]);
        assert!(ev2.is_empty());
        clear_current();
    }

    #[test]
    fn scan_incoming_inside_args_envelope() {
        let _t = test_lock();
        clear_current();
        let wrapped = format!(
            r#"{{"name":"notify","args":[{}]}}"#,
            INVITE.replace('\n', " ")
        );
        let ev = scan_events(&[wrapped]);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].kind, "incoming");
        clear_current();
    }

    #[test]
    fn scan_end_closes_active_call() {
        let _t = test_lock();
        clear_current();
        scan_events(&[INVITE.to_string()]);
        let ev = scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string(),
        ]);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].kind, "end");
        let v: serde_json::Value = serde_json::from_str(&call_status_json()).unwrap();
        assert_eq!(v["call"]["state"], "ended");
        clear_current();
    }

    #[test]
    fn scan_end_args_first_and_first_hit_wins() {
        // Inline-scan refactor pin: args[] beats top level, one hit
        // stops the scan (same order as the old cands Vec).
        let _t = test_lock();
        clear_current();
        scan_events(&[INVITE.to_string()]);
        let ev = scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"TOP"},"args":[{"x":1},{"callEnd":{"code":486,"subCode":0,"phrase":"ARGS"}}]}"#
                .to_string(),
        ]);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].kind, "end");
        assert!(ev[0].detail.as_deref().unwrap_or("").contains("ARGS"));
        clear_current();
    }

    #[test]
    fn scan_end_without_call_is_silent() {
        let _t = test_lock();
        clear_current();
        let ev = scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string(),
        ]);
        assert!(ev.is_empty());
    }

    #[test]
    fn scan_rejection_fails_active_call() {
        let _t = test_lock();
        clear_current();
        scan_events(&[INVITE.to_string()]);
        let ev = scan_events(&[
            r#"{"sessionRejection":{"code":486,"subCode":0,"phrase":"Busy"}}"#.to_string(),
        ]);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].kind, "rejected");
        let v: serde_json::Value = serde_json::from_str(&call_status_json()).unwrap();
        assert_eq!(v["call"]["state"], "failed");
        clear_current();
    }

    #[test]
    fn non_call_frames_scan_clean() {
        let _t = test_lock();
        clear_current();
        let ev = scan_events(&[
            r#"{"name":"trouter.connected","args":[]}"#.to_string(),
            r#"{"content":"hi","messagetype":"Text"}"#.to_string(),
            "not json".to_string(),
        ]);
        assert!(ev.is_empty());
        clear_current();
    }

    #[test]
    fn scan_values_matches_scan_events() {
        // Parse-once guard: the Values path must emit exactly what the
        // string path emits across every nest shape (counts, no timings).
        let _t = test_lock();
        let invite_obj: serde_json::Value = serde_json::from_str(INVITE).unwrap();
        let seq = vec![
            INVITE.to_string(),
            format!(
                r#"{{"name":"notify","args":[{}]}}"#,
                INVITE.replace('\n', " ")
            ),
            serde_json::json!({"name": "notify", "args": [INVITE]}).to_string(),
            serde_json::json!({"body": invite_obj.clone()}).to_string(),
            serde_json::json!({"body": INVITE}).to_string(),
            serde_json::json!({"data": invite_obj}).to_string(),
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string(),
            r#"{"name":"trouter.connected","args":[]}"#.to_string(),
            "not json".to_string(),
        ];
        clear_current();
        let a = scan_events(&seq);
        let va: Vec<serde_json::Value> =
            a.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
        clear_current();
        let values: Vec<serde_json::Value> = seq
            .iter()
            .filter_map(|s| serde_json::from_str(s).ok())
            .collect();
        let b = scan_values(&values);
        let vb: Vec<serde_json::Value> =
            b.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
        assert_eq!(va, vb);
        assert_eq!(va.len(), 2); // incoming + end; dups parked, noise silent
        assert_eq!(va[0]["kind"], "incoming");
        assert_eq!(va[1]["kind"], "end");
        clear_current();
    }

    #[test]
    fn mri_from_jwt_skypeid_and_oid() {
        // {"skypeid":"orgid:aaa"} / {"oid":"bbb"} (b64url, no padding).
        let with_skypeid = "h.eyJza3lwZWlkIjoib3JnaWQ6YWFhIn0.s";
        assert_eq!(
            extract_mri(with_skypeid).as_deref(),
            Some("8:orgid:aaa")
        );
        let with_oid = "h.eyJvaWQiOiJiYmIifQ.s";
        assert_eq!(extract_mri(with_oid).as_deref(), Some("8:orgid:bbb"));
        assert_eq!(extract_mri("not-a-jwt"), None);
        assert_eq!(extract_mri(""), None);
    }

    #[test]
    fn callee_oid_picks_non_caller() {
        let t = "19:aaa_bbb@unq.gbl.spaces";
        assert_eq!(extract_callee_oid(t, "aaa").as_deref(), Some("bbb"));
        assert_eq!(extract_callee_oid(t, "bbb").as_deref(), Some("aaa"));
        assert_eq!(extract_callee_oid("19:only@unq.gbl.spaces", "aaa"), None);
        assert_eq!(extract_callee_oid("junk", "aaa"), None);
    }

    #[test]
    fn epconv_prefers_service_url_then_derives() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"calling_conversationServiceUrl":"https://c/ep"}"#).unwrap();
        assert_eq!(derive_epconv_url(&v).as_deref(), Some("https://c/ep"));
        let v2: serde_json::Value = serde_json::from_str(
            r#"{"calling_potentialCallRequestUrl":"https://h/api/v2/cc/v1/potentialcall"}"#,
        )
        .unwrap();
        assert_eq!(
            derive_epconv_url(&v2).as_deref(),
            Some("https://h/api/v2/epconv")
        );
        assert_eq!(derive_epconv_url(&serde_json::json!({})), None);
    }

    #[test]
    fn add_url_keeps_query() {
        assert_eq!(
            derive_add_url("https://h/conv/x?a=1", "addParticipant"),
            "https://h/conv/x/addParticipant?a=1"
        );
        assert_eq!(
            derive_add_url("https://h/conv/x/", "add"),
            "https://h/conv/x/add"
        );
    }

    #[test]
    fn echo_thread_shape() {
        assert_eq!(
            signaling::echo_thread_id("aaa"),
            "19:aaa_cf28171e-fcfd-47e4-a1d6-79460b0b3ca0@unq.gbl.spaces"
        );
    }

    #[test]
    fn place_empty_thread_rejected_without_network() {
        for bad in ["", "   "] {
            for f in [call_place_json(bad, 30), call_place_live_json(bad, 30)] {
                let v: serde_json::Value = serde_json::from_str(&f).unwrap();
                assert_eq!(v["ok"], false);
                assert_eq!(v["error"], "arg");
            }
        }
    }

    #[test]
    fn accept_end_inject_without_slot_are_errors() {
        let _t = test_lock();
        clear_current();
        for f in [
            call_accept_json(),
            call_accept_live_json(),
            call_end_json(),
            call_record_inject_json(),
        ] {
            let v: serde_json::Value = serde_json::from_str(&f).unwrap();
            assert_eq!(v["ok"], false);
        }
        let v: serde_json::Value = serde_json::from_str(&call_accept_json()).unwrap();
        assert_eq!(v["error"], "no_incoming");
        let v: serde_json::Value = serde_json::from_str(&call_accept_live_json()).unwrap();
        assert_eq!(v["error"], "no_incoming");
        let v: serde_json::Value = serde_json::from_str(&call_end_json()).unwrap();
        assert_eq!(v["error"], "no_call");
    }

    /// CORE-C: mute resets when an active call ends (per call), a
    /// between-calls toggle is kept, and `connected_at` stays absent until
    /// the call connects (no network: ring → callEnd frame).
    #[test]
    fn core_c_mute_resets_per_call_and_connected_at_absent_until_connect() {
        let _t = test_lock();
        clear_current();
        let was = crate::live::muted();
        scan_events(&[INVITE.to_string()]);
        let v: serde_json::Value = serde_json::from_str(&call_status_json()).unwrap();
        assert!(v["call"].get("connected_at").is_none());
        crate::live::call_mute_json(true);
        scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string(),
        ]);
        assert!(!crate::live::muted(), "mute must not carry into the next call");
        // Toggle between calls (pre-join) survives a no-op terminal read.
        crate::live::call_mute_json(true);
        scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string(),
        ]);
        assert!(crate::live::muted(), "no active call ended: keep pre-join mute");
        crate::live::call_mute_json(was);
        clear_current();
    }

    #[test]
    fn clamp_timeout_bounds() {
        assert_eq!(clamp_timeout(0), Duration::from_secs(5));
        assert_eq!(clamp_timeout(30), Duration::from_secs(30));
        assert_eq!(clamp_timeout(9999), Duration::from_secs(120));
    }
}
