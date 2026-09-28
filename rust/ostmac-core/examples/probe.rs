//! Manual probe: trouter-start code, device-code start (network).
//! `cargo run --example probe` (unsigned env expected: trouter -2).
//! NOTE (R12 ffi-move-now B0): status moved to Swift (CoreLocal).

fn main() {
    println!("version: {}", env!("CARGO_PKG_VERSION"));
    println!("trouter_start: {}", ostmac_core::trouter_start());
    println!("trouter_poll: {}", ostmac_core::trouter_poll_json());
    println!("trouter_stop: {}", ostmac_core::trouter_stop());
    // NOTE (R14 om-later-b18 B18): device flow moved to Swift
    // (DeviceAuth); nothing to probe from Rust anymore.
    let _ = std::env::var("OSTMAC_PROBE_DEVICE");
    println!("device_start: moved to Swift (DeviceAuth)");
}
