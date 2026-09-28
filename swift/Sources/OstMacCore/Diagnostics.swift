// Diagnostics.swift — om-statusbar lane: pure one-line formatters for the
// counters that moved out of the status bar into the Diagnostics window
// (Window ▸ Diagnostics). The slim status bar (Live dot + errors) and the
// Diagnostics window share these so the tooltip and the rows never drift.
// Tested (DiagnosticsTests); views stay dumb.
import Foundation

public enum DiagnosticsFormat {
    /// `core 1.2.3 · init=0` (was the status bar's leading counter).
    public static func coreLine(version: String, initCode: Int32) -> String {
        "core \(version) · init=\(initCode)"
    }

    /// Session one-liner: demo mode, signed in/out, or still checking.
    public static func sessionLine(isDemo: Bool, signedIn: Bool?) -> String {
        if isDemo { return "DEMO · offline" }
        return switch signedIn {
        case .some(true): "signed in"
        case .some(false): "signed out"
        case .none: "auth ?"
        }
    }

    /// Full feed line with counters (was the status bar's feed text).
    public static func feedLine(
        state: RealtimeFeed.State, events: Int, polls: Int, resyncs: Int
    ) -> String {
        switch state {
        case .live:
            "Live · \(events) new · \(polls) polls · \(resyncs) resyncs"
        case .retryWait:
            "Connecting… (\(events) new · \(resyncs) resyncs)"
        case .stopped:
            "Realtime off"
        }
    }

    /// Short feed state word for the status-bar dot tooltip prefix.
    public static func feedWord(state: RealtimeFeed.State) -> String {
        switch state {
        case .live: "Live"
        case .retryWait: "Connecting…"
        case .stopped: "Realtime off"
        }
    }

    /// Typing counters (om-typing): session events + live indicators.
    /// Diagnostics window only — typing never shows a count elsewhere.
    public static func typingLine(events: Int, active: Int) -> String {
        "\(events) events · \(active) active"
    }

    /// Read-receipt counters (om-receipts): sent positions, tracked
    /// threads, peer positions. Timeline shows Seen with no numbers;
    /// the counts live here only.
    public static func receiptsLine(sent: Int, threads: Int, peers: Int) -> String {
        "\(sent) sent · \(threads) threads · \(peers) peers"
    }

    /// Recent-call counters (om-call-history): entries + missed. The
    /// list lives in the Recent Calls window; counts live here only.
    public static func callsLine(total: Int, missed: Int) -> String {
        "\(total) recent · \(missed) missed"
    }

    /// Meetings counters (om-meet-join): upcoming fetched, joins
    /// started, lobby state. The Meetings window shows no numbers;
    /// the counts live here only.
    public static func meetingsLine(fetched: Int, joins: Int, lobby: String) -> String {
        "\(fetched) upcoming · \(joins) joins · \(lobby)"
    }

    /// Meeting-roster counters (om-meet-chat): session events + live
    /// rows + speaking + muted. Diagnostics window only — the roster
    /// shows no counts.
    public static func rosterLine(events: Int, active: Int, speaking: Int, muted: Int) -> String {
        "\(events) events · \(active) in roster · \(speaking) speaking · \(muted) muted"
    }

    /// Meeting-thread one-liner (om-meet-chat): persisted message
    /// count + live/ended state. Diagnostics window only.
    public static func meetingThreadLine(messages: Int, live: Bool) -> String {
        "\(messages) messages · \(live ? "live" : "ended")"
    }

    /// Screen-share counters (om-screenshare): source label + captured/
    /// sent frames. The tile shows status words only; the numbers live
    /// here. Nil/blank source (idle) reads "off".
    public static func shareLine(source: String?, frames: Int, sent: Int) -> String {
        guard let source, !source.isEmpty else { return "off" }
        return "\(source) · \(frames) frames · \(sent) sent"
    }

    /// Image-preload counters (om-imgpreload): completed prefills,
    /// window targets already cached, cancelled far fetches, fills in
    /// flight. Diagnostics window only — chats never show counts.
    public static func preloadLine(prefetched: Int, hits: Int, cancelled: Int, inFlight: Int) -> String {
        "\(prefetched) prefetched · \(hits) hits · \(cancelled) cancelled · \(inFlight) in flight"
    }

