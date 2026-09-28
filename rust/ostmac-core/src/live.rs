//! Live media engine — the `run_call_test` media path joined to the Call UI.
//!
//! Signaling (`calls.rs`) places the call; this module owns everything after
//! the SDP answer: ICE, SRTP, RTP send/recv loops, and the two Swift joins:
//! - send: Swift AVCapture -> VideoToolbox encode -> `video_send_push` NAL
//!   queue -> packetizer -> SRTP -> UDP (black IDR fallback when idle).
//! - recv: UDP -> SRTP -> depacketize -> access-unit framing (MS PACSI /
//!   prefix NALs stripped) -> `video_incoming_poll` queue -> Swift
//!   VideoToolbox decode -> SwiftUI display.
//!
//! Audio rides the same engine via cpal (`ost::calling::audio`): mic capture
//! when a device exists, 1kHz tone fallback, speaker render, echo record.
//!
//! The engine runs on its own OS thread + tokio runtime (media cannot live
//! on the shared `rt()`: `block_on` there is synchronous per call). Loops
//! poll a shutdown flag on 500ms recv timeouts so `stop` joins within ~1s.

use std::collections::VecDeque;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use base64::Engine;
use serde::Serialize;

use ost::calling::{ice, rtp, rtcp, sdp, srtp, test_tone, video};

use crate::{err_json, now_secs, string_to_c};

// ---------------------------------------------------------------------------
// Queues (FFI <-> engine)
// ---------------------------------------------------------------------------

/// One send-side access unit from Swift (raw NALs, no start codes).
#[derive(Debug, Clone)]
pub struct SendUnit {
    pub nals: Vec<Vec<u8>>,
}

/// One recv-side access unit for Swift (PACSI/prefix stripped).
#[derive(Debug, Clone)]
pub struct RecvUnit {
    pub nals: Vec<Vec<u8>>,
}

/// Max queued send units (drop-oldest past this; Swift paces at ~15fps).
pub const SEND_QUEUE_CAP: usize = 8;
/// Max queued recv units (drop-oldest; SwiftUI drains at display pace).
pub const RECV_QUEUE_CAP: usize = 4;
/// Max decoded NAL bytes accepted over FFI per push (4 MiB).
pub const MAX_SEND_BYTES: usize = 4 * 1024 * 1024;

fn send_queue() -> &'static Mutex<VecDeque<SendUnit>> {
    static S: OnceLock<Mutex<VecDeque<SendUnit>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn recv_queue() -> &'static Mutex<VecDeque<RecvUnit>> {
    static S: OnceLock<Mutex<VecDeque<RecvUnit>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn lock<T>(m: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// Tests run threaded but the queues are global: queue-touching tests hold
// this guard (plus the calls slot guard) so they never interleave.
#[cfg(test)]
fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static T: OnceLock<Mutex<()>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

static SEND_DROPPED: AtomicU64 = AtomicU64::new(0);
static RECV_DROPPED: AtomicU64 = AtomicU64::new(0);

fn push_send(unit: SendUnit) -> usize {
    let mut q = lock(send_queue());
    if q.len() >= SEND_QUEUE_CAP {
        q.pop_front();
        SEND_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    q.push_back(unit);
    q.len()
}

/// Take the newest send unit, dropping older ones (live pacing: never lag).
fn take_send_latest() -> Option<SendUnit> {
    let mut q = lock(send_queue());
    let unit = q.pop_back()?;
    let stale = q.len() as u64;
    if stale > 0 {
        q.clear();
        SEND_DROPPED.fetch_add(stale, Ordering::Relaxed);
    }
    Some(unit)
}

fn push_recv(unit: RecvUnit) {
    let mut q = lock(recv_queue());
    if q.len() >= RECV_QUEUE_CAP {
        q.pop_front();
        RECV_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    q.push_back(unit);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize)]
pub struct LiveStats {
    pub running: bool,
    pub audio_sent: u32,
    pub audio_recv: u32,
    pub video_sent: u32,
    pub video_recv: u32,
    pub send_queued: usize,
    pub send_dropped: u64,
    pub recv_pending: usize,
    pub recv_dropped: u64,
    pub ice_audio: String,
    pub ice_video: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub started_at: u64,
    /// True while the mic is muted (send loop emits silence; sticky).
    pub muted: bool,
    /// Effective speaker route: named device, or None = system default.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    /// Last speaker-reroute failure (cleared by the next success).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker_error: Option<String>,
}

fn engine_stats() -> &'static Mutex<LiveStats> {
    static S: OnceLock<Mutex<LiveStats>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(LiveStats::default()))
}

// ---------------------------------------------------------------------------
// NAL helpers
// ---------------------------------------------------------------------------

fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1F).unwrap_or(0)
}

/// MS-H264PF wrappers the VT decoder must not see: PACSI (30), prefix (14).
fn is_wrapper_nal(nal: &[u8]) -> bool {
    matches!(nal_type(nal), 14 | 30)
}

// ---------------------------------------------------------------------------
// Framed NAL payloads (byte+len FFI ABI, om-s3-mediahot)
// ---------------------------------------------------------------------------

/// Length-prefixed NAL framing, both directions:
/// `u32LE nal_count (1..=32)`, then per NAL `u32LE len + raw bytes`.
/// Total payload must fit [`MAX_SEND_BYTES`]. Swift mirrors this layout
/// (`NalFraming`) — the base64/JSON path is gone.
pub fn frame_nals(nals: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + nals.len() * 4 + nals.iter().map(Vec::len).sum::<usize>());
    out.extend_from_slice(&(nals.len() as u32).to_le_bytes());
    for nal in nals {
        out.extend_from_slice(&(nal.len() as u32).to_le_bytes());
        out.extend_from_slice(nal);
    }
    out
}

