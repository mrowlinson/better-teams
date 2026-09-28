// MeetingDemo.swift — P4 split: verbatim move from MeetingChat.swift.

public enum MeetingDemo {
    public static let threadID = "19:meeting_demo@thread.v2"
    public static let threadName = "Design Sync (meeting)"

    public static let participants = [
        MeetingParticipant(id: "8:orgid:megan", name: "Megan Harper", speaking: true),
        MeetingParticipant(id: "8:orgid:tom", name: "Tom Becker", muted: true),
        MeetingParticipant(id: "8:orgid:me", name: "Me"),
    ]

    public static let messages = [
        ChatMessage(
            id: "meet-1", sender: "Megan Harper",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Morning! Design sync in 10. Dropping the agenda here."),
        ChatMessage(
            id: "meet-2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:04:47Z",
            content: "Mocks are up — link in the Shared tab after the call."),
        ChatMessage(
            id: "meet-3", sender: "Me",
            timestamp: "2026-09-22T09:07:30Z",
            content: "On mute, following along.", isOwn: true),
    ]
}
