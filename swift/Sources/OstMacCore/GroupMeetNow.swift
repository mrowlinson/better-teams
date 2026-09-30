// GroupMeetNow.swift — CAL2: group-chat Meet now starts a real Teams
// meeting like Teams does: an online meeting is created now (on the
// user's calendar, no calendar invitations mailed), its invitation is
// posted into the group chat (every member sees it and can join), and
// the user joins the meeting. Replaces the ringing thread call.
import Foundation

public enum GroupMeetNow {
    /// Teams' name for an instant meeting started from a chat.
    public static func subject(chatName: String) -> String {
        let name = chatName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Meet now" : "Meeting in \u{201C}\(name)\u{201D}"
    }

    /// The chat message carrying the join link.
    public static func invitation(subject: String, joinURL: String) -> String {
        "I started a meeting: \(subject)\nJoin: \(joinURL)"
    }

    /// One verified post of `text` to `chatID` (blocking: off-main).
    public static func post(chatID: String, text: String) throws {
        _ = try SendPipeline.postVerified(chatID: chatID, text: text)
    }

    public enum Outcome: Equatable, Sendable {
        case started(MeetingItem)
        /// The meeting exists but the invitation didn't post (joined anyway).
        case startedNotPosted(MeetingItem, String)
        case failed(String)
    }

    /// Create → post the invitation to `chatID` → join. `create` returns
    /// nil with `createError()` explaining; `post` throws on failure.
    @MainActor
    public static func run(chatID: String, chatName: String,
                           create: (String) async -> MeetingItem?,
                           createError: () -> String?,
                           post: (String, String) async throws -> Void,
                           join: (MeetingItem) -> Void) async -> Outcome {
        let name = subject(chatName: chatName)
        guard let row = await create(name) else {
            return .failed(createError() ?? "Couldn\u{2019}t start the meeting")
        }
        guard let link = row.joinURL, !link.isEmpty else {
            return .failed("The meeting has no join link yet")
        }
        var outcome = Outcome.started(row)
        do {
            try await post(chatID, invitation(subject: name, joinURL: link))
        } catch {
            outcome = .startedNotPosted(row, FriendlyError.message(for: error))
        }
        join(row)
        return outcome
    }
}