/// Parse [`frame_nals`] output. Same limits as the old JSON path:
/// 1..=32 NALs, each 1..=MAX_SEND_BYTES, total <= MAX_SEND_BYTES.
pub fn unframe_nals(data: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if data.len() < 4 {
        return Err("NAL payload too short".to_string());
    }
    let n = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
    if n == 0 || n > 32 {
        return Err(format!("need 1..=32 NALs, got {}", n));
    }
    let mut nals = Vec::with_capacity(n);
    let mut off = 4usize;
    let mut total = 0usize;
    for i in 0..n {
        if off + 4 > data.len() {
            return Err(format!("nal {} truncated", i));
        }
        let len = u32::from_le_bytes(data[off..off + 4].try_into().unwrap()) as usize;
        off += 4;
        if len == 0 || len > MAX_SEND_BYTES {
            return Err(format!("nal {} bad size {}", i, len));
        }
        if off + len > data.len() {
            return Err(format!("nal {} truncated", i));
        }
        total += len;
        if total > MAX_SEND_BYTES {
            return Err(format!("unit too large: {} bytes", total));
        }
        nals.push(data[off..off + len].to_vec());
        off += len;
    }
    if off != data.len() {
        return Err(format!("{} trailing bytes", data.len() - off));
    }
    Ok(nals)
}

// ---------------------------------------------------------------------------
// JSON bodies: send queue / incoming queue / stats
// ---------------------------------------------------------------------------

/// Push one send-side access unit: framed NALs (no start codes).
/// Over-cap pushes drop the oldest unit (still `{ok:true}`).
pub fn video_send_push_bytes_json(data: &[u8]) -> String {
    let nals = match unframe_nals(data) {
        Ok(n) => n,
        Err(e) => return err_json("arg", e),
    };
    let queued = push_send(SendUnit { nals });
    serde_json::json!({"ok": true, "queued": queued}).to_string()
}

/// Drain the newest recv-side access unit (older ones count as dropped).
/// Returns the framed payload (empty when none), the stale count, and
/// whether an AU is present. All-wrapper AUs read as absent, as before.
pub fn video_incoming_poll_raw() -> (Vec<u8>, usize, bool) {
    // Pop under the lock; filter + frame outside it so the mutex is
    // never held across AU-sized allocs/copies.
    let (au, stale) = {
        let mut q = lock(recv_queue());
        let au = q.pop_back();
        let stale = q.len();
        if stale > 0 {
            q.clear();
            RECV_DROPPED.fetch_add(stale as u64, Ordering::Relaxed);
        }
        (au, stale)
    };
    let nals = au.map(|u| {
        u.nals
            .iter()
            .filter(|n| !is_wrapper_nal(n))
            .cloned()
            .collect::<Vec<_>>()
    });
    match nals {
        Some(nals) if !nals.is_empty() => (frame_nals(&nals), stale, true),
        _ => (Vec::new(), stale, false),
    }
}

/// Live engine stats (idle `{ok:true, running:false, ...}` when stopped).
pub fn call_media_json() -> String {
    let mut s = lock(engine_stats()).clone();
    s.send_queued = lock(send_queue()).len();
    s.recv_pending = lock(recv_queue()).len();
    s.send_dropped = SEND_DROPPED.load(Ordering::Relaxed);
    s.recv_dropped = RECV_DROPPED.load(Ordering::Relaxed);
    s.muted = muted();
    s.speaker = lock(effective_speaker()).clone();
    s.speaker_error = lock(speaker_error_slot()).clone();
    serde_json::json!({"ok": true, "media": s}).to_string()
}

// ---------------------------------------------------------------------------
// Offline loopback: the (c)->packetize->SRTP->depacketize->(b) join, no net.
// ---------------------------------------------------------------------------

fn loopback_material(tag: u32, fill: u8) -> Result<srtp::SrtpKeyingMaterial, String> {
    let raw = vec![fill; 30];
    let b64 = base64::engine::general_purpose::STANDARD.encode(&raw);
    let line = format!(
        "a=crypto:{} AES_CM_128_HMAC_SHA1_80 inline:{}|2^31",
        tag, b64
    );
    srtp::parse_crypto_line(&line).map_err(|e| format!("{:#}", e))
}

/// Run every queued send unit through the real engine data path —
/// packetize -> SRTP protect/unprotect -> RTP decode -> depacketize -> AU
/// framing — and push the resulting AUs to the incoming queue. Returns
/// `{ok, units, packets, aus, nals}`. No network, no auth, no hardware.
pub fn live_loopback_json() -> String {
    let units: Vec<SendUnit> = {
        let mut q = lock(send_queue());
        let mut v = Vec::with_capacity(q.len());
        while let Some(u) = q.pop_front() {
            v.push(u);
        }
        v
    };
    if units.is_empty() {
        return err_json("empty", "send queue is empty; push NALs first");
    }
    let mat_a = loopback_material(1, 0x11).unwrap();
    let mat_b = loopback_material(2, 0x22).unwrap();
    let mut ctx_send = srtp::create_context(&mat_a, &mat_b).unwrap();
    let mut ctx_recv = srtp::create_context(&mat_b, &mat_a).unwrap();
    let mut packetizer = video::VideoPacketizer::new(0x51ab_0001);
    let mut depacketizer = video::VideoDepacketizer::new();

    let mut packets = 0usize;
    let mut aus = 0usize;
    let mut nals_out = 0usize;
    for unit in &units {
        let rtp_packets = packetizer.packetize_frame(&unit.nals);
        let mut au: Vec<Vec<u8>> = Vec::new();
        for pkt in &rtp_packets {
            packets += 1;
            let wire = match srtp::protect(&mut ctx_send, pkt) {
                Ok(p) => p,
                Err(e) => return err_json("srtp", format!("protect: {:#}", e)),
            };
            let back = match srtp::unprotect(&mut ctx_recv, &wire) {
                Ok(p) => p,
                Err(e) => return err_json("srtp", format!("unprotect: {:#}", e)),
            };
            let decoded = match rtp::decode(&back) {
                Ok(p) => p,
                Err(e) => return err_json("rtp", format!("decode: {:#}", e)),
            };
            match depacketizer.depacketize(&decoded.payload, decoded.marker) {
                Ok(Some(nal)) => {
                    if !is_wrapper_nal(&nal) {
                        nals_out += 1;
                        au.push(nal);
                    }
                    if decoded.marker && !au.is_empty() {
                        push_recv(RecvUnit { nals: std::mem::take(&mut au) });
                        aus += 1;
                    }
                }
                Ok(None) => {}
                Err(e) => return err_json("depacketize", format!("{:#}", e)),
            }
        }
        if !au.is_empty() {
            // No marker seen (single-NAL units): still deliver the AU.
            push_recv(RecvUnit { nals: au });
            aus += 1;
        }
    }
    serde_json::json!({
        "ok": true, "units": units.len(), "packets": packets,
        "aus": aus, "nals": nals_out,
    })
    .to_string()
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Everything the engine needs after the SDP answer lands.
pub struct EngineParams {
    pub audio_sock: std::net::UdpSocket,
    pub video_sock: std::net::UdpSocket,
    pub local_audio_crypto: String,
    pub local_video_crypto: Option<String>,
    pub local_audio_ufrag: String,
    pub local_audio_pwd: String,
    pub local_video_ufrag: Option<String>,
    pub local_video_pwd: Option<String>,
    pub remote_sdp: String,
    pub controlling: bool,
    pub video_ssrc: u32,
    pub cname: String,
}

struct EngineHandle {
    shutdown: std::sync::Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn engine_slot() -> &'static Mutex<Option<EngineHandle>> {
    static S: OnceLock<Mutex<Option<EngineHandle>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

pub fn engine_running() -> bool {
    lock(engine_slot()).is_some()
}

/// Start the live media engine on its own thread. Idempotent-busy: errors
/// when an engine is already running.
pub fn start_engine(p: EngineParams) -> Result<(), String> {
    {
        if lock(engine_slot()).is_some() {
            return Err("live media already running".to_string());
        }
    }
    // Fresh stats + drained queues for the new call.
    *lock(engine_stats()) = LiveStats {
        running: true,
        started_at: now_secs(),
        ..Default::default()
    };
    lock(send_queue()).clear();
    lock(recv_queue()).clear();

    let shutdown = std::sync::Arc::new(AtomicBool::new(false));
    let flag = shutdown.clone();
    let thread = std::thread::Builder::new()
        .name("ostmac-live-media".to_string())
        .spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(r) => r,
                Err(e) => {
                    lock(engine_stats()).error = Some(format!("runtime: {}", e));
                    return;
                }
            };
            rt.block_on(drive(p, flag));
        })
        .map_err(|e| format!("spawn media thread: {}", e))?;
    *lock(engine_slot()) = Some(EngineHandle {
        shutdown,
        thread: Some(thread),
    });
    Ok(())
}

