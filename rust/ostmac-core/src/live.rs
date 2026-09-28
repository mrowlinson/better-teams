//! Live media engine — the `run_call_test` media path joined to the Call UI.
//!
//! Signaling (`calls.rs`) places the call; this module owns everything after
//! the SDP answer: ICE, SRTP, RTP send/recv loops, and the two Swift joins:
//! - send: Swift AVCapture -> VideoToolbox encode -> `video_send_push` NAL
//!   queue -> packetizer -> SRTP -> UDP (camera off: no video RTP at all).
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
/// Max queued recv units per queue (~1 s at 30 fps). The host decodes
/// every unit in order (P-frames need their references); overflow drops
/// whole GOPs, never a lone reference frame (see [`GopQueue`]).
pub const RECV_QUEUE_CAP: usize = 30;
/// Max queued recv bytes per queue.
pub const RECV_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;
/// Max decoded NAL bytes accepted over FFI per push (4 MiB).
pub const MAX_SEND_BYTES: usize = 4 * 1024 * 1024;
/// A recv queue polled within this window has a live decoder.
const CONSUMER_WINDOW_MS: u64 = 1_000;
/// Min spacing of keyframe requests for one queue.
const KEYFRAME_REQUEST_GAP_MS: u64 = 1_000;

fn send_queue() -> &'static Mutex<VecDeque<SendUnit>> {
    static S: OnceLock<Mutex<VecDeque<SendUnit>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn recv_queue() -> &'static Mutex<GopQueue> {
    static S: OnceLock<Mutex<GopQueue>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(GopQueue::new()))
}

/// An access unit a decoder can start from: it carries an SPS or an IDR
/// slice.
fn is_keyframe(unit: &RecvUnit) -> bool {
    unit.nals.iter().any(|n| matches!(nal_type(n), 5 | 7))
}

fn unit_bytes(unit: &RecvUnit) -> usize {
    unit.nals.iter().map(Vec::len).sum()
}

/// A decoder-safe receive queue: FIFO, so the host decodes every access
/// unit in order. It starts (and restarts after an overflow or packet
/// loss) at a keyframe: units that cannot decode without a missing
/// reference are dropped instead of smearing. Overflow keeps the newest
/// run that starts at a keyframe, else empties and waits for the next
/// keyframe. While a polled (live) queue waits, it asks for a keyframe
/// at most once per [`KEYFRAME_REQUEST_GAP_MS`].
struct GopQueue {
    q: VecDeque<RecvUnit>,
    bytes: usize,
    awaiting_key: bool,
    /// Units dropped since the host's last poll.
    dropped: usize,
    last_poll_ms: u64,
    last_key_request_ms: u64,
}

impl GopQueue {
    fn new() -> Self {
        GopQueue {
            q: VecDeque::new(),
            bytes: 0,
            awaiting_key: true,
            dropped: 0,
            last_poll_ms: 0,
            last_key_request_ms: 0,
        }
    }

    fn clear(&mut self) {
        *self = GopQueue::new();
    }

    fn drop_units(&mut self, n: usize) {
        self.dropped += n;
        RECV_DROPPED.fetch_add(n as u64, Ordering::Relaxed);
    }

    /// A keyframe request is due: a decoder polls this queue and the
    /// last request is older than the gap.
    fn want_key(&mut self, now: u64) -> bool {
        let consumed = self.last_poll_ms > 0
            && now.saturating_sub(self.last_poll_ms) <= CONSUMER_WINDOW_MS;
        if consumed && now.saturating_sub(self.last_key_request_ms) >= KEYFRAME_REQUEST_GAP_MS {
            self.last_key_request_ms = now;
            true
        } else {
            false
        }
    }

    /// Queue one access unit. True = request a keyframe from the sender now.
    fn push(&mut self, unit: RecvUnit, now: u64) -> bool {
        if self.awaiting_key && !is_keyframe(&unit) {
            self.drop_units(1);
            return self.want_key(now);
        }
        self.awaiting_key = false;
        self.bytes += unit_bytes(&unit);
        self.q.push_back(unit);
        if self.q.len() <= RECV_QUEUE_CAP && self.bytes <= RECV_QUEUE_MAX_BYTES {
            return false;
        }
        match self.q.iter().rposition(is_keyframe) {
            Some(i) if i > 0 => {
                for u in self.q.drain(..i) {
                    self.bytes -= unit_bytes(&u);
                }
                self.drop_units(i);
                false
            }
            _ => {
                let n = self.q.len();
                self.q.clear();
                self.bytes = 0;
                self.awaiting_key = true;
                self.drop_units(n);
                self.want_key(now)
            }
        }
    }

    /// Packet loss inside the next unit: drop it and everything after it
    /// until a keyframe. True = request a keyframe now.
    fn lose(&mut self, now: u64) -> bool {
        self.awaiting_key = true;
        self.drop_units(1);
        self.want_key(now)
    }

