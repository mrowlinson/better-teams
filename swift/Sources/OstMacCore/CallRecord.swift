// CallRecord.swift — P4 split: verbatim move from CallHistory.swift.
import Foundation

/// One finished call. Unix-second stamps (UTC, DST-proof); labels are
/// derived host-side. `thread` is empty on incoming legs (no redial).
public struct CallRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let direction: CallDirection
    public let peer: String
    public let peerName: String
    public let thread: String
    public let startedAt: UInt64
    public let endedAt: UInt64
    /// Connected seconds; 0 when the call never connected.
    public let durationSecs: UInt64

    public init(
        id: String, direction: CallDirection,
        peer: String = "", peerName: String = "", thread: String = "",
        startedAt: UInt64, endedAt: UInt64, durationSecs: UInt64 = 0
    ) {
        self.id = id
        self.direction = direction
        self.peer = peer
        self.peerName = peerName
        self.thread = thread
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSecs = durationSecs
    }

    public var isMissed: Bool { direction == .missed }

    /// Name, else MRI, else thread (CallInfo.displayPeer rules).
    public var displayName: String {
        if !peerName.isEmpty { return peerName }
        if !peer.isEmpty { return peer }
        return thread
    }

    /// Start time: locale short clock today ("12:53 PM" en_US), else
    /// clock + "22 Sep" (ChatMessage rules).
    public var displayTime: String {
        Self.displayTime(
            for: Date(timeIntervalSince1970: TimeInterval(startedAt)))
    }

    /// Start-time label (fid-time D8/D9): locale short clock in
    /// `timeZone`, day boundary in `timeZone`.
    public static func displayTime(
        for date: Date, now: Date = Date(),
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let clock = TeamsTime.clock(date, timeZone: timeZone, locale: locale)
        if cal.isDate(date, inSameDayAs: now) { return clock }
        return "\(clock) \(TeamsTime.dayMonth(date, timeZone: timeZone))"
    }

    /// "0:43", "12:05", "1:02:03" (hours only when non-zero).
    public var durationLabel: String { Self.durationLabel(durationSecs) }

    public static func durationLabel(_ secs: UInt64) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "Missed · 12:53 PM" / "… · 0:43 · 12:53 PM 22 Sep" row subtitle (en_US).
    public var detailLine: String {
        if isMissed { return "Missed · \(displayTime)" }
        if durationSecs == 0 { return "\(direction.label) · \(displayTime)" }
        return "\(direction.label) · \(durationLabel) · \(displayTime)"
    }
}