/// Signal stop and join the engine thread (loops poll the flag on 500ms
/// recv timeouts, so this returns in ~1s).
pub fn stop_engine() -> LiveStats {
    let handle = lock(engine_slot()).take();
    if let Some(mut h) = handle {
        h.shutdown.store(true, Ordering::Relaxed);
        if let Some(t) = h.thread.take() {
            let _ = t.join();
        }
    }
    let mut s = lock(engine_stats());
    s.running = false;
    s.clone()
}

pub fn call_media_stop_json() -> String {
    let s = stop_engine();
    serde_json::json!({"ok": true, "media": s}).to_string()
}

// ---------------------------------------------------------------------------
// In-call controls (om-call-ux): mute + speaker select
// ---------------------------------------------------------------------------

/// Process-wide mic mute. Read by the audio send loop (emits digital
/// silence while set). Per call: `reset_call_mute` clears it when an
/// active call ends/fails, so a new call never inherits the last call's
/// mute; a toggle made between calls (pre-join) still applies to the next
/// call. No hardware touched — safe headless.
static MUTED: AtomicBool = AtomicBool::new(false);

/// Requested speaker (`None` = system default). Read once at engine start;
/// mid-call changes arrive via [`speaker_request`] and are applied by the
/// audio recv task without stalling it.
fn preferred_speaker() -> &'static Mutex<Option<String>> {
    static S: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Pending mid-call reroute (`None` = no request). `Some(None)` = back to
/// the system default.
fn speaker_request() -> &'static Mutex<Option<Option<String>>> {
    static S: OnceLock<Mutex<Option<Option<String>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Effective route (`None` = system default or no device). Written by the
/// engine only; surfaced in stats so the UI can confirm a switch.
fn effective_speaker() -> &'static Mutex<Option<String>> {
    static S: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

fn speaker_error_slot() -> &'static Mutex<Option<String>> {
    static S: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

pub fn muted() -> bool {
    MUTED.load(Ordering::Relaxed)
}

/// Clear the mic mute at call end (spec: mute resets per call). Called by
/// `calls` when an active call reaches ended/failed.
pub fn reset_call_mute() {
    MUTED.store(false, Ordering::Relaxed);
}

/// Set mic mute. `{ok:true, muted}`. Applies to the live engine when one
/// runs; otherwise stored and honored by the next call.
pub fn call_mute_json(muted: bool) -> String {
    MUTED.store(muted, Ordering::Relaxed);
    serde_json::json!({"ok": true, "muted": muted}).to_string()
}

/// Request a speaker route (`None`/empty = system default).
/// `{ok:true, speaker}`. Stored always (the next engine start honors it);
/// when an engine runs, a reroute is queued and the audio task applies it
/// without dropping the current device on failure.
pub fn call_speaker_json(name: Option<&str>) -> String {
    let want = name
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    *lock(preferred_speaker()) = want.clone();
    if engine_running() {
        *lock(speaker_request()) = Some(want.clone());
    }
    serde_json::json!({"ok": true, "speaker": want}).to_string()
}

fn take_speaker_request() -> Option<Option<String>> {
    lock(speaker_request()).take()
}

/// Open the requested output, falling back to the system default.
/// Returns (guard, tx, effective-name-or-None-for-default).
fn open_speaker(
    want: Option<&str>,
) -> (
    Option<ost::calling::audio::AudioPlayback>,
    Option<std::sync::mpsc::SyncSender<Vec<i16>>>,
    Option<String>,
) {
    if let Some(name) = want {
        if let Some((pb, tx)) = ost::calling::audio::AudioPlayback::start_on(Some(name)) {
            return (Some(pb), Some(tx), Some(name.to_string()));
        }
    }
    match ost::calling::audio::AudioPlayback::start() {
        Some((pb, tx)) => (Some(pb), Some(tx), None),
        None => (None, None, None),
    }
}

/// Finished background device open: the request plus the new route (None
/// = the device would not open; the old route stays).
type SpeakerOpen = (
    Option<String>,
    Option<(
        ost::calling::audio::AudioPlayback,
        std::sync::mpsc::SyncSender<Vec<i16>>,
    )>,
);