    /// The oldest queued unit plus the units dropped since the last poll.
    fn pop(&mut self, now: u64) -> (Option<RecvUnit>, usize) {
        self.last_poll_ms = now;
        let u = self.q.pop_front();
        if let Some(ref u) = u {
            self.bytes -= unit_bytes(u);
        }
        (u, std::mem::take(&mut self.dropped))
    }
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

/// Take every queued send unit, oldest first. Each one goes out: the
/// receiver's decoder needs every frame an encoder chained (dropping one
/// smears the peer's picture until the next keyframe). Nothing queued
/// (camera off) sends nothing: no black filler, as Teams sends no video
/// while the camera is off.
fn take_send_all() -> Vec<SendUnit> {
    lock(send_queue()).drain(..).collect()
}

/// Queue a 1:1 access unit. True = request a keyframe now.
fn push_recv(unit: RecvUnit) -> bool {
    lock(recv_queue()).push(unit, now_ms())
}

// ---------------------------------------------------------------------------
// Per-source recv queues + source subscription (meeting video, MS-RTP)
// ---------------------------------------------------------------------------
//
// A conference mixer forwards each subscribed video source on its own
// SSRC and lists the source's MSI as the first CSRC (MS-RTP 2.2.1:
// mixer packets carry MSI in the CSRC list). The recv loop reassembles
// per SSRC and files each access unit under its source key: the CSRC
// MSI, else the MSI this client subscribed into that SSRC slot, else the
// SSRC itself (1:1 peers). The host polls one queue per visible tile.
//
// Subscriptions go out as Video Source Requests (RTCP PSFB FMT=15, AFB
// type 1): one per slot, "SSRC of media source" = the remote side's
// x-ssrc-range base + slot index, retransmitted 4x at 190 ms then 5x at
// 3 s (MS-RTP 3.2). With no host subscription, slot 0 asks SOURCE_ANY
// (the sender picks: the 1:1 peer, or the mixer's active speaker).

/// One source's queue (a [`GopQueue`], like the 1:1 queue).
struct SourceQueue {
    q: GopQueue,
    frames: u64,
    last_ms: u64,
}

/// Max tracked sources (least recently fed evicted past this).
pub const MAX_SOURCES: usize = 16;
/// Max subscribed sources (tiles with live video).
pub const MAX_SUBSCRIPTIONS: usize = 9;
/// MS-RTP MSI: the receiver requests no source.
pub const SOURCE_NONE: u32 = 0xFFFF_FFFF;
/// MS-RTP MSI: the sender selects the source.
pub const SOURCE_ANY: u32 = 0xFFFF_FFFE;
/// Reserved queue key (never a subscribed MSI): someone else's shared
/// screen, received on the applicationsharing-video leg.
pub const SOURCE_SHARE: u32 = 0xFFFF_FFFD;

fn source_queues() -> &'static Mutex<std::collections::HashMap<u32, SourceQueue>> {
    static S: OnceLock<Mutex<std::collections::HashMap<u32, SourceQueue>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The source's queue (created on its first unit; the least recently fed
/// source is evicted past [`MAX_SOURCES`]), with its delivery stamped.
fn source_entry(map: &mut std::collections::HashMap<u32, SourceQueue>, key: u32) -> &mut SourceQueue {
    if !map.contains_key(&key) && map.len() >= MAX_SOURCES {
        if let Some(old) = map.iter().min_by_key(|(_, s)| s.last_ms).map(|(k, _)| *k) {
            map.remove(&old);
        }
    }
    let s = map.entry(key).or_insert_with(|| SourceQueue {
        q: GopQueue::new(),
        frames: 0,
        last_ms: 0,
    });
    s.frames += 1;
    s.last_ms = now_ms();
    s
}

/// File one source's access unit. True = request a keyframe now.
fn push_source(key: u32, unit: RecvUnit) -> bool {
    let mut map = lock(source_queues());
    source_entry(&mut map, key).q.push(unit, now_ms())
}

/// A source's next unit lost packets: it and its dependents are dropped
/// until a keyframe. True = request a keyframe now.
fn lose_source(key: u32) -> bool {
    let mut map = lock(source_queues());
    source_entry(&mut map, key).q.lose(now_ms())
}

/// Take the oldest access unit of one source (FIFO: the host decodes
/// every unit), as [`video_incoming_poll_raw`] does for the 1:1 queue.
/// The count is units dropped (overflow, loss) since the last poll.
pub fn video_source_poll_raw(key: u32) -> (Vec<u8>, usize, bool) {
    let (au, dropped) = {
        let mut map = lock(source_queues());
        match map.get_mut(&key) {
            Some(s) => s.q.pop(now_ms()),
            None => (None, 0),
        }
    };
    let nals = au.map(|u| u.nals.into_iter().filter(|n| !is_wrapper_nal(n)).collect::<Vec<_>>());
    match nals {
        Some(nals) if !nals.is_empty() => (frame_nals(&nals), dropped, true),
        _ => (Vec::new(), dropped, false),
    }
}

/// Sources that delivered video this call: `{ok, sources:[{id, frames,
/// age_ms}]}` (id = MSI or SSRC, see the section note).
pub fn video_sources_json() -> String {
    let now = now_ms();
    let map = lock(source_queues());
    let mut list: Vec<_> = map
        .iter()
        .map(|(k, s)| serde_json::json!({"id": k, "frames": s.frames,
            "age_ms": now.saturating_sub(s.last_ms)}))
        .collect();
    list.sort_by_key(|v| v["id"].as_u64().unwrap_or(0));
    serde_json::json!({"ok": true, "sources": list}).to_string()
}

/// Host-wanted source MSIs in priority order (slot 0 first) + a version
/// the VSR task watches.
struct Subscriptions {
    wanted: Vec<u32>,
    version: u64,
}

fn subscriptions() -> &'static Mutex<Subscriptions> {
    static S: OnceLock<Mutex<Subscriptions>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(Subscriptions { wanted: Vec::new(), version: 0 }))
}

/// Set the subscribed video sources (MSIs, priority order; deduped,
/// capped at [`MAX_SUBSCRIPTIONS`]; reserved MSIs dropped). Empty =
/// SOURCE_ANY on slot 0. Takes effect on the running engine within ~50 ms.
pub fn video_subscribe_json(msis: &[u32]) -> String {
    let mut wanted: Vec<u32> = Vec::new();
    for m in msis {
        if *m != SOURCE_NONE && *m != SOURCE_ANY && *m != SOURCE_SHARE && !wanted.contains(m) && wanted.len() < MAX_SUBSCRIPTIONS {
            wanted.push(*m);
        }
    }
    let mut s = lock(subscriptions());
    if s.wanted != wanted {
        s.wanted = wanted.clone();
        s.version += 1;
    }
    serde_json::json!({"ok": true, "subscribed": wanted}).to_string()
}

/// The effective per-slot MSIs: the host's list, or SOURCE_ANY alone.
fn effective_slots(wanted: &[u32]) -> Vec<u32> {
    if wanted.is_empty() {
        vec![SOURCE_ANY]
    } else {
        wanted.to_vec()
    }
}

/// Source key for a received packet (see the section note).
pub fn source_key(csrc: Option<u32>, ssrc: u32, slots: &[(u32, u32)]) -> u32 {
    if let Some(m) = csrc {
        return m;
    }
    slots
        .iter()
        .find(|(slot_ssrc, msi)| *slot_ssrc == ssrc && *msi != SOURCE_ANY && *msi != SOURCE_NONE)
        .map(|(_, msi)| *msi)
        .unwrap_or(ssrc)
}

/// First CSRC of a (decrypted) RTP packet, if any.
pub fn rtp_first_csrc(rtp: &[u8]) -> Option<u32> {
    if rtp.len() >= 16 && rtp[0] & 0x0F > 0 {
        Some(u32::from_be_bytes([rtp[12], rtp[13], rtp[14], rtp[15]]))
    } else {
        None
    }
}

/// The lowest SSRC of a media section's `a=x-ssrc-range:S-E` (`section`
/// = "video"/"audio"), from the remote SDP.
pub fn remote_ssrc_base(sdp: &str, section: &str) -> Option<u32> {
    let mut in_section = false;
    for line in sdp.lines() {
        let line = line.trim();
        if let Some(m) = line.strip_prefix("m=") {
            in_section = m.starts_with(section);
            continue;
        }
        if in_section {
            if let Some(r) = line.strip_prefix("a=x-ssrc-range:") {
                return r.split('-').next().and_then(|s| s.trim().parse::<u32>().ok());
            }
        }
    }
    None
}

