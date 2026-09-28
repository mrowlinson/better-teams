//! A/V FFI: mic/tone/camera/display/call-dry-run over JSON.
//!
//! Native capture/display live in Swift (AVFoundation/VideoToolbox/SwiftUI).
//! This module exposes the `ost::calling` pieces Swift needs:
//! - caps: static capability map
//! - mic: cpal device probe + capture/playback test (CoreAudio on macOS)
//! - tone: audible 1kHz tone + deterministic echo self-check
//! - camera: I420 pump fed by Swift AVCapture frames (byte+len over FFI)
//! - video: remote-frame slot SwiftUI polls for display
//! - dry-run: offline media pipeline (SRTP loopback + H.264 packetize)

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::{Mutex, OnceLock};

use serde_json::json;

use ost::calling::macav;

use crate::{cstr_to_string, err_json, string_to_c};

/// Max decoded frame bytes accepted over FFI (16 MiB).
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

fn camera_pump() -> &'static Mutex<macav::CameraPump> {
    static S: OnceLock<Mutex<macav::CameraPump>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(macav::CameraPump::new()))
}

fn remote_slot() -> &'static Mutex<macav::RemoteSlot> {
    static S: OnceLock<Mutex<macav::RemoteSlot>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(macav::RemoteSlot::new()))
}

fn lock<T>(m: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Borrow a byte+len FFI arg. Null with nonzero len is an error; empty
/// borrows as `&[]` so validation reports the domain error, not a crash.
fn bytes_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], String> {
    if ptr.is_null() && len > 0 {
        return Err("null pixels".to_string());
    }
    if len == 0 {
        return Ok(&[]);
    }
    if len > MAX_FRAME_BYTES {
        return Err(format!("frame too large: {} bytes", len));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

// ---------------------------------------------------------------------------
// JSON bodies
// ---------------------------------------------------------------------------

// NOTE (R12 ffi-move-now B1): av_info moved to Swift (CoreLocal);
// backing fn + export deleted.

/// Fast mic/speaker availability probe.
pub fn mic_probe_json() -> String {
    let (input, output) = ost::calling::audio::audio_probe();
    json!({"ok": true, "input": input, "output": output}).to_string()
}

/// Map an ost audio error message to its FFI code. Resolve-fail
/// (`Unknown audio…`) stays `unknown_device`; open-fail
/// (`Failed to open audio…`) is `open_failed` so the panel never heals
/// a healthy pick; anything else is the `missing` code.
pub fn audio_error_code<'a>(msg: &str, missing: &'a str) -> &'a str {
    if msg.starts_with("Unknown audio") {
        "unknown_device"
    } else if msg.starts_with("Failed to open audio") {
        "open_failed"
    } else {
        missing
    }
}

/// Capture `seconds` of mic + play back. Errors `no_input` without a mic,
/// `open_failed` when the device resolves but the stream fails.
pub fn mic_test_json(seconds: u64) -> String {
    match ost::calling::audio::mic_test_report(seconds, false) {
        Ok(r) => json!({
            "ok": true,
            "frames": r.frames,
            "seconds": r.seconds,
            "peak_db": r.peak_db,
            "played_back": r.played_back,
        })
        .to_string(),
        Err(e) => {
            let msg = e.to_string();
            let code = audio_error_code(&msg, "no_input");
            err_json(code, msg)
        }
    }
}

/// Play a 1kHz tone for `msecs`. Errors `no_output` without a speaker,
/// `open_failed` when the device resolves but the stream fails.
pub fn tone_play_json(msecs: u64) -> String {
    match ost::calling::audio::play_tone(msecs) {
        Ok(frames) => json!({"ok": true, "frames": frames}).to_string(),
        Err(e) => {
            let msg = e.to_string();
            let code = audio_error_code(&msg, "no_output");
            err_json(code, msg)
        }
    }
}

// NOTE (R12 ffi-move-now B2): tone_check moved to Swift (ToneDsp);
// backing fn + export deleted.

/// Audio device display names for UI pickers (+ system defaults).
pub fn audio_devices_json() -> String {
    json!({
        "ok": true,
        "inputs": ost::calling::audio::input_device_names(),
        "outputs": ost::calling::audio::output_device_names(),
        "default_input": ost::calling::audio::default_input_name(),
        "default_output": ost::calling::audio::default_output_name(),
    })
    .to_string()
}