/// One non-blocking step of the mid-call speaker reroute (runs each audio
/// recv iteration): start a blocking-pool open for a pending request, then
/// collect a finished open — swap on success, keep the old device and
/// record `speaker_error` on failure.
fn pump_speaker(
    opening: &mut Option<tokio::sync::oneshot::Receiver<SpeakerOpen>>,
    playback: &mut Option<ost::calling::audio::AudioPlayback>,
    tx: &mut Option<std::sync::mpsc::SyncSender<Vec<i16>>>,
) {
    if opening.is_none() {
        if let Some(want) = take_speaker_request() {
            let (os_tx, os_rx) = tokio::sync::oneshot::channel::<SpeakerOpen>();
            *opening = Some(os_rx);
            tokio::task::spawn_blocking(move || {
                let opened = match want.as_deref() {
                    Some(name) => ost::calling::audio::AudioPlayback::start_on(Some(name)),
                    None => ost::calling::audio::AudioPlayback::start(),
                };
                let _ = os_tx.send((want, opened));
            });
        }
    }
    if let Some(rx) = opening.as_mut() {
        if let Ok((want, opened)) = rx.try_recv() {
            *opening = None;
            match opened {
                Some((pb, new_tx)) => {
                    *playback = Some(pb);
                    *tx = Some(new_tx);
                    *lock(effective_speaker()) = want;
                    *lock(speaker_error_slot()) = None;
                }
                None => {
                    let label = want.clone().unwrap_or_else(|| "(default)".to_string());
                    *lock(speaker_error_slot()) = Some(format!(
                        "cannot open speaker {}; keeping current route",
                        label
                    ));
                }
            }
        }
    }
}

fn stat_add(f: impl FnOnce(&mut LiveStats)) {
    f(&mut lock(engine_stats()));
}

fn stat_set_ice(audio: String, video: String) {
    let mut s = lock(engine_stats());
    s.ice_audio = audio;
    s.ice_video = video;
}

fn stat_error(e: String) {
    let mut s = lock(engine_stats());
    s.error = Some(e);
}

async fn drive(p: EngineParams, shutdown: std::sync::Arc<AtomicBool>) {
    if let Err(e) = drive_inner(p, shutdown).await {
        stat_error(e);
    }
    stat_add(|s| s.running = false);
}