/// MS-RTP Video Source Request (RTCP PSFB, FMT=15, AFB type 1) asking
/// `msi` in X-H264UC (PT 122, UCConfig mode 1) up to `width`x`height`
/// at 15/30 fps. SOURCE_NONE carries zero entries. Reduced-size RTCP
/// (sent alone, never compounded), per MS-RTP 2.2.12.
pub fn build_vsr(
    sender_ssrc: u32,
    media_ssrc: u32,
    msi: u32,
    request_id: u16,
    keyframe: bool,
    width: u16,
    height: u16,
) -> Vec<u8> {
    const ENTRY_LEN: usize = 0x44;
    let entries = if msi == SOURCE_NONE { 0 } else { 1 };
    let fci_len = 20 + ENTRY_LEN * entries;
    let total = 12 + fci_len;
    let mut b = Vec::with_capacity(total);
    b.push(0x80 | 15); // V=2, P=0, FMT=15 (AFB)
    b.push(206); // PT=PSFB
    b.extend_from_slice(&((total / 4 - 1) as u16).to_be_bytes());
    b.extend_from_slice(&sender_ssrc.to_be_bytes());
    b.extend_from_slice(&media_ssrc.to_be_bytes());
    // VSR header (20 bytes).
    b.extend_from_slice(&1u16.to_be_bytes()); // AFB type: VSR
    b.extend_from_slice(&(fci_len as u16).to_be_bytes());
    b.extend_from_slice(&msi.to_be_bytes());
    b.extend_from_slice(&request_id.to_be_bytes());
    b.extend_from_slice(&[0, 0]); // Reserve1
    b.push(0); // Version
    b.push(if keyframe { 0x80 } else { 0 }); // K + Reserve2
    b.push(entries as u8);
    b.push(ENTRY_LEN as u8);
    b.extend_from_slice(&[0, 0, 0, 0]); // Reserve3
    if entries == 1 {
        let entry_start = b.len();
        b.push(video::PT_H264); // payload type 122 (X-H264UC)
        b.push(1); // UCConfig mode 1
        b.push(0); // flags
        b.push(0x03); // aspect: 4:3 | 16:9
        b.extend_from_slice(&width.to_be_bytes());
        b.extend_from_slice(&height.to_be_bytes());
        let min_bitrate: u32 = 100_000;
        let per_level: u32 = 100_000;
        b.extend_from_slice(&min_bitrate.to_be_bytes());
        b.extend_from_slice(&[0, 0, 0, 0]); // reserved (video)
        b.extend_from_slice(&per_level.to_be_bytes());
        // Bitrate histogram: one receiver at the level for this size.
        let want: u32 = if width as u32 * height as u32 >= 1280 * 720 { 1_000_000 } else { 500_000 };
        let level = ((want - min_bitrate) / per_level).min(9) as usize;
        for i in 0..10 {
            b.extend_from_slice(&(if i == level { 1u16 } else { 0 }).to_be_bytes());
        }
        b.extend_from_slice(&((1u32 << 2) | (1u32 << 4)).to_be_bytes()); // 15 | 30 fps
        b.extend_from_slice(&1u16.to_be_bytes()); // MUST instances
        b.extend_from_slice(&0u16.to_be_bytes()); // MAY instances
        b.extend_from_slice(&[0u8; 16]); // quality report histogram
        b.extend_from_slice(&(width as u32 * height as u32).to_be_bytes());
        debug_assert_eq!(b.len() - entry_start, ENTRY_LEN);
    }
    b
}

/// Application-layer feedback blocks (PSFB FMT=15) in a decrypted RTCP
/// (compound or reduced-size) packet: `(afb_type, fci)`. PLI (PSFB
/// FMT=1) reads as type 0 with an empty FCI.
pub fn parse_afb(rtcp: &[u8]) -> Vec<(u16, Vec<u8>)> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 4 <= rtcp.len() {
        let fmt = rtcp[at] & 0x1F;
        let pt = rtcp[at + 1];
        let words = u16::from_be_bytes([rtcp[at + 2], rtcp[at + 3]]) as usize;
        let end = at + (words + 1) * 4;
        if rtcp[at] >> 6 != 2 || end > rtcp.len() {
            break;
        }
        if pt == 206 && end >= at + 12 {
            if fmt == 15 && end >= at + 16 {
                let t = u16::from_be_bytes([rtcp[at + 12], rtcp[at + 13]]);
                out.push((t, rtcp[at + 12..end].to_vec()));
            } else if fmt == 1 {
                out.push((0, Vec::new()));
            }
        }
        at = end;
    }
    out
}

/// Sends per VSR: the original + 4 resends at 190 ms + 5 at 3 s (MS-RTP).
pub const VSR_SENDS: u8 = 10;

/// Delay before the next send of a VSR already sent `sent` times.
pub fn vsr_resend_delay(sent: u8) -> Duration {
    if sent <= 4 {
        Duration::from_millis(190)
    } else {
        Duration::from_secs(3)
    }
}

/// `(slot SSRC, MSI)` per subscription slot: the remote x-ssrc-range
/// base + slot index. Empty without a remote range.
fn slot_table(base: Option<u32>, wanted: &[u32]) -> Vec<(u32, u32)> {
    let Some(b) = base else {
        return Vec::new();
    };
    effective_slots(wanted)
        .iter()
        .enumerate()
        .map(|(i, m)| (b.wrapping_add(i as u32), *m))
        .collect()
}

/// Dominant speaker MSI from a DSH FCI (AFB type 3): None = SOURCE_NONE.
pub fn dsh_dominant(fci: &[u8]) -> Option<Option<u32>> {
    if fci.len() < 8 || u16::from_be_bytes([fci[0], fci[1]]) != 3 {
        return None;
    }
    let msi = u32::from_be_bytes([fci[4], fci[5], fci[6], fci[7]]);
    Some(if msi == SOURCE_NONE { None } else { Some(msi) })
}

/// RTCP Picture Loss Indication (PSFB FMT=1, RFC 4585 6.3.1): asks the
/// sender of `media_ssrc` for a keyframe. Reduced-size, sent alone.
pub fn build_pli(sender_ssrc: u32, media_ssrc: u32) -> Vec<u8> {
    let mut b = Vec::with_capacity(12);
    b.push(0x80 | 1); // V=2, P=0, FMT=1 (PLI)
    b.push(206); // PT=PSFB
    b.extend_from_slice(&2u16.to_be_bytes());
    b.extend_from_slice(&sender_ssrc.to_be_bytes());
    b.extend_from_slice(&media_ssrc.to_be_bytes());
    b
}

/// Source keys that asked for a keyframe; the leg's VSR loop re-sends the
/// matching slot's request (every VSR carries the keyframe flag). One set
/// for main video, one for the share leg.
fn keyframe_requests(share: bool) -> &'static Mutex<std::collections::HashSet<u32>> {
    static MAIN: OnceLock<Mutex<std::collections::HashSet<u32>>> = OnceLock::new();
    static SHARE: OnceLock<Mutex<std::collections::HashSet<u32>>> = OnceLock::new();
    let s = if share { &SHARE } else { &MAIN };
    s.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

/// Where a VSR loop reads the sources it requests: main video follows the
/// host's subscription; the share leg follows the roster's presenter
/// (SOURCE_ANY until the roster names one).
#[derive(Clone, Copy, Debug, PartialEq)]
enum VsrFeed {
    Main,
    Share,
}