/// Named-device mic test (None/empty = default). Errors `no_input` when
/// the device is missing, `unknown_device` for a stale pick, `open_failed`
/// when a resolved device cannot be opened.
pub fn mic_test_on_json(seconds: u64, input: Option<&str>, output: Option<&str>) -> String {
    match ost::calling::audio::mic_test_report_on(seconds, false, input, output) {
        Ok(r) => json!({
            "ok": true,
            "frames": r.frames,
            "seconds": r.seconds,
            "peak_db": r.peak_db,
            "played_back": r.played_back,
        })
        .to_string(),
        Err(e) => {
            let msg = e.to_string();
            let code = audio_error_code(&msg, "no_input");
            err_json(code, msg)
        }
    }
}

/// Named-device tone play (None/empty = default output).
/// `unknown_device` = stale pick, `open_failed` = resolved but unusable.
pub fn tone_play_on_json(msecs: u64, output: Option<&str>) -> String {
    match ost::calling::audio::play_tone_on(msecs, output) {
        Ok(frames) => json!({"ok": true, "frames": frames}).to_string(),
        Err(e) => {
            let msg = e.to_string();
            let code = audio_error_code(&msg, "no_output");
            err_json(code, msg)
        }
    }
}

/// Short mic level sample for a live meter. Never errors: no device (or
/// stale pick) yields `has_input: false` at the silence floor.
pub fn mic_level_json(msecs: u64, input: Option<&str>) -> String {
    match ost::calling::audio::mic_level_sample(msecs, input) {
        Some(peak) => json!({"ok": true, "peak_db": peak, "has_input": true}).to_string(),
        None => json!({"ok": true, "peak_db": -60.0, "has_input": false}).to_string(),
    }
}

/// Optional C string arg: null/empty = default device.
fn opt_name(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .ok()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub fn camera_begin_json(width: u32, height: u32, fps: u32) -> String {
    if width == 0 || height == 0 || fps == 0 {
        return err_json("arg", "width/height/fps must be nonzero");
    }
    lock(camera_pump()).begin(width, height, fps);
    json!({"ok": true, "width": width, "height": height, "fps": fps}).to_string()
}

/// Push one camera frame (raw pixels, `fmt`: i420|nv12|bgra|420v|32bgra).
/// Convert failures count as drops (still `{ok:true}` + stats).
pub fn camera_push_bytes_json(data: &[u8], width: u32, height: u32, fmt: &str) -> String {
    if data.len() > MAX_FRAME_BYTES {
        return err_json("arg", format!("frame too large: {} bytes", data.len()));
    }
    let pix = match macav::PixFmt::parse(fmt) {
        Ok(p) => p,
        Err(e) => return err_json("arg", e),
    };
    // Single lock: push + stats under one guard (was: push, then a
    // second lock inside camera_stats_json, per frame).
    let s = {
        let mut pump = lock(camera_pump());
        pump.push(data, width, height, pix);
        pump.stats()
    };
    camera_stats_body(&s)
}

pub fn camera_stats_json() -> String {
    camera_stats_body(&lock(camera_pump()).stats())
}

fn camera_stats_body(s: &macav::CameraStats) -> String {
    json!({
        "ok": true,
        "running": s.running,
        "width": s.width,
        "height": s.height,
        "fps_want": s.fps_want,
        "frames": s.frames,
        "dropped": s.dropped,
        "fps_actual": s.fps_actual,
        "last_bytes": s.last_bytes,
    })
    .to_string()
}

pub fn camera_end_json() -> String {
    lock(camera_pump()).end();
    json!({"ok": true}).to_string()
}

/// Push one decoded remote I420 frame (raw bytes) for the SwiftUI view.
pub fn video_push_remote_bytes_json(data: &[u8], width: u32, height: u32) -> String {
    if data.len() > MAX_FRAME_BYTES {
        return err_json("arg", format!("frame too large: {} bytes", data.len()));
    }
    let need = macav::I420Frame::expected_len(width, height);
    if width == 0 || height == 0 || data.len() < need {
        return err_json(
            "arg",
            format!("i420 too small: {} bytes, need {}", data.len(), need),
        );
    }
    // Copy outside the lock: the mutex is never held across the
    // frame-sized memcpy (was: to_vec inside the push arg).
    let frame = macav::I420Frame {
        width,
        height,
        data: data[..need].to_vec(),
    };
    lock(remote_slot()).push(frame);
    json!({"ok": true, "bytes": need}).to_string()
}

/// Drain the latest remote frame, if any.
pub fn video_poll_remote_raw() -> Option<macav::I420Frame> {
    lock(remote_slot()).take()
}

/// Black 176x144 IDR access unit as base64 NALs (VideoToolbox target).
pub fn black_iframe_json() -> String {
    json!({
        "ok": true,
        "width": 176,
        "height": 144,
        "nals": macav::black_iframe_b64(),
    })
    .to_string()
}

/// Offline call pipeline (SRTP loopback + H.264 packetize round-trip).
pub fn call_dry_run_json() -> String {
    match macav::call_dry_run() {
        Ok(r) => json!({
            "ok": true,
            "audio_sent": r.audio_sent,
            "audio_received": r.audio_received,
            "echo_detected": r.echo_detected,
            "echo_delay_ms": r.echo_delay_ms,
            "echo_correlation": r.echo_correlation,
            "video_packets": r.video_packets,
            "video_nals": r.video_nals,
        })
        .to_string(),
        Err(e) => err_json("dry_run", e),
    }
}

// ---------------------------------------------------------------------------
// C ABI (caller frees every return with `ostmac_free`)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn ostmac_mic_probe() -> *mut c_char {
    string_to_c(mic_probe_json())
}