async fn drive_inner(p: EngineParams, shutdown: std::sync::Arc<AtomicBool>) -> Result<(), String> {
    use tokio::sync::Mutex as AMutex;

    let audio_sock = std::sync::Arc::new(
        tokio::net::UdpSocket::from_std(p.audio_sock).map_err(|e| format!("audio sock: {}", e))?,
    );
    let video_sock = std::sync::Arc::new(
        tokio::net::UdpSocket::from_std(p.video_sock).map_err(|e| format!("video sock: {}", e))?,
    );

    let remote = sdp::parse_sdp_offer(&p.remote_sdp).map_err(|e| format!("remote SDP: {:#}", e))?;

    // SRTP contexts (local offer/answer crypto + remote crypto).
    let local_audio_mat =
        srtp::parse_crypto_line(&p.local_audio_crypto).map_err(|e| format!("audio crypto: {:#}", e))?;
    let remote_audio_mat = remote
        .crypto_lines
        .iter()
        .find_map(|l| srtp::parse_crypto_line(l).ok())
        .ok_or_else(|| "no audio crypto in remote SDP".to_string())?;
    let audio_ctx = std::sync::Arc::new(AMutex::new(
        srtp::create_context(&local_audio_mat, &remote_audio_mat)
            .map_err(|e| format!("audio srtp: {:#}", e))?,
    ));

    let video_pair: Option<(std::sync::Arc<AMutex<srtp::SrtpContext>>, String, String)> =
        match (&p.local_video_crypto, &remote.video) {
            (Some(local_line), Some(vid)) => {
                let local_mat = srtp::parse_crypto_line(local_line)
                    .map_err(|e| format!("video crypto: {:#}", e))?;
                let remote_mat = vid
                    .crypto_lines
                    .iter()
                    .find_map(|l| srtp::parse_crypto_line(l).ok())
                    .ok_or_else(|| "no video crypto in remote SDP".to_string())?;
                let ctx = srtp::create_context(&local_mat, &remote_mat)
                    .map_err(|e| format!("video srtp: {:#}", e))?;
                Some((
                    std::sync::Arc::new(AMutex::new(ctx)),
                    p.local_video_ufrag.clone().unwrap_or_default(),
                    p.local_video_pwd.clone().unwrap_or_default(),
                ))
            }
            _ => None,
        };

    // ICE (bounded: stop-aware).
    let audio_cands = ice::parse_candidates_from_sdp(&p.remote_sdp);
    let audio_agent = ice::IceAgent::new(
        ice::IceCredentials {
            ufrag: p.local_audio_ufrag.clone(),
            pwd: p.local_audio_pwd.clone(),
        },
        ice::IceCredentials {
            ufrag: remote.ice_ufrag.clone(),
            pwd: remote.ice_pwd.clone(),
        },
        p.controlling,
    );
    let ice_fut = audio_agent.check_connectivity(audio_sock.clone(), &audio_cands);
    let audio_remote = tokio::select! {
        r = ice_fut => r.map(|c| c.remote_addr).unwrap_or_else(|_| {
            ice::select_remote_candidate(&audio_cands)
                .unwrap_or_else(|| "127.0.0.1:9".parse().unwrap())
        }),
        _ = wait_shutdown(&shutdown) => return Ok(()),
    };
    stat_set_ice(audio_remote.to_string(), String::new());

    let video_remote: Option<std::net::SocketAddr> = if video_pair.is_some() {
        let vid_cands = ice::parse_candidates_from_sdp_section(&p.remote_sdp, "video");
        let vid = remote.video.as_ref().cloned().unwrap();
        let vid_agent = ice::IceAgent::new(
            ice::IceCredentials {
                ufrag: p.local_video_ufrag.clone().unwrap_or_default(),
                pwd: p.local_video_pwd.clone().unwrap_or_default(),
            },
            ice::IceCredentials {
                ufrag: vid.ice_ufrag,
                pwd: vid.ice_pwd,
            },
            p.controlling,
        );
        let ice_fut = vid_agent.check_connectivity(video_sock.clone(), &vid_cands);
        let addr = tokio::select! {
            r = ice_fut => r.map(|c| Some(c.remote_addr)).unwrap_or_else(|_| {
                ice::select_remote_candidate(&vid_cands)
            }),
            _ = wait_shutdown(&shutdown) => return Ok(()),
        };
        if let Some(a) = addr {
            let mut s = lock(engine_stats());
            s.ice_video = a.to_string();
        }
        addr
    } else {
        None
    };

    // Audio devices (cpal; tone fallback when no mic). The in-call
    // window's requested speaker wins; unknown names fall back to the
    // system default and stats carry the reason.
    let (_capture, mic_rx) = ost::calling::audio::AudioCapture::start()
        .map(|(c, rx)| (Some(c), Some(rx)))
        .unwrap_or((None, None));
    let want = lock(preferred_speaker()).clone();
    let (_playback, speaker_tx, effective) = open_speaker(want.as_deref());
    *lock(effective_speaker()) = effective;
    if want.is_some() && lock(effective_speaker()).is_none() && speaker_tx.is_some() {
        *lock(speaker_error_slot()) = Some(format!(
            "unknown speaker {:?}; using system default",
            want.unwrap_or_default()
        ));
    } else {
        *lock(speaker_error_slot()) = None;
    }
    // The mic guard lives for the whole drive; the playback guard moves
    // into the audio recv task so mid-call reroutes can swap it.
    let _mic_guard = _capture;

    let send_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpSendStats::default()));
    let recv_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpRecvStats::default()));
    let remote_ssrc = std::sync::Arc::new(AMutex::new(0u32));
    let vid_send_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpSendStats::default()));
    let vid_recv_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpRecvStats::default()));
    let vid_remote_ssrc = std::sync::Arc::new(AMutex::new(0u32));
    let dyn_remote = std::sync::Arc::new(AMutex::new(audio_remote));
    let recorder = std::sync::Arc::new(AMutex::new(test_tone::AudioRecorder::new(8 * 8000)));

    let ssrc = (now_secs() as u32) ^ 0x51ab_0000;
    send_stats.lock().await.ssrc = ssrc;
    vid_send_stats.lock().await.ssrc = p.video_ssrc;

    let mut tasks = Vec::new();

    // -- audio send (mic > tone, 20ms) --
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let stats = send_stats.clone();
        let dyn_remote = dyn_remote.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut tone = test_tone::ToneGenerator::new();
            let mut seq: u16 = 0;
            let mut ts: u32 = 0;
            let mut interval = tokio::time::interval(Duration::from_millis(20));
            while !flag.load(Ordering::Relaxed) {
                interval.tick().await;
                // Muted calls emit digital silence (μ-law 0xFF after the
                // linear map below) — the peer hears nothing, timing stays.
                let samples = if muted() {
                    vec![0i16; rtp::SAMPLES_PER_PACKET]
                } else {
                    match mic_rx.as_ref().and_then(|rx| rx.try_recv().ok()) {
                        Some(s) if s.len() == rtp::SAMPLES_PER_PACKET => s,
                        _ => tone.next_frame(),
                    }
                };
                let payload: Vec<u8> =
                    samples.iter().map(|&s| rtp::linear_to_ulaw(s)).collect();
                let rtp_pkt = rtp::encode(rtp::PT_PCMU, seq, ts, ssrc, &payload);
                let wire = {
                    let mut c = ctx.lock().await;
                    srtp::protect(&mut c, &rtp_pkt)
                };
                if let Ok(wire) = wire {
                    let addr = *dyn_remote.lock().await;
                    if socket.send_to(&wire, addr).await.is_ok() {
                        let mut st = stats.lock().await;
                        st.packets_sent += 1;
                        st.bytes_sent += payload.len() as u32;
                        st.last_rtp_timestamp = ts;
                        stat_add(|s| s.audio_sent += 1);
                    }
                }
                seq = seq.wrapping_add(1);
                ts = ts.wrapping_add(160);
            }
        }));
    }

    // -- audio recv (STUN/SRTCP/RTP; speaker + echo record) --
    // Owns the playback guard so the in-call speaker picker can reroute
    // mid-call (see pump_speaker: background open, swap on success).
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let stats = recv_stats.clone();
        let rssrc = remote_ssrc.clone();
        let rec = recorder.clone();
        let dyn_remote = dyn_remote.clone();
        let local_pwd = p.local_audio_pwd.clone();
        let flag = shutdown.clone();
        let mut _playback = _playback;
        let mut speaker_tx = speaker_tx;
        tasks.push(tokio::spawn(async move {
            let mut buf = [0u8; 2048];
            let mut opening: Option<tokio::sync::oneshot::Receiver<SpeakerOpen>> = None;
            while !flag.load(Ordering::Relaxed) {
                pump_speaker(&mut opening, &mut _playback, &mut speaker_tx);
                let got = tokio::time::timeout(
                    Duration::from_millis(500),
                    socket.recv_from(&mut buf),
                )
                .await;
                let (len, from) = match got {
                    Ok(Ok(v)) => v,
                    _ => continue,
                };
                let data = &buf[..len];
                if len >= 20 && ice::is_stun_message(data) {
                    if ice::is_stun_request(data) {
                        if let Some(txn) = ice::get_transaction_id(data) {
                            let resp = ice::build_binding_response(
                                &txn,
                                from,
                                Some(local_pwd.as_bytes()),
                            );
                            let _ = socket.send_to(&resp, from).await;
                        }
                        let mut dr = dyn_remote.lock().await;
                        *dr = from;
                    }
                    continue;
                }
                if let Ok(rtcp_data) = {
                    let mut c = ctx.lock().await;
                    srtp::unprotect_rtcp(&mut c, data).map_err(|_| ())
                } {
                    for block in rtcp::parse_rtcp(&rtcp_data) {
                        if let rtcp::RtcpBlock::SenderReport { ntp_timestamp, .. } = block {
                            let mut rs = stats.lock().await;
                            rs.last_sr_ntp = ((ntp_timestamp >> 16) & 0xFFFF_FFFF) as u32;
                            rs.last_sr_recv_time = Some(std::time::Instant::now());
                        }
                    }
                    continue;
                }
                let rtp_data = {
                    let mut c = ctx.lock().await;
                    srtp::unprotect(&mut c, data)
                };
                let rtp_data = match rtp_data {
                    Ok(d) => d,
                    Err(_) => continue,
                };
                if let Ok(pkt) = rtp::decode(&rtp_data) {
                    {
                        let mut rs = stats.lock().await;
                        rs.packets_received += 1;
                        if pkt.sequence_number as u32 > rs.highest_seq {
                            rs.highest_seq = pkt.sequence_number as u32;
                        }
                    }
                    stat_add(|s| s.audio_recv += 1);
                    {
                        let mut r = rssrc.lock().await;
                        if *r == 0 {
                            *r = pkt.ssrc;
                        }
                    }
                    let samples: Vec<i16> =
                        pkt.payload.iter().map(|&b| rtp::ulaw_to_linear(b)).collect();
                    rec.lock().await.push_frame(&samples);
                    if let Some(ref tx) = speaker_tx {
                        let _ = tx.try_send(samples);
                    }
                }
            }
        }));
    }

    // -- audio RTCP (5s, 250ms-granular shutdown) --
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let ss = send_stats.clone();
        let rs = recv_stats.clone();
        let rssrc = remote_ssrc.clone();
        let dyn_remote = dyn_remote.clone();
        let cname = p.cname.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut ticks = 0u32;
            while !flag.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(250)).await;
                ticks += 1;
                if ticks < 20 {
                    continue;
                }
                ticks = 0;
                let s = ss.lock().await.clone();
                let r = rs.lock().await.clone();
                let remote = *rssrc.lock().await;
                let pkt = if s.packets_sent > 0 {
                    rtcp::build_sender_report(&s, &r, remote, &cname)
                } else {
                    rtcp::build_receiver_report(s.ssrc, &r, remote, &cname)
                };
                let mut c = ctx.lock().await;
                if let Ok(wire) = srtp::protect_rtcp(&mut c, &pkt) {
                    let addr = *dyn_remote.lock().await;
                    let _ = socket.send_to(&wire, addr).await;
                }
            }
        }));
    }

    // -- video send (NAL queue > black IDR, ~15fps) --
    if let (Some(vctx), Some(vaddr)) =
        (video_pair.as_ref().map(|(c, _, _)| c.clone()), video_remote)
    {
        let socket = video_sock.clone();
        let stats = vid_send_stats.clone();
        let vssrc = p.video_ssrc;
        let vctx_send = vctx.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut packetizer = video::VideoPacketizer::new(vssrc);
            let mut interval =
                tokio::time::interval(Duration::from_millis(video::FRAME_INTERVAL_MS));
            while !flag.load(Ordering::Relaxed) {
                interval.tick().await;
                let nals = take_send_latest()
                    .map(|u| u.nals)
                    .unwrap_or_else(video::generate_black_iframe);
                for rtp_pkt in packetizer.packetize_frame(&nals) {
                    let ts = if rtp_pkt.len() >= 8 {
                        u32::from_be_bytes([rtp_pkt[4], rtp_pkt[5], rtp_pkt[6], rtp_pkt[7]])
                    } else {
                        0
                    };
                    let paylen = rtp_pkt.len().saturating_sub(rtp::RTP_HEADER_SIZE);
                    let wire = {
                        let mut c = vctx_send.lock().await;
                        srtp::protect(&mut c, &rtp_pkt)
                    };
                    if let Ok(wire) = wire {
                        if socket.send_to(&wire, vaddr).await.is_ok() {
                            let mut st = stats.lock().await;
                            st.packets_sent += 1;
                            st.bytes_sent += paylen as u32;
                            st.last_rtp_timestamp = ts;
                            stat_add(|s| s.video_sent += 1);
                        }
                    }
                }
            }
        }));

        // -- video recv (SRTP -> depacketize -> AU framing -> incoming queue) --
        {
            let socket = video_sock.clone();
            let vctx = vctx.clone();
            let stats = vid_recv_stats.clone();
            let rssrc = vid_remote_ssrc.clone();
            let vid_pwd = video_pair.as_ref().map(|(_, _, pwd)| pwd.clone()).unwrap_or_default();
            let flag = shutdown.clone();
            tasks.push(tokio::spawn(async move {
                let mut buf = [0u8; 2048];
                let mut depacketizer = video::VideoDepacketizer::new();
                let mut au: Vec<Vec<u8>> = Vec::new();
                while !flag.load(Ordering::Relaxed) {
                    let got = tokio::time::timeout(
                        Duration::from_millis(500),
                        socket.recv_from(&mut buf),
                    )
                    .await;
                    let (len, from) = match got {
                        Ok(Ok(v)) => v,
                        _ => continue,
                    };
                    let data = &buf[..len];
                    if len >= 20 && ice::is_stun_message(data) {
                        if ice::is_stun_request(data) {
                            if let Some(txn) = ice::get_transaction_id(data) {
                                let resp = ice::build_binding_response(
                                    &txn,
                                    from,
                                    Some(vid_pwd.as_bytes()),
                                );
                                let _ = socket.send_to(&resp, from).await;
                            }
                        }
                        continue;
                    }
                    {
                        let mut c = vctx.lock().await;
                        if let Ok(rtcp_data) = srtp::unprotect_rtcp(&mut c, data) {
                            let mut rs = stats.lock().await;
                            for block in rtcp::parse_rtcp(&rtcp_data) {
                                if let rtcp::RtcpBlock::SenderReport { ntp_timestamp, .. } =
                                    block
                                {
                                    rs.last_sr_ntp =
                                        ((ntp_timestamp >> 16) & 0xFFFF_FFFF) as u32;
                                    rs.last_sr_recv_time = Some(std::time::Instant::now());
                                }
                            }
                            continue;
                        }
                    }
                    let rtp_data = {
                        let mut c = vctx.lock().await;
                           srtp::unprotect(&mut c, data)
                    };
                    let rtp_data = match rtp_data {
                        Ok(d) => d,
                        Err(_) => continue,
                    };
                    if let Ok(pkt) = rtp::decode(&rtp_data) {
                        {
                            let mut rs = stats.lock().await;
                            rs.packets_received += 1;
                            if pkt.sequence_number as u32 > rs.highest_seq {
                                rs.highest_seq = pkt.sequence_number as u32;
                            }
                        }
                        stat_add(|s| s.video_recv += 1);
                        {
                            let mut r = rssrc.lock().await;
                            if *r == 0 {
                                *r = pkt.ssrc;
                            }
                        }
                        match depacketizer.depacketize(&pkt.payload, pkt.marker) {
                            Ok(Some(nal)) => {
                                if !is_wrapper_nal(&nal) {
                                    au.push(nal);
                                }
                                if pkt.marker && !au.is_empty() {
                                    push_recv(RecvUnit { nals: std::mem::take(&mut au) });
                                }
                            }
                            Ok(None) => {}
                            Err(_) => {}
                        }
                    }
                }
            }));
        }

        // -- video RTCP (5s) --
        {
            let socket = video_sock.clone();
            let stats = vid_send_stats.clone();
            let rs = vid_recv_stats.clone();
            let rssrc = vid_remote_ssrc.clone();
            let cname = p.cname.clone();
            let flag = shutdown.clone();
            tasks.push(tokio::spawn(async move {
                let mut ticks = 0u32;
                while !flag.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    ticks += 1;
                    if ticks < 20 {
                        continue;
                    }
                    ticks = 0;
                    let s = stats.lock().await.clone();
                    let r = rs.lock().await.clone();
                    let remote = *rssrc.lock().await;
                    let pkt = if s.packets_sent > 0 {
                        rtcp::build_sender_report(&s, &r, remote, &cname)
                    } else {
                        rtcp::build_receiver_report(s.ssrc, &r, remote, &cname)
                    };
                    let mut c = vctx.lock().await;
                    if let Ok(wire) = srtp::protect_rtcp(&mut c, &pkt) {
                        let _ = socket.send_to(&wire, vaddr).await;
                    }
                }
            }));
        }
    }

    // Park until shutdown, then abort loops.
    wait_shutdown(&shutdown).await;
    for t in &tasks {
        t.abort();
    }
    Ok(())
}