impl VsrFeed {
    /// `(version, wanted MSIs)`; a new version re-plans the slots.
    fn wanted(self) -> (u64, Vec<u32>) {
        match self {
            VsrFeed::Main => {
                let s = lock(subscriptions());
                (s.version, s.wanted.clone())
            }
            VsrFeed::Share => {
                let m = crate::call_roster::presenter_screen_msi();
                (m.map(|x| x as u64 + 1).unwrap_or(0), m.into_iter().collect())
            }
        }
    }

    /// Requested size for slot `i`.
    fn size(self, i: usize) -> (u16, u16) {
        match (self, i) {
            (VsrFeed::Share, _) => (1920, 1080),
            (VsrFeed::Main, 0) => (1280, 720),
            _ => (640, 360),
        }
    }
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
    /// Video Source Requests sent / received (MS-RTP AFB type 1).
    pub vsr_sent: u32,
    pub vsr_recv: u32,
    /// Picture loss indications received on video.
    pub pli_recv: u32,
    /// Dominant Speaker History notifications received on audio.
    pub dsh_recv: u32,
    /// Distinct video sources that delivered frames this call.
    pub video_sources: usize,
    /// Keyframe requests sent (RTCP PLI; a VSR re-send rides along).
    pub pli_sent: u32,
    /// Screen share leg: RTP packets received, and its ICE pair.
    pub share_recv: u32,
    pub ice_share: String,
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

/// Take the oldest recv-side access unit (FIFO: the host decodes every
/// unit in order). Returns the framed payload (empty when none), the
/// units dropped (overflow, loss) since the last poll, and whether an AU
/// is present. All-wrapper AUs read as absent, as before.
pub fn video_incoming_poll_raw() -> (Vec<u8>, usize, bool) {
    // Pop under the lock; filter + frame outside it so the mutex is
    // never held across AU-sized allocs/copies.
    let (au, stale) = lock(recv_queue()).pop(now_ms());
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
    s.recv_pending = lock(recv_queue()).q.len();
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
    /// Screen share receive leg (group / meeting joins that offered one).
    pub share: Option<ShareParams>,
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
    lock(source_queues()).clear();
    lock(keyframe_requests(false)).clear();
    lock(keyframe_requests(true)).clear();

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
    // Subscriptions are per call (set before or after the engine starts).
    {
        let mut subs = lock(subscriptions());
        subs.wanted.clear();
        subs.version += 1;
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
                    // Mixer Dominant Speaker History (MS-RTP AFB type 3).
                    for (_, fci) in parse_afb(&rtcp_data) {
                        if let Some(dominant) = dsh_dominant(&fci) {
                            stat_add(|s| s.dsh_recv += 1);
                            crate::call_roster::set_dominant_msi(dominant);
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

    // -- video send (host NAL queue, ~15fps; camera off sends no video RTP) --
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
                for unit in take_send_all() {
                    for rtp_pkt in packetizer.packetize_frame(&unit.nals) {
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
            }
        }));

        // -- video recv (SRTP -> depacketize -> AU framing -> queues) --
        tasks.push(tokio::spawn(video_recv_loop(VideoLeg {
            socket: video_sock.clone(),
            ctx: vctx.clone(),
            pwd: video_pair.as_ref().map(|(_, _, pwd)| pwd.clone()).unwrap_or_default(),
            stats: vid_recv_stats.clone(),
            remote_ssrc: vid_remote_ssrc.clone(),
            flag: shutdown.clone(),
            slot_base: remote_ssrc_base(&p.remote_sdp, "video"),
            sender_ssrc: p.video_ssrc,
            dest: vaddr,
            share: false,
        })));

        // -- video source requests (MS-RTP VSR, one per slot) --
        tasks.push(tokio::spawn(vsr_loop(
            video_sock.clone(),
            vctx.clone(),
            shutdown.clone(),
            p.video_ssrc,
            remote_ssrc_base(&p.remote_sdp, "video"),
            vaddr,
            VsrFeed::Main,
        )));

        // -- video RTCP (5s) --
        tasks.push(tokio::spawn(rtcp_report_loop(
            video_sock.clone(),
            vctx.clone(),
            vid_send_stats.clone(),
            vid_recv_stats.clone(),
            vid_remote_ssrc.clone(),
            p.cname.clone(),
            shutdown.clone(),
            vaddr,
        )));
    }

    // -- screen share receive (applicationsharing-video leg; own ICE, never
    //    blocks audio/video) --
    if let Some(sp) = p.share {
        let cname = p.cname.clone();
        let controlling = p.controlling;
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            if let Err(e) = share_leg(sp, controlling, cname, flag).await {
                crate::call_roster::diag(format!("share: {}", e));
            }
        }));
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
// Video legs: receive loop, VSR loop, RTCP reports, screen share leg
// ---------------------------------------------------------------------------

/// One video receive leg: main video, or the screen share leg.
struct VideoLeg {
    socket: std::sync::Arc<tokio::net::UdpSocket>,
    ctx: std::sync::Arc<tokio::sync::Mutex<srtp::SrtpContext>>,
    /// Our ICE password (answers the remote connectivity checks).
    pwd: String,
    stats: std::sync::Arc<tokio::sync::Mutex<rtcp::RtpRecvStats>>,
    remote_ssrc: std::sync::Arc<tokio::sync::Mutex<u32>>,
    flag: std::sync::Arc<AtomicBool>,
    /// Remote x-ssrc-range base (VSR slot SSRCs).
    slot_base: Option<u32>,
    /// Our SSRC on this leg (PLI sender).
    sender_ssrc: u32,
    dest: std::net::SocketAddr,
    /// Share leg: every unit files under [`SOURCE_SHARE`], no 1:1 queue.
    share: bool,
}

/// Per remote SSRC: SRTP rollover state, FU-A reassembly, the access
/// unit being built, and loss tracking.
struct SsrcRecv {
    ctx: srtp::SrtpContext,
    depack: video::VideoDepacketizer,
    au: Vec<Vec<u8>>,
    last_seq: Option<u16>,
    /// A packet of the unit being built was lost.
    lossy: bool,
}

/// RTP payload types carrying H.264 this client decodes: X-H264UC (122)
/// and H264 (124, screen share). FEC (123) and RTVC1 (121) carry no NALs.
fn is_h264_pt(pt: u8) -> bool {
    pt == video::PT_H264 || pt == 124
}

/// Lost packets between `last` and `seq` (mod 2^16). A late, duplicate or
/// wildly jumped (sender restart) sequence number is not loss.
fn seq_gap(last: u16, seq: u16) -> bool {
    let d = seq.wrapping_sub(last);
    d > 1 && d < 3000
}

/// `seq` is newer than `last` (mod 2^16).
fn seq_newer(last: u16, seq: u16) -> bool {
    let d = seq.wrapping_sub(last);
    d != 0 && d < 0x8000
}

