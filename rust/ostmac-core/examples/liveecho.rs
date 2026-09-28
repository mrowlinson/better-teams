//! Live echo-bot call probe: place echo-live, print media stats, hang up.
//! `cargo run --example liveecho [secs=20] [timeout=30]` (needs auth).
//! Send-side video is black IDR (no camera in a CLI probe); mic/speaker run
//! when cpal devices exist. Prints one JSON stats line per 2s.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let secs: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(20);
    let timeout: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(30);

    let placed = ostmac_core::calls::call_echo_live_json(timeout);
    println!("place: {}", placed);
    let live = serde_json::from_str::<serde_json::Value>(&placed)
        .ok()
        .and_then(|v| v["live_media"].as_bool())
        .unwrap_or(false);
    if !live {
        return;
    }
    let ticks = secs.div_ceil(2);
    for _ in 0..ticks {
        std::thread::sleep(std::time::Duration::from_secs(2));
        println!("media: {}", ostmac_core::live::call_media_json());
    }
    println!("end: {}", ostmac_core::calls::call_end_json());
}