async fn wait_shutdown(flag: &std::sync::Arc<AtomicBool>) {
    while !flag.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

// ---------------------------------------------------------------------------
// C ABI (caller frees every return with `ostmac_free`)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn ostmac_video_send_push_bytes(data: *const u8, len: usize) -> *mut c_char {
    if data.is_null() && len > 0 {
        return string_to_c(err_json("arg", "null NAL payload"));
    }
    let bytes = if len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    string_to_c(video_send_push_bytes_json(bytes))
}

#[no_mangle]
pub extern "C" fn ostmac_video_poll_incoming_bytes(
    out: *mut *mut u8,
    out_len: *mut usize,
    dropped: *mut c_int,
) -> c_int {
    if out.is_null() || out_len.is_null() || dropped.is_null() {
        return -1;
    }
    let (payload, stale, has) = video_incoming_poll_raw();
    unsafe {
        *dropped = stale as c_int;
        if has {
            let boxed = payload.into_boxed_slice();
            *out_len = boxed.len();
            *out = Box::into_raw(boxed) as *mut u8;
            1
        } else {
            *out = std::ptr::null_mut();
            *out_len = 0;
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn ostmac_call_media() -> *mut std::os::raw::c_char {
    string_to_c(call_media_json())
}

#[no_mangle]
pub extern "C" fn ostmac_call_media_stop() -> *mut std::os::raw::c_char {
    string_to_c(call_media_stop_json())
}

#[no_mangle]
pub extern "C" fn ostmac_live_loopback() -> *mut std::os::raw::c_char {
    string_to_c(live_loopback_json())
}

#[no_mangle]
pub extern "C" fn ostmac_call_mute(muted: std::os::raw::c_int) -> *mut std::os::raw::c_char {
    string_to_c(call_mute_json(muted != 0))
}

#[no_mangle]
pub extern "C" fn ostmac_call_speaker(
    name: *const std::os::raw::c_char,
) -> *mut std::os::raw::c_char {
    match crate::opt_cstr_to_string(name) {
        Ok(n) => string_to_c(call_speaker_json(n.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network/auth/hardware; queues drained per test)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn drain_queues() {
        lock(send_queue()).clear();
        lock(recv_queue()).clear();
    }

    fn framed(nals: &[Vec<u8>]) -> Vec<u8> {
        frame_nals(nals)
    }

    #[test]
    fn framing_roundtrips_and_bounds_overhead() {
        let nals = vec![vec![0x67u8, 0x42], vec![0x68u8], vec![0x65u8, 0, 1, 2, 3]];
        let payload: usize = nals.iter().map(Vec::len).sum();
        let f = framed(&nals);
        // Overhead is exactly count + per-NAL length prefixes (perf guard).
        assert_eq!(f.len(), 4 + 4 * nals.len() + payload);
        assert_eq!(unframe_nals(&f).unwrap(), nals);
        // Malformed payloads reject without panicking.
        assert!(unframe_nals(&[]).is_err());
        assert!(unframe_nals(&[1, 0, 0]).is_err());
        assert!(unframe_nals(&0u32.to_le_bytes()).is_err()); // zero NALs
        assert!(unframe_nals(&33u32.to_le_bytes()).is_err()); // too many
        let mut trunc = f.clone();
        trunc.pop();
        assert!(unframe_nals(&trunc).is_err());
        let mut trailing = f.clone();
        trailing.push(0);
        assert!(unframe_nals(&trailing).is_err());
    }

    #[test]
    fn send_push_validates_args() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // Too short / zero NALs / truncated length.
        for bad in [vec![], 0u32.to_le_bytes().to_vec(), vec![1, 0, 0]] {
            let v: serde_json::Value =
                serde_json::from_str(&video_send_push_bytes_json(&bad)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        // Empty NAL body.
        let mut empty_nal = 1u32.to_le_bytes().to_vec();
        empty_nal.extend_from_slice(&0u32.to_le_bytes());
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_bytes_json(&empty_nal)).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "arg");
        drain_queues();
    }

    #[test]
    fn send_push_caps_drop_oldest() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let one = framed(&[vec![0x67, 0x42, 0x00]]);
        for _ in 0..(SEND_QUEUE_CAP + 3) {
            let v: serde_json::Value =
                serde_json::from_str(&video_send_push_bytes_json(&one)).unwrap();
            assert_eq!(v["ok"], true);
        }
        assert_eq!(lock(send_queue()).len(), SEND_QUEUE_CAP);
        drain_queues();
    }

    #[test]
    fn incoming_poll_null_then_latest() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let (payload, stale, has) = video_incoming_poll_raw();
        assert!(!has);
        assert!(payload.is_empty());
        assert_eq!(stale, 0);
        // Wrapper NALs (PACSI 30, prefix 14) are stripped for VT.
        push_recv(RecvUnit {
            nals: vec![vec![0x1E, 0x00], vec![0x0E, 0x00], vec![0x67, 0x42]],
        });
        let (payload, _, has) = video_incoming_poll_raw();
        assert!(has);
        assert_eq!(unframe_nals(&payload).unwrap(), vec![vec![0x67, 0x42]]);
        let (_, _, has) = video_incoming_poll_raw();
        assert!(!has);
        drain_queues();
    }

    #[test]
    fn loopback_black_frame_roundtrips() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // Black IDR [SPS, PPS, IDR] through the real engine data path.
        let nals: Vec<Vec<u8>> = video::generate_black_iframe();
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_bytes_json(&framed(&nals))).unwrap();
        assert_eq!(v["ok"], true);
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["units"], 1);
        assert!(v["packets"].as_u64().unwrap() >= 5); // PACSI + prefix + 3 NALs
        assert_eq!(v["aus"], 1);
        assert_eq!(v["nals"], 3); // SPS + PPS + IDR (wrappers stripped)
        // The AU is pollable for the Swift decode join.
        let (payload, _, has) = video_incoming_poll_raw();
        assert!(has);
        let got = unframe_nals(&payload).unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[0], nals[0]); // SPS bit-identical
        assert_eq!(got[2], nals[2]); // IDR bit-identical
        drain_queues();
    }

    #[test]
    fn loopback_fragmented_slice_reassembles() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // 4000-byte IDR slice forces FU-A fragmentation across RTP packets.
        let mut idr = vec![0x65u8];
        idr.extend((0..3999u32).map(|i| (i % 251) as u8));
        let sps = vec![0x67u8, 0x42, 0x00, 0x1E];
        let pps = vec![0x68u8, 0xCE, 0x06, 0xE2];
        let arr = vec![sps, pps, idr];
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_bytes_json(&framed(&arr))).unwrap();
        assert_eq!(v["ok"], true);
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["packets"].as_u64().unwrap() >= 5);
        assert_eq!(v["aus"], 1);
        let (payload, _, has) = video_incoming_poll_raw();
        assert!(has);
        let got = unframe_nals(&payload).unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[2], arr[2]); // reassembled IDR bit-identical
        drain_queues();
    }

    #[test]
    fn loopback_empty_queue_is_error() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "empty");
    }

    #[test]
    fn media_stats_idle_shape() {
        let v: serde_json::Value = serde_json::from_str(&call_media_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["media"]["running"], false);
        assert!(v["media"]["audio_sent"].is_number());
        assert!(v["media"]["video_recv"].is_number());
        assert!(v["media"]["muted"].is_boolean()); // race-safe: shape only
    }

    #[test]
    fn mute_roundtrips_without_hardware() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        let was = muted();
        let v: serde_json::Value = serde_json::from_str(&call_mute_json(true)).unwrap();
        assert_eq!(v, serde_json::json!({"ok": true, "muted": true}));
        assert!(muted());
        let v: serde_json::Value = serde_json::from_str(&call_mute_json(false)).unwrap();
        assert_eq!(v["muted"], false);
        assert!(!muted());
        // Stats mirror the flag with no engine running.
        let v: serde_json::Value = serde_json::from_str(&call_media_json()).unwrap();
        assert_eq!(v["media"]["muted"], false);
        call_mute_json(was); // restore (sticky across tests)
    }

    #[test]
    fn mute_frame_is_ulaw_silence() {
        // The muted send path emits zeros; μ-law 0 maps to 0xFF silence.
        assert_eq!(ost::calling::rtp::linear_to_ulaw(0), 0xFF);
    }

    #[test]
    fn speaker_select_stores_and_reports() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        assert!(!engine_running()); // idle: stored only, no reroute queued
        let v: serde_json::Value =
            serde_json::from_str(&call_speaker_json(Some("External Headphones"))).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"ok": true, "speaker": "External Headphones"})
        );
        assert!(take_speaker_request().is_none()); // idle engines take none
        assert_eq!(
            *lock(preferred_speaker()),
            Some("External Headphones".to_string())
        );
        // Empty/blank resets to the system default.
        let v: serde_json::Value = serde_json::from_str(&call_speaker_json(Some("  "))).unwrap();
        assert!(v["speaker"].is_null());
        assert_eq!(*lock(preferred_speaker()), None);
        let v: serde_json::Value = serde_json::from_str(&call_speaker_json(None)).unwrap();
        assert!(v["speaker"].is_null());
    }

    #[test]
    fn ffi_mute_speaker_shapes() {
        use std::os::raw::c_char;
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        unsafe {
            let p = ostmac_call_mute(1);
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&s).unwrap()["muted"],
                true
            );
            let p = ostmac_call_mute(0);
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&s).unwrap()["muted"],
                false
            );
            // NULL = system default.
            let p = ostmac_call_speaker(std::ptr::null());
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["speaker"].is_null());
            let name = CString::new("Built-in Output").unwrap();
            let p = ostmac_call_speaker(name.as_ptr() as *const c_char);
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&s).unwrap()["speaker"],
                "Built-in Output"
            );
        }
        call_speaker_json(None); // restore default
        call_mute_json(false);
    }

    #[test]
    fn media_stop_idle_is_ok() {
        let v: serde_json::Value = serde_json::from_str(&call_media_stop_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["media"]["running"], false);
    }

    #[test]
    fn ffi_push_null_is_arg_error() {
        unsafe {
            let p = ostmac_video_send_push_bytes(std::ptr::null(), 8);
            assert!(!p.is_null());
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_poll_roundtrip_shape() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        unsafe {
            let one = framed(&[vec![0x67, 0x42]]);
            let p = ostmac_video_send_push_bytes(one.as_ptr(), one.len());
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["ok"], true);
            let p = ostmac_live_loopback();
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["aus"], 1);
            let mut out: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut dropped: c_int = -1;
            let rc = ostmac_video_poll_incoming_bytes(&mut out, &mut out_len, &mut dropped);
            assert_eq!(rc, 1);
            assert_eq!(dropped, 0);
            let payload = std::slice::from_raw_parts(out, out_len).to_vec();
            crate::ostmac_bytes_free(out, out_len);
            assert_eq!(unframe_nals(&payload).unwrap().len(), 1);
            // Drained: second poll reports none.
            let rc = ostmac_video_poll_incoming_bytes(&mut out, &mut out_len, &mut dropped);
            assert_eq!(rc, 0);
            assert!(out.is_null());
            // Null out-params are a hard -1.
            assert_eq!(
                ostmac_video_poll_incoming_bytes(
                    std::ptr::null_mut(),
                    &mut out_len,
                    &mut dropped
                ),
                -1
            );
        }
        drain_queues();
    }
}