/// NALs of a STAP-A aggregate (type 24: `u16 size + NAL` repeated, e.g.
/// SPS + PPS in one packet); None for any other payload.
fn stap_a_nals(payload: &[u8]) -> Option<Vec<Vec<u8>>> {
    if payload.first().map(|b| b & 0x1F) != Some(24) {
        return None;
    }
    let mut out = Vec::new();
    let mut at = 1usize;
    while at + 2 <= payload.len() {
        let n = u16::from_be_bytes([payload[at], payload[at + 1]]) as usize;
        at += 2;
        if n == 0 || at + n > payload.len() {
            break;
        }
        out.push(payload[at..at + n].to_vec());
        at += n;
    }
    Some(out)
}

/// UDP -> SRTP -> depacketize -> access units -> queues, per SSRC (a
/// mixer forwards several sources, each with its own sequence space and
/// FU-A reassembly). Main video files each unit under its source key and
/// in the 1:1 queue; the share leg files under [`SOURCE_SHARE`]. Loss
/// drops the damaged unit and its dependents until a keyframe; a starved
/// live queue asks the sender for one (PLI now, VSR re-send next tick).
async fn video_recv_loop(leg: VideoLeg) {
    let mut buf = [0u8; 2048];
    let base_ctx = leg.ctx.lock().await.clone();
    let mut per_ssrc: std::collections::HashMap<u32, SsrcRecv> = std::collections::HashMap::new();
    let mut subs_version = u64::MAX;
    let mut slots: Vec<(u32, u32)> = Vec::new();
    while !leg.flag.load(Ordering::Relaxed) {
        let got = tokio::time::timeout(Duration::from_millis(500), leg.socket.recv_from(&mut buf)).await;
        let (len, from) = match got {
            Ok(Ok(v)) => v,
            _ => continue,
        };
        let data = &buf[..len];
        if len >= 20 && ice::is_stun_message(data) {
            if ice::is_stun_request(data) {
                if let Some(txn) = ice::get_transaction_id(data) {
                    let resp = ice::build_binding_response(&txn, from, Some(leg.pwd.as_bytes()));
                    let _ = leg.socket.send_to(&resp, from).await;
                }
            }
            continue;
        }
        // RTCP (rtcp-mux demux, RFC 5761: PT byte 192..=223).
        if len >= 2 && (192..=223).contains(&data[1]) {
            let rtcp_data = {
                let mut c = leg.ctx.lock().await;
                srtp::unprotect_rtcp(&mut c, data)
            };
            if let Ok(rtcp_data) = rtcp_data {
                {
                    let mut rs = leg.stats.lock().await;
                    for block in rtcp::parse_rtcp(&rtcp_data) {
                        if let rtcp::RtcpBlock::SenderReport { ntp_timestamp, .. } = block {
                            rs.last_sr_ntp = ((ntp_timestamp >> 16) & 0xFFFF_FFFF) as u32;
                            rs.last_sr_recv_time = Some(std::time::Instant::now());
                        }
                    }
                }
                for (t, _) in parse_afb(&rtcp_data) {
                    match t {
                        0 => stat_add(|s| s.pli_recv += 1),
                        1 => stat_add(|s| s.vsr_recv += 1),
                        _ => {}
                    }
                }
            }
            continue;
        }
        if len < rtp::RTP_HEADER_SIZE {
            continue;
        }
        let ssrc = u32::from_be_bytes([data[8], data[9], data[10], data[11]]);
        if !per_ssrc.contains_key(&ssrc) && per_ssrc.len() >= 32 {
            if let Some(k) = per_ssrc.keys().next().copied() {
                per_ssrc.remove(&k);
            }
        }
        let entry = per_ssrc.entry(ssrc).or_insert_with(|| {
            let mut c = base_ctx.clone();
            c.remote_roc = 0;
            c.remote_highest_seq = 0;
            SsrcRecv {
                ctx: c,
                depack: video::VideoDepacketizer::new(),
                au: Vec::new(),
                last_seq: None,
                lossy: false,
            }
        });
        let rtp_data = match srtp::unprotect(&mut entry.ctx, data) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let pkt = match rtp::decode(&rtp_data) {
            Ok(p) => p,
            Err(_) => continue,
        };
        {
            let mut rs = leg.stats.lock().await;
            rs.packets_received += 1;
            if pkt.sequence_number as u32 > rs.highest_seq {
                rs.highest_seq = pkt.sequence_number as u32;
            }
        }
        if leg.share {
            stat_add(|s| s.share_recv += 1);
        } else {
            stat_add(|s| s.video_recv += 1);
        }
        {
            let mut r = leg.remote_ssrc.lock().await;
            if *r == 0 {
                *r = pkt.ssrc;
            }
        }
        // Loss (counted over every payload type: FEC shares the sequence
        // space) damages the unit being built.
        let seq = pkt.sequence_number;
        match entry.last_seq {
            Some(last) => {
                if seq_gap(last, seq) {
                    entry.lossy = true;
                }
                if seq_newer(last, seq) {
                    entry.last_seq = Some(seq);
                }
            }
            None => entry.last_seq = Some(seq),
        }
        if !is_h264_pt(pkt.payload_type) {
            continue;
        }
        if let Some(nals) = stap_a_nals(&pkt.payload) {
            entry.au.extend(nals.into_iter().filter(|n| !is_wrapper_nal(n)));
        } else if let Ok(Some(nal)) = entry.depack.depacketize(&pkt.payload, pkt.marker) {
            if !is_wrapper_nal(&nal) {
                entry.au.push(nal);
            }
        }
        if !pkt.marker {
            continue;
        }
        // Access unit complete.
        let unit = RecvUnit { nals: std::mem::take(&mut entry.au) };
        let lossy = std::mem::replace(&mut entry.lossy, false);
        let key = if leg.share {
            SOURCE_SHARE
        } else {
            {
                let subs = lock(subscriptions());
                if subs.version != subs_version {
                    subs_version = subs.version;
                    slots = slot_table(leg.slot_base, &subs.wanted);
                }
            }
            source_key(rtp_first_csrc(&rtp_data), pkt.ssrc, &slots)
        };
        let want = if lossy {
            let w = lose_source(key);
            if leg.share {
                w
            } else {
                lock(recv_queue()).lose(now_ms()) || w
            }
        } else if unit.nals.is_empty() {
            false
        } else if leg.share {
            push_source(key, unit)
        } else {
            let w = push_source(key, unit.clone());
            push_recv(unit) || w
        };
        if !leg.share {
            let n = lock(source_queues()).len();
            stat_add(|s| s.video_sources = n);
        }
        if want {
            let pli = build_pli(leg.sender_ssrc, pkt.ssrc);
            let wire = {
                let mut c = leg.ctx.lock().await;
                srtp::protect_rtcp(&mut c, &pli)
            };
            if let Ok(w) = wire {
                if leg.socket.send_to(&w, leg.dest).await.is_ok() {
                    stat_add(|s| s.pli_sent += 1);
                }
            }
            lock(keyframe_requests(leg.share)).insert(key);
        }
    }
}