#[no_mangle]
pub extern "C" fn ostmac_mic_test(seconds: c_int) -> *mut c_char {
    let s = if seconds <= 0 { 3 } else { seconds as u64 };
    string_to_c(mic_test_json(s))
}

#[no_mangle]
pub extern "C" fn ostmac_tone_play(msecs: c_int) -> *mut c_char {
    let ms = if msecs <= 0 { 1000 } else { msecs as u64 };
    string_to_c(tone_play_json(ms))
}

#[no_mangle]
pub extern "C" fn ostmac_audio_devices() -> *mut c_char {
    string_to_c(audio_devices_json())
}

#[no_mangle]
pub extern "C" fn ostmac_mic_test_on(
    seconds: c_int,
    input: *const c_char,
    output: *const c_char,
) -> *mut c_char {
    let s = if seconds <= 0 { 3 } else { seconds as u64 };
    let i = opt_name(input);
    let o = opt_name(output);
    string_to_c(mic_test_on_json(s, i.as_deref(), o.as_deref()))
}

#[no_mangle]
pub extern "C" fn ostmac_tone_play_on(msecs: c_int, output: *const c_char) -> *mut c_char {
    let ms = if msecs <= 0 { 1000 } else { msecs as u64 };
    let o = opt_name(output);
    string_to_c(tone_play_on_json(ms, o.as_deref()))
}

#[no_mangle]
pub extern "C" fn ostmac_mic_level(msecs: c_int, input: *const c_char) -> *mut c_char {
    let ms = if msecs <= 0 { 150 } else { msecs as u64 };
    let i = opt_name(input);
    string_to_c(mic_level_json(ms, i.as_deref()))
}

#[no_mangle]
pub extern "C" fn ostmac_camera_begin(width: c_int, height: c_int, fps: c_int) -> *mut c_char {
    string_to_c(camera_begin_json(
        width.max(0) as u32,
        height.max(0) as u32,
        fps.max(0) as u32,
    ))
}

