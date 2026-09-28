// ScreenShareSummary.swift — P4 split: verbatim move from ScreenShare.swift.

public enum ScreenShareSummary {
    /// Phase -> one human word (failures keep their detail). No numbers —
    /// counters live in Diagnostics only.
    public static func status(phase: ScreenSharePhase, lastError: String?) -> String {
        switch phase {
        case .idle: return "Off"
        case .picking: return "Choose a screen…"
        case .starting: return "Starting…"
        case .live: return "Live"
        case .stopping: return "Stopping…"
        case .failed:
            guard let lastError, !lastError.isEmpty else { return "Failed" }
            return "Failed — \(lastError)"
        }
    }

    /// Source -> one-line label.
    public static func label(for source: ScreenShareSource) -> String {
        switch source.kind {
        case .display: return "Display · \(source.name)"
        case .window: return "Window · \(source.name)"
        case .app: return "App · \(source.name)"
        }
    }

    /// Denied-permission hint (mirrors AvSummary.micDenied).
    public static let denied =
        "Screen Recording denied — allow Better Teams in System Settings › Privacy & Security › Screen Recording"

    /// Tile preview-vs-placeholder decision (pure, unit-tested).
    /// No-blank guarantee: every combo renders something — a live
    /// frame, or a status placeholder. Live without a frame yet (stream
    /// just started, frame dropped) shows the "Live" word, never an
    /// empty tile — the Teams blank-share failure mode (BetaNews
    /// 2026-07-12) cannot render as silence here.
    public static func tileContent(
        phase: ScreenSharePhase, hasPreview: Bool
    ) -> ScreenShareTileContent {
        (phase.isLive && hasPreview) ? .preview : .placeholder
    }
}