/// MS-RTP Video Source Requests, one per slot: "SSRC of media source" =
/// the remote x-ssrc-range base + slot index, retransmitted 4x at 190 ms
/// then 5x at 3 s. A keyframe request for a slot's source re-sends that
/// slot's request (the keyframe flag is always set).
async fn vsr_loop(
    socket: std::sync::Arc<tokio::net::UdpSocket>,
    ctx: std::sync::Arc<tokio::sync::Mutex<srtp::SrtpContext>>,
    flag: std::sync::Arc<AtomicBool>,
    sender: u32,
    base: Option<u32>,
    dest: std::net::SocketAddr,
    feed: VsrFeed,
) {
    struct Slot {
        msi: u32,
        request_id: u16,
        sent: u8,
        next: tokio::time::Instant,
    }
    let share = feed == VsrFeed::Share;
    let mut slots: Vec<Slot> = Vec::new();
    let mut version = u64::MAX;
    let mut next_id: u16 = (now_secs() as u16) | 1;
    while !flag.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let (v, wanted) = feed.wanted();
        let now = tokio::time::Instant::now();
        if v != version {
            version = v;
            let eff = effective_slots(&wanted);
            for i in 0..eff.len().max(slots.len()) {
                let msi = eff.get(i).copied().unwrap_or(SOURCE_NONE);
                let fresh = Slot { msi, request_id: next_id, sent: 0, next: now };
                match slots.get_mut(i) {
                    Some(s) if s.msi == msi => continue,
                    Some(s) => *s = fresh,
                    None => slots.push(fresh),
                }
                next_id = next_id.wrapping_add(1);
            }
        }
        let asked: Vec<u32> = lock(keyframe_requests(share)).drain().collect();
        for key in asked {
            let i = slots.iter().position(|s| s.msi == key).or_else(|| {
                let any = slots.first().map(|s| s.msi == SOURCE_ANY).unwrap_or(false);
                (share || any).then_some(0).filter(|_| !slots.is_empty())
            });
            if let Some(s) = i.and_then(|i| slots.get_mut(i)) {
                if s.msi == SOURCE_NONE {
                    continue;
                }
                if s.sent >= VSR_SENDS {
                    s.sent = VSR_SENDS - 1; // one more send, as a new request
                    s.request_id = next_id;
                    next_id = next_id.wrapping_add(1);
                }
                s.next = now;
            }
        }
        for (i, s) in slots.iter_mut().enumerate() {
            if s.sent >= VSR_SENDS || now < s.next {
                continue;
            }
            let media = base.map(|b| b.wrapping_add(i as u32)).unwrap_or(0);
            let (w, h) = feed.size(i);
            let pkt = build_vsr(sender, media, s.msi, s.request_id, true, w, h);
            let wire = {
                let mut c = ctx.lock().await;
                srtp::protect_rtcp(&mut c, &pkt)
            };
            if let Ok(wire) = wire {
                if socket.send_to(&wire, dest).await.is_ok() {
                    stat_add(|st| st.vsr_sent += 1);
                }
            }
            s.sent += 1;
            s.next = now + vsr_resend_delay(s.sent);
        }
        while slots
            .last()
            .map(|s| s.msi == SOURCE_NONE && s.sent >= VSR_SENDS)
            .unwrap_or(false)
        {
            slots.pop();
        }
    }
}

/// RTCP sender / receiver report every 5 s (250 ms-granular shutdown).
#[allow(clippy::too_many_arguments)]
async fn rtcp_report_loop(
    socket: std::sync::Arc<tokio::net::UdpSocket>,
    ctx: std::sync::Arc<tokio::sync::Mutex<srtp::SrtpContext>>,
    send_stats: std::sync::Arc<tokio::sync::Mutex<rtcp::RtpSendStats>>,
    recv_stats: std::sync::Arc<tokio::sync::Mutex<rtcp::RtpRecvStats>>,
    remote_ssrc: std::sync::Arc<tokio::sync::Mutex<u32>>,
    cname: String,
    flag: std::sync::Arc<AtomicBool>,
    dest: std::net::SocketAddr,
) {
    let mut ticks = 0u32;
    while !flag.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(250)).await;
        ticks += 1;
        if ticks < 20 {
            continue;
        }
        ticks = 0;
        let s = send_stats.lock().await.clone();
        let r = recv_stats.lock().await.clone();
        let remote = *remote_ssrc.lock().await;
        let pkt = if s.packets_sent > 0 {
            rtcp::build_sender_report(&s, &r, remote, &cname)
        } else {
            rtcp::build_receiver_report(s.ssrc, &r, remote, &cname)
        };
        let mut c = ctx.lock().await;
        if let Ok(wire) = srtp::protect_rtcp(&mut c, &pkt) {
            let _ = socket.send_to(&wire, dest).await;
        }
    }
}

/// The screen share receive leg (applicationsharing-video m-line of a
/// group / meeting join): its own port, ICE and SRTP; receive only. VSRs
/// ask for the roster's presenter (SOURCE_ANY until one is known).
pub struct ShareParams {
    pub sock: std::net::UdpSocket,
    pub local_crypto: String,
    pub local_ufrag: String,
    pub local_pwd: String,
    /// Our SSRC on the leg (RTCP / VSR sender; no media is sent).
    pub ssrc: u32,
    /// The answer's share media section (see [`split_share_section`]).
    pub remote_section: String,
}

async fn share_leg(
    sp: ShareParams,
    controlling: bool,
    cname: String,
    flag: std::sync::Arc<AtomicBool>,
) -> Result<(), String> {
    use tokio::sync::Mutex as AMutex;
    let socket = std::sync::Arc::new(
        tokio::net::UdpSocket::from_std(sp.sock).map_err(|e| format!("socket: {}", e))?,
    );
    let info = section_info(&sp.remote_section);
    let local = srtp::parse_crypto_line(&sp.local_crypto).map_err(|e| format!("crypto: {:#}", e))?;
    let remote = info
        .crypto
        .iter()
        .find_map(|l| srtp::parse_crypto_line(l).ok())
        .ok_or_else(|| "no crypto in the answer".to_string())?;
    let ctx = std::sync::Arc::new(AMutex::new(
        srtp::create_context(&local, &remote).map_err(|e| format!("srtp: {:#}", e))?,
    ));
    let cands = ice::parse_candidates_from_sdp_section(&sp.remote_section, "video");
    let agent = ice::IceAgent::new(
        ice::IceCredentials { ufrag: sp.local_ufrag.clone(), pwd: sp.local_pwd.clone() },
        ice::IceCredentials { ufrag: info.ufrag.clone(), pwd: info.pwd.clone() },
        controlling,
    );
    let dest = tokio::select! {
        r = agent.check_connectivity(socket.clone(), &cands) => r
            .map(|c| Some(c.remote_addr))
            .unwrap_or_else(|_| ice::select_remote_candidate(&cands)),
        _ = wait_shutdown(&flag) => return Ok(()),
    };
    let dest = dest.ok_or_else(|| "no candidate in the answer".to_string())?;
    lock(engine_stats()).ice_share = dest.to_string();
    crate::call_roster::diag(format!(
        "share: leg up, source base {}",
        info.ssrc_base.map(|b| b.to_string()).unwrap_or_else(|| "-".to_string())
    ));
    let send_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpSendStats::default()));
    send_stats.lock().await.ssrc = sp.ssrc;
    let recv_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpRecvStats::default()));
    let remote_ssrc = std::sync::Arc::new(AMutex::new(0u32));
    let vsr = tokio::spawn(vsr_loop(
        socket.clone(),
        ctx.clone(),
        flag.clone(),
        sp.ssrc,
        info.ssrc_base,
        dest,
        VsrFeed::Share,
    ));
    let reports = tokio::spawn(rtcp_report_loop(
        socket.clone(),
        ctx.clone(),
        send_stats,
        recv_stats.clone(),
        remote_ssrc.clone(),
        cname,
        flag.clone(),
        dest,
    ));
    video_recv_loop(VideoLeg {
        socket,
        ctx,
        pwd: sp.local_pwd,
        stats: recv_stats,
        remote_ssrc,
        flag,
        slot_base: info.ssrc_base,
        sender_ssrc: sp.ssrc,
        dest,
        share: true,
    })
    .await;
    vsr.abort();
    reports.abort();
    Ok(())
}