#[no_mangle]
pub extern "C" fn ostmac_camera_push_bytes(
    pixels: *const u8,
    len: usize,
    width: c_int,
    height: c_int,
    fmt: *const c_char,
) -> *mut c_char {
    let data = match bytes_arg(pixels, len) {
        Ok(d) => d,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let format = match cstr_to_string(fmt) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    string_to_c(camera_push_bytes_json(
        data,
        width.max(0) as u32,
        height.max(0) as u32,
        &format,
    ))
}

#[no_mangle]
pub extern "C" fn ostmac_camera_stats() -> *mut c_char {
    string_to_c(camera_stats_json())
}

#[no_mangle]
pub extern "C" fn ostmac_camera_end() -> *mut c_char {
    string_to_c(camera_end_json())
}

#[no_mangle]
pub extern "C" fn ostmac_video_push_remote_bytes(
    data: *const u8,
    len: usize,
    width: c_int,
    height: c_int,
) -> *mut c_char {
    match bytes_arg(data, len) {
        Ok(d) => string_to_c(video_push_remote_bytes_json(
            d,
            width.max(0) as u32,
            height.max(0) as u32,
        )),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[no_mangle]
pub extern "C" fn ostmac_video_poll_remote_bytes(
    width: *mut c_int,
    height: *mut c_int,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if width.is_null() || height.is_null() || out.is_null() || out_len.is_null() {
        return -1;
    }
    match video_poll_remote_raw() {
        Some(f) => unsafe {
            *width = f.width as c_int;
            *height = f.height as c_int;
            let boxed = f.data.into_boxed_slice();
            *out_len = boxed.len();
            *out = Box::into_raw(boxed) as *mut u8;
            1
        },
        None => unsafe {
            *width = 0;
            *height = 0;
            *out = std::ptr::null_mut();
            *out_len = 0;
            0
        },
    }
}

#[no_mangle]
pub extern "C" fn ostmac_av_black_iframe() -> *mut c_char {
    string_to_c(black_iframe_json())
}

#[no_mangle]
pub extern "C" fn ostmac_call_dry_run() -> *mut c_char {
    string_to_c(call_dry_run_json())
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no hardware; camera/remote globals used by one test each)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// Serializes tests that share the global `remote_slot()`.
    static REMOTE_SLOT_LOCK: Mutex<()> = Mutex::new(());
    fn remote_slot_lock() -> std::sync::MutexGuard<'static, ()> {
        REMOTE_SLOT_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    // NOTE (R12 ffi-move-now B1): av_info shape test moved to Swift
    // (FfiMoveNowTests).

    // NOTE (R12 ffi-move-now B2): tone_check detect test moved to
    // Swift (FfiMoveNowTests).

    #[test]
    fn av_camera_push_stats_roundtrip() {
        // begin rejects zero dims without touching state
        let v: serde_json::Value = serde_json::from_str(&camera_begin_json(0, 240, 15)).unwrap();
        assert_eq!(v["ok"], false);

        let v: serde_json::Value =
            serde_json::from_str(&camera_begin_json(320, 240, 15)).unwrap();
        assert_eq!(v["ok"], true);

        // bad fmt is an arg error
        let tiny = [0u8; 4];
        let v: serde_json::Value =
            serde_json::from_str(&camera_push_bytes_json(&tiny, 320, 240, "mjpeg")).unwrap();
        assert_eq!(v["ok"], false);

        // one good BGRA frame (320x240x4)
        let bgra = vec![0x80u8; 320 * 240 * 4];
        let v: serde_json::Value =
            serde_json::from_str(&camera_push_bytes_json(&bgra, 320, 240, "bgra")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["frames"], 1);
        assert_eq!(v["last_bytes"], 320 * 240 * 3 / 2);

        // short buffer counts as drop, still ok
        let v: serde_json::Value =
            serde_json::from_str(&camera_push_bytes_json(&tiny, 320, 240, "bgra")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["frames"], 1);
        assert_eq!(v["dropped"], 1);

        let v: serde_json::Value = serde_json::from_str(&camera_end_json()).unwrap();
        assert_eq!(v["ok"], true);
        let v: serde_json::Value = serde_json::from_str(&camera_stats_json()).unwrap();
        assert_eq!(v["running"], false);
    }

    #[test]
    fn av_video_push_poll_roundtrip() {
        let _g = remote_slot_lock();
        // drain first so parallel order can't leak a frame in
        let _ = video_poll_remote_raw();
        assert!(video_poll_remote_raw().is_none());

        // reject short buffers
        let v: serde_json::Value =
            serde_json::from_str(&video_push_remote_bytes_json(&[0u8; 4], 320, 240)).unwrap();
        assert_eq!(v["ok"], false);

        let i420 = vec![0x10u8; 320 * 240 * 3 / 2];
        let v: serde_json::Value =
            serde_json::from_str(&video_push_remote_bytes_json(&i420, 320, 240)).unwrap();
        assert_eq!(v["ok"], true);

        let f = video_poll_remote_raw().expect("frame");
        assert_eq!(f.width, 320);
        assert_eq!(f.height, 240);
        assert_eq!(f.data, i420); // bit-identical, no encode round-trip

        // poll drains
        assert!(video_poll_remote_raw().is_none());
    }

    #[test]
    fn av_black_iframe_shape() {
        let v: serde_json::Value = serde_json::from_str(&black_iframe_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["width"], 176);
        assert_eq!(v["height"], 144);
        assert_eq!(v["nals"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn av_dry_run_loops() {
        let v: serde_json::Value = serde_json::from_str(&call_dry_run_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["audio_sent"], 25);
        assert_eq!(v["audio_received"], 25);
        assert_eq!(v["echo_detected"], true);
        assert_eq!(v["video_packets"], 5);
        assert_eq!(v["video_nals"], 5);
    }

    #[test]
    fn av_ffi_camera_begin_rejects_zero() {
        unsafe {
            let p = ostmac_camera_begin(0, 0, 0);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn av_audio_devices_shape() {
        // No hardware asserted — lists may be empty on headless.
        let v: serde_json::Value = serde_json::from_str(&audio_devices_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["inputs"].is_array());
        assert!(v["outputs"].is_array());
    }

    #[test]
    fn av_mic_level_unknown_device_has_no_input() {
        // Deterministic with or without hardware: a bogus name never matches.
        let v: serde_json::Value =
            serde_json::from_str(&mic_level_json(50, Some("ostmac-no-such-device"))).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["has_input"], false);
        assert_eq!(v["peak_db"], -60.0);
    }

    #[test]
    fn av_named_test_unknown_device_errors() {
        let v: serde_json::Value =
            serde_json::from_str(&mic_test_on_json(1, Some("ostmac-no-such-device"), None))
                .unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "unknown_device");
        let v: serde_json::Value =
            serde_json::from_str(&tone_play_on_json(100, Some("ostmac-no-such-device"))).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "unknown_device");
    }

    #[test]
    fn av_f32_converters_roundtrip() {
        // Gate-covered (ost audio tests need --features audio): pure
        // converter checks over the real ost functions, no hardware.
        use ost::calling::audio as a;
        assert_eq!(a::f32_to_i16(0.0), 0);
        assert_eq!(a::f32_to_i16(1.0), 32767);
        assert_eq!(a::f32_to_i16(-1.5), -32767);
        assert_eq!(a::i16_to_f32(0), 0.0);
        assert_eq!(
            a::f32_interleaved_to_mono_i16(&[1.0, -1.0], 2),
            vec![0]
        );
        assert_eq!(
            a::f32_interleaved_to_mono_i16(&[0.5, 0.5], 2),
            vec![16384]
        );
    }

    #[test]
    fn av_audio_error_code_splits_open_from_resolve() {
        // Pure mapping: no hardware touched.
        assert_eq!(
            audio_error_code("Unknown audio input device: X", "no_input"),
            "unknown_device"
        );
        assert_eq!(
            audio_error_code(
                "Failed to open audio input device 'X': build failed",
                "no_input"
            ),
            "open_failed"
        );
        assert_eq!(
            audio_error_code(
                "Failed to open audio output device: build failed",
                "no_output"
            ),
            "open_failed"
        );
        assert_eq!(audio_error_code("No audio input device found", "no_input"), "no_input");
        assert_eq!(
            audio_error_code("No audio output device found", "no_output"),
            "no_output"
        );
    }

    #[test]
    fn av_ffi_mic_level_null_is_ok() {
        unsafe {
            let p = ostmac_mic_level(50, std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], true);
        }
    }

    #[test]
    fn av_ffi_push_null_is_arg_error() {
        unsafe {
            let fmt = CString::new("bgra").unwrap();
            let p = ostmac_camera_push_bytes(std::ptr::null(), 16, 2, 2, fmt.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn av_ffi_remote_bytes_roundtrip() {
        let _g = remote_slot_lock();
        let _ = video_poll_remote_raw(); // drain
        unsafe {
            let i420 = vec![0x10u8; 64 * 64 * 3 / 2];
            let p = ostmac_video_push_remote_bytes(i420.as_ptr(), i420.len(), 64, 64);
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["ok"], true);
            let mut w: c_int = 0;
            let mut h: c_int = 0;
            let mut out: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            assert_eq!(
                ostmac_video_poll_remote_bytes(&mut w, &mut h, &mut out, &mut out_len),
                1
            );
            assert_eq!((w, h), (64, 64));
            let got = std::slice::from_raw_parts(out, out_len).to_vec();
            crate::ostmac_bytes_free(out, out_len);
            assert_eq!(got, i420);
            assert_eq!(
                ostmac_video_poll_remote_bytes(&mut w, &mut h, &mut out, &mut out_len),
                0
            );
            assert!(out.is_null());
            assert_eq!(
                ostmac_video_poll_remote_bytes(
                    std::ptr::null_mut(),
                    &mut h,
                    &mut out,
                    &mut out_len
                ),
                -1
            );
        }
        let _ = video_poll_remote_raw(); // leave drained
    }
}
