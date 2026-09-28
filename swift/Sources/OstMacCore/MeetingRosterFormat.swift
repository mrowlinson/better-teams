// MeetingRosterFormat.swift — P4 split: verbatim move from MeetingChat.swift.

// Accessibility + icon contract shared by the row and tests.
public enum MeetingRosterFormat {
    public static func micIcon(muted: Bool) -> String {
        muted ? "mic.slash.fill" : "mic.fill"
    }

    public static func accessibilityLabel(for p: MeetingParticipant) -> String {
        var parts = [p.name]
        parts.append(p.muted ? "muted" : "unmuted")
        if p.speaking { parts.append("speaking") }
        return parts.joined(separator: ", ")
    }
}