/// ICE credentials, crypto lines, port and x-ssrc-range base of one SDP
/// media section.
#[derive(Debug, Default, PartialEq)]
pub struct SectionInfo {
    pub port: u16,
    pub ufrag: String,
    pub pwd: String,
    pub crypto: Vec<String>,
    pub ssrc_base: Option<u32>,
}

pub fn section_info(section: &str) -> SectionInfo {
    let mut out = SectionInfo::default();
    for line in section.lines().map(str::trim) {
        if let Some(m) = line.strip_prefix("m=") {
            out.port = m.split_whitespace().nth(1).and_then(|p| p.parse().ok()).unwrap_or(0);
        } else if let Some(v) = line.strip_prefix("a=ice-ufrag:") {
            out.ufrag = v.to_string();
        } else if let Some(v) = line.strip_prefix("a=ice-pwd:") {
            out.pwd = v.to_string();
        } else if line.starts_with("a=crypto:") || line.starts_with("a=cryptoscale:") {
            out.crypto.push(line.to_string());
        } else if let Some(r) = line.strip_prefix("a=x-ssrc-range:") {
            out.ssrc_base = r.split('-').next().and_then(|s| s.trim().parse().ok());
        }
    }
    out
}

/// Split a remote SDP into the SDP without its screen share media section
/// and that section alone (session-level ICE credentials folded in). The
/// share section is the `m=video` section labelled
/// `applicationsharing-video` (a=label or a=x-source); it is None when
/// absent or rejected (port 0). Every other parser keeps seeing exactly
/// the audio + main video sections it was written for.
pub fn split_share_section(sdp: &str) -> (String, Option<String>) {
    let mut sections: Vec<String> = vec![String::new()];
    for line in sdp.split_inclusive('\n') {
        if line.starts_with("m=") {
            sections.push(String::new());
        }
        sections.last_mut().unwrap().push_str(line);
    }
    let is_share = |s: &str| {
        s.starts_with("m=video")
            && s.lines().map(str::trim).any(|l| {
                l == "a=label:applicationsharing-video" || l == "a=x-source:applicationsharing-video"
            })
    };
    let Some(i) = sections.iter().position(|s| is_share(s)) else {
        return (sdp.to_string(), None);
    };
    let share = sections.remove(i);
    let main = sections.concat();
    if section_info(&share).port == 0 {
        return (main, None);
    }
    let mut section = share;
    if !section.ends_with('\n') {
        section.push_str("\r\n");
    }
    let head = section_info(&sections[0]);
    let own = section_info(&section);
    if own.ufrag.is_empty() && !head.ufrag.is_empty() {
        section.push_str(&format!("a=ice-ufrag:{}\r\n", head.ufrag));
    }
    if own.pwd.is_empty() && !head.pwd.is_empty() {
        section.push_str(&format!("a=ice-pwd:{}\r\n", head.pwd));
    }
    (main, Some(section))
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

/// Drain the newest AU of one video source (meeting tiles); same
/// contract as [`ostmac_video_poll_incoming_bytes`].
#[no_mangle]
pub extern "C" fn ostmac_video_poll_source_bytes(
    source: u32,
    out: *mut *mut u8,
    out_len: *mut usize,
    dropped: *mut c_int,
) -> c_int {
    if out.is_null() || out_len.is_null() || dropped.is_null() {
        return -1;
    }
    let (payload, stale, has) = video_source_poll_raw(source);
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

/// Video sources seen this call. See [`video_sources_json`].
#[no_mangle]
pub extern "C" fn ostmac_video_sources() -> *mut c_char {
    string_to_c(video_sources_json())
}

/// Subscribe video sources: `msis_json` is a JSON array of MSIs in
/// priority order. See [`video_subscribe_json`].
#[no_mangle]
pub extern "C" fn ostmac_video_subscribe(msis_json: *const c_char) -> *mut c_char {
    match crate::cstr_to_string(msis_json) {
        Ok(s) => match serde_json::from_str::<Vec<u32>>(&s) {
            Ok(v) => string_to_c(video_subscribe_json(&v)),
            Err(e) => string_to_c(err_json("arg", format!("msis: {}", e))),
        },
        Err(e) => string_to_c(err_json("arg", e)),
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

    /// meetvideo: VSR wire layout (MS-RTP 2.2.12.2), AFB/DSH parse,
    /// source keying, and per-source queues (FIFO per source).
    #[test]
    fn vsr_layout_and_source_queues() {
        let _t = test_lock();
        let be16 = |b: &[u8], i: usize| u16::from_be_bytes([b[i], b[i + 1]]);
        let be32 = |b: &[u8], i: usize| u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
        let v = build_vsr(0x1111_1111, 0x2222_2222, 21, 7, true, 1280, 720);
        assert_eq!(v.len(), 12 + 20 + 0x44);
        assert_eq!((v[0], v[1]), (0x8F, 206), "V=2 FMT=15, PT=PSFB");
        assert_eq!(be16(&v, 2) as usize, v.len() / 4 - 1);
        assert_eq!((be32(&v, 4), be32(&v, 8)), (0x1111_1111, 0x2222_2222));
        assert_eq!(be16(&v, 12), 1, "AFB type VSR");
        assert_eq!(be16(&v, 14) as usize, 20 + 0x44, "FCI length incl. type+length");
        assert_eq!(be32(&v, 16), 21, "requested MSI");
        assert_eq!(be16(&v, 20), 7, "request id");
        assert_eq!((v[25], v[26], v[27]), (0x80, 1, 0x44), "K, entries, entry length");
        let e = 32;
        assert_eq!((v[e], v[e + 1]), (122, 1), "X-H264UC, UCConfig mode 1");
        assert_eq!((be16(&v, e + 4), be16(&v, e + 6)), (1280, 720));
        assert_eq!(be32(&v, e + 64), 1280 * 720, "max pixels closes the 0x44 entry");
        let none = build_vsr(1, 2, SOURCE_NONE, 8, false, 0, 0);
        assert_eq!((none.len(), none[26]), (32, 0), "SOURCE_NONE: header only");

        // Compound: PLI + our VSR + a mixer DSH (dominant 20, history 30).
        let mut rtcp = vec![0x81u8, 206, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2];
        rtcp.extend_from_slice(&v);
        rtcp.extend_from_slice(&[0x8F, 206, 0, 5, 0, 0, 0, 1, 0, 0, 0, 0,
            0, 3, 0, 12, 0, 0, 0, 20, 0, 0, 0, 30]);
        let afb = parse_afb(&rtcp);
        assert_eq!(afb.iter().map(|(t, _)| *t).collect::<Vec<_>>(), vec![0, 1, 3]);
        assert_eq!(dsh_dominant(&afb[2].1), Some(Some(20)));
        assert_eq!(dsh_dominant(&afb[1].1), None, "a VSR is not a DSH");

        // Source keys: CSRC MSI > subscribed slot > SSRC.
        let slots = slot_table(Some(5000), &[7, 9]);
        assert_eq!(slots, vec![(5000, 7), (5001, 9)]);
        assert_eq!(source_key(Some(21), 5001, &slots), 21);
        assert_eq!(source_key(None, 5001, &slots), 9);
        assert_eq!(source_key(None, 5000, &slot_table(Some(5000), &[])), 5000, "SOURCE_ANY keeps SSRC");
        assert_eq!(source_key(None, 42, &[]), 42);
        let sdp = "m=audio 1 RTP/SAVP 0\r\na=x-ssrc-range:10-10\r\nm=video 2 RTP/SAVP 122\r\na=x-ssrc-range:5000-5099\r\n";
        assert_eq!(remote_ssrc_base(sdp, "video"), Some(5000));
        assert_eq!(remote_ssrc_base(sdp, "audio"), Some(10));
        assert_eq!(vsr_resend_delay(4), Duration::from_millis(190));
        assert_eq!(vsr_resend_delay(5), Duration::from_secs(3));
        let sub: serde_json::Value =
            serde_json::from_str(&video_subscribe_json(&[21, 21, SOURCE_ANY, 31])).unwrap();
        assert_eq!(sub["subscribed"], serde_json::json!([21, 31]));
        video_subscribe_json(&[]);

        lock(source_queues()).clear();
        push_source(21, RecvUnit { nals: vec![vec![0x65, 1]] });
        push_source(21, RecvUnit { nals: vec![vec![0x65, 2]] });
        push_source(31, RecvUnit { nals: vec![vec![0x65, 3]] });
        let (payload, stale, has) = video_source_poll_raw(21);
        assert!(has);
        assert_eq!(stale, 0);
        assert_eq!(unframe_nals(&payload).unwrap(), vec![vec![0x65, 1]], "oldest first");
        assert_eq!(unframe_nals(&video_source_poll_raw(21).0).unwrap(), vec![vec![0x65, 2]]);
        assert!(!video_source_poll_raw(21).2, "drained");
        assert!(video_source_poll_raw(31).2, "other source untouched");
        let list: serde_json::Value = serde_json::from_str(&video_sources_json()).unwrap();
        assert_eq!(list["sources"].as_array().unwrap().len(), 2);
        lock(source_queues()).clear();
    }

    /// callfix: every queued unit reaches the decoder in order; overflow
    /// and loss drop whole GOPs (never a lone reference), and a starved
    /// live queue asks for a keyframe once a second. Send side: every
    /// frame goes out in order, and camera off sends nothing (no black).
    #[test]
    fn gop_queue_decodes_every_unit_and_drops_whole_gops() {
        let key = |n: u8| RecvUnit { nals: vec![vec![0x67, 0x42], vec![0x65, n]] };
        let p = |n: u8| RecvUnit { nals: vec![vec![0x41, n]] };
        let tag = |u: &RecvUnit| *u.nals.last().unwrap().last().unwrap();
        let mut q = GopQueue::new();
        assert!(!q.push(p(1), 10_000), "leading P-frame dropped; no decoder yet, no request");
        q.push(key(2), 10_001);
        q.push(p(3), 10_002);
        let (u, dropped) = q.pop(10_003);
        assert_eq!((tag(&u.unwrap()), dropped), (2, 1));
        assert_eq!(tag(&q.pop(10_004).0.unwrap()), 3);
        assert!(q.pop(10_005).0.is_none());

        q.push(key(10), 10_010);
        for i in 0..20 {
            q.push(p(11 + i), 10_010);
        }
        q.push(key(40), 10_010);
        for i in 0..9 {
            q.push(p(41 + i), 10_010);
        }
        assert_eq!(q.q.len(), 10, "overflow kept the newest GOP from its keyframe");
        let (u, dropped) = q.pop(20_000);
        assert_eq!((tag(&u.unwrap()), dropped), (40, 21));

        let asked = (0..40u8).filter(|i| q.push(p(*i), 20_100)).count();
        assert_eq!(asked, 1, "one-GOP overflow: empty, wait, ask once");
        assert!(q.q.is_empty() && q.awaiting_key);
        q.pop(21_150);
        assert!(q.push(p(99), 21_200), "still starved a second later: ask again");
        q.push(key(100), 21_201);
        assert_eq!(tag(&q.pop(21_202).0.unwrap()), 100, "resumes at the keyframe");
        q.push(p(101), 21_203);
        q.lose(21_204);
        q.push(p(102), 21_205);
        assert_eq!(tag(&q.pop(21_206).0.unwrap()), 101, "units before the loss still decode");
        assert!(q.pop(21_207).0.is_none(), "the damaged unit's dependents drop");

        {
            let _t = test_lock();
            lock(send_queue()).clear();
            push_send(SendUnit { nals: vec![vec![0x65, 1]] });
            push_send(SendUnit { nals: vec![vec![0x41, 2]] });
            let sent: Vec<u8> = take_send_all().into_iter().map(|u| u.nals[0][1]).collect();
            assert_eq!(sent, vec![1, 2], "every queued frame goes out, oldest first");
            assert!(take_send_all().is_empty(), "camera off: nothing to send, no black filler");
        }
        assert_eq!(
            stap_a_nals(&[24, 0, 2, 0x67, 1, 0, 1, 0x68]),
            Some(vec![vec![0x67, 1], vec![0x68]])
        );
        assert_eq!(stap_a_nals(&[0x65, 1]), None);
        assert!(seq_gap(10, 12) && !seq_gap(10, 11) && !seq_gap(10, 9) && seq_gap(65535, 1));
        assert!(is_h264_pt(122) && is_h264_pt(124) && !is_h264_pt(123));
        assert_eq!(build_pli(1, 2), vec![0x81, 206, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2]);
    }
}