    /// Quiet-hours state (om-quiet-hours): which source is active plus
    /// session banners suppressed. Diagnostics window only — the
    /// suppressed count appears nowhere else (no sidebar, no Settings).
    /// Focus (e2-attention) joins the source list, defaulted (old 3-arg
    /// calls stay byte stable).
    public static func quietHoursLine(dnd: Bool, schedule: Bool, suppressed: Int, focus: Bool = false) -> String {
        var sources: [String] = []
        if schedule { sources.append("schedule") }
        if dnd { sources.append("DND") }
        if focus { sources.append("Focus") }
        let state = sources.isEmpty ? "off" : "on (\(sources.joined(separator: " + ")))"
        return "\(state) · \(suppressed) suppressed"
    }

    /// Mention-row one-liner (om-mention-alerts): unreviewed mentioning
    /// threads (the Mentions row filter source). Diagnostics mirrors the
    /// row count; the Dock tile shows the same number.
    public static func mentionsLine(count: Int) -> String {
        "\(count) threads"
    }

    /// Unread one-liner (om-mention-alerts): total messages + chats with
    /// unread. Sidebar rows badge per chat; the totals live here only.
    public static func unreadLine(total: Int, chats: Int) -> String {
        "\(total) messages · \(chats) chats"
    }

    /// Mention-alert one-liner (om-mention-alerts): breakthroughs
    /// through mute + DND/quiet suppressions. Banners/sounds are the
    /// only interruption; the counts live here only.
    public static func mentionAlertsLine(breakthroughs: Int, dnd: Int, quiet: Int) -> String {
        "\(breakthroughs) breakthroughs · \(dnd) DND · \(quiet) quiet"
    }

    /// Notification counters (om-notif-live): rules notify/skip
    /// decisions this session + the last decision reason. Diagnostics
    /// window only — banners carry no counts.
    public static func notifLine(posted: Int, skipped: Int, lastReason: String) -> String {
        "\(posted) posted · \(skipped) skipped · last \(lastReason.isEmpty ? "—" : lastReason)"
    }

    /// User-pin one-liner (om-userpins): persisted pin count.
    /// Diagnostics window only — sidebar rows show a pin glyph,
    /// never a number.
    public static func pinsLine(count: Int) -> String {
        "\(count) pinned"
    }

    /// Leave/block counters (om-leave-block): threads left this
    /// session, users currently blocked, failed leave calls. The
    /// sidebar and Settings show no numbers; the counts live here only.
    public static func leaveBlockLine(leaves: Int, blocks: Int, failed: Int) -> String {
        "\(leaves) left · \(blocks) blocked · \(failed) failed"
    }

    /// Jump-to-message verdicts (gap-g9): seek attempts, landed jumps,
    /// and id misses with the miss rate. The miss rate is the live
    /// signal for Graph-hit-id vs native-history-id divergence: a
    /// climbing rate means the mapping needs a fix, not more paging.
    /// Diagnostics window only — the timeline banners the miss itself.
    public static func seekLine(attempted: Int, landed: Int, missed: Int) -> String {
        guard attempted > 0 else { return "no jumps yet" }
        let pct = Int((Double(missed) / Double(attempted) * 100).rounded())
        return "\(attempted) attempts · \(landed) landed · \(missed) missed (\(pct)%)"
    }

    /// Ghost-mode state (f1-ghost): which signals are suppressed plus
    /// session suppressed/held counts. Diagnostics window only — the
    /// counters appear nowhere else (no sidebar, no Settings). Master
    /// off reads "off" even with stale sub-toggles (subs need master).
    public static func ghostLine(
        master: Bool, receipts: Bool, presence: Bool, suppressed: Int, held: Int
    ) -> String {
        var signals: [String] = []
        if master {
            if receipts { signals.append("receipts") }
            if presence { signals.append("presence") }
        }
        let state = signals.isEmpty ? "off" : "on (\(signals.joined(separator: " + ")))"
        return "\(state) · \(suppressed) suppressed · \(held) held"
    }
}
