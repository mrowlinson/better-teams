// AvSummary.swift — P4 split: verbatim move from AvPanelView.swift.
import Foundation

/// Terse, numbers-first result strings. No key=value in the main view.
public enum AvSummary {
    public static func micTest(_ r: MicTestResult) -> String {
        String(format: "%.1fs · peak %.0fdB · %@", r.seconds, r.peak_db,
            r.played_back ? "played back" : "no playback")
    }

    public static func tone(frames: Int, msecs: Int) -> String {
        String(format: "%.1fs · %d frames", Double(msecs) / 1000, frames)
    }

    public static func cameraStats(_ s: CameraStats) -> String {
        String(format: "%d frames · %.1f fps · %d dropped",
            s.frames, s.fps_actual, s.dropped)
    }

    /// Raw camera status -> one human word (failures keep their detail).
    public static func cameraStatus(_ raw: String) -> String {
        switch raw {
        case "idle", "stopped": return "Off"
        case "starting…": return "Starting…"
        case "capturing": return "Live"
        case "stopping…": return "Stopping…"
        default: break
        }
        if let rest = rest(after: "failed: ", in: raw) { return "Failed — \(rest)" }
        if let rest = rest(after: "push failed: ", in: raw) { return "Push failed — \(rest)" }
        return raw
    }

    /// Core error -> human line. Unknown shapes pass through untouched.
    public static func friendlyError(_ e: Error) -> String {
        guard case let CoreCallError.failed(m) = e else { return e.localizedDescription }
        if m.contains("unknown_device") { return "Device unplugged — pick another" }
        if m.contains("open_failed") { return "Couldn't open device — try again" }
        if m.contains("no_input") { return "Microphone unavailable" }
        if m.contains("no_output") { return "Speaker unavailable" }
        return m
    }

    /// True when a core error is a stale device pick (unknown_device).
    /// open_failed is NOT unknown: the pick resolved, the stream failed —
    /// the panel must not heal it away.
    public static func isUnknownDevice(_ e: Error) -> Bool {
        guard case let CoreCallError.failed(m) = e else { return false }
        return m.contains("unknown_device")
    }

    /// Mic TCC denial -> human line + where to fix it.
    public static let micDenied =
        "Microphone denied — allow Better Teams in System Settings › Privacy & Security › Microphone"

    /// True-unplug heal: the pick is gone, the panel switched to the default.
    public static func healedMic(_ fallback: String?) -> String {
        "Device unplugged — switched to \(fallback ?? "System Default")"
    }

    public static func healedSpeaker(_ fallback: String?) -> String {
        "Device unplugged — switched to \(fallback ?? "System Default")"
    }

    /// Empty-list wedge: the rescan found nothing (HAL wedge, not a true
    /// unplug) — the pick is kept, Rescan retries.
    public static func wedgeKept(_ pick: String?) -> String {
        "No devices found — kept \(pick ?? "selection") (Rescan to retry)"
    }

    /// The stale pick is back in the fresh list (transient error).
    public static let deviceBack = "Device available again — retry the test"

    /// Device scan exceeded N seconds (wedged HAL/driver): the pickers
    /// stop spinning and offer Rescan instead of "Scanning…" forever.
    public static let scanTimedOut = "Device scan timed out — Rescan to retry"

    /// Probe placeholder until the Test-owned mic grant lands.
    public static let probePending = "pending mic access"

    private static func rest(after prefix: String, in s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }
}
