// SidebarIngest.swift — om-sidebarchurn: realtime → row decision.
//
// The live feed carries meeting beacons, card payloads, bot chatter, and
// system notices alongside user text. Bubbling the sidebar on all of them
// churns row order and litters previews with "TitlePlay"/JSON/blank text.
// This classifier is the single policy: skip (no row change, no reorder),
// refresh (preview update in place), or bubble (preview + move to top).
import Foundation

/// Sidebar ingest policy. Pure; every branch covered by tests.
public enum SidebarIngest {
    /// Row effect of one realtime event.
    public enum Outcome: Sendable, Equatable {
        /// No row change, no reorder, no publish.
        case skip
        /// Preview/sender/time update in place, no reorder.
        case refresh
        /// Preview update + move to top.
        case bubble
    }

    /// Classify one event for the row named `chatName`.
    ///
    /// - Empty text: skip, unless the raw body carries an image
    ///   (image-only bubbles surface like history keeps them; the
    ///   preview falls back to the sender line). Reaction-only
    ///   patches never blank a preview.
    /// - Play beacons, meeting blobs, Facilitator bookends: skip, in
    ///   every thread — a beacon is never a preview anywhere.
    /// - Plain JSON/code blobs: skip in meeting threads, from unknown
    ///   senders, and from bots/system; a human paste in a normal chat
    ///   still surfaces (status quo bubble).
    /// - Media cards (`Media_` types): skip (history skips them too;
    ///   their stripped text is `TitlePlay` fragments or raw JSON).
    /// - Bots (`28:` sender MRI, Facilitator residue) + system types
    ///   (`ThreadActivity`, `Control`, …): refresh in place.
    /// - Meeting cards (chrome + human lines): refresh in place; the
    ///   human lines become the preview (see ``humanLines``).
    /// - Edits: refresh in place (existing behavior).
    /// - Anything else with text: bubble. Unknown message types (old
    ///   cores omit `message_type`) bubble — unclassifiable, never skip.
    public static func decide(message: RealtimeMessage, chatName: String) -> Outcome {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageOnly = trimmed.isEmpty && hasImageHTML(message.raw)
        if trimmed.isEmpty, !imageOnly { return .skip }
        if !imageOnly {
            switch MeetingSignal.classify(
                text: message.text, content: message.raw ?? message.text,
                chatID: message.chatID, senderName: message.sender,
                chatDisplayName: chatName
            ) {
            case .playBeacon, .meetingBlob, .facilitatorOpen,
                 .facilitatorClose, .emptyText:
                return .skip
            case .jsonBlob, .codeBlob:
                if MeetingSignal.isMeetingThread(message.chatID)
                    || MeetingSignal.isUnknownSender(message.sender)
                    || isBot(message) || isSystem(message)
                {
                    return .skip
                }
            case .normal:
                break
            }
        }
        let typeRaw = (message.messageType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if typeRaw.contains("Media_") { return .skip }
        if isBot(message) {
            // A bot's own 1:1 chat (Workflows, Polly…) is a conversation
            // like any other: Teams moves it to the top on a new post.
            let botMRI = message.senderID?.hasPrefix("28:") == true
            return botMRI && isBotChat(message.chatID) && !message.isEdit && !isSystem(message) ? .bubble : .refresh
        }
        if isSystem(message) { return .refresh }
        if message.isEdit { return .refresh }
        if MeetingSignal.isMeetingThread(message.chatID), isMixedCard(message.text) {
            return .refresh
        }
        return .bubble
    }

    /// Bot senders: Bot Framework MRIs (`28:…`, cf `ECHO_BOT_MRI`) or
    /// Facilitator residue that isn't an open/close bookend (skipped above).
    public static func isBot(_ message: RealtimeMessage) -> Bool {
        if let id = message.senderID, id.hasPrefix("28:") { return true }
        return MeetingSignal.isFacilitator(message.sender)
    }

    /// A 1:1 chat with a bot: the legacy bare bot MRI id (`28:…`) or a
    /// 1:1 id (`19:…@unq.gbl.spaces`) whose pair names a bot app. The
    /// bot sender check (`isBot`) decides the rest: in a 1:1 id the only
    /// bot poster is the mate.
    public static func isBotChat(_ chatID: String) -> Bool {
        let id = chatID.trimmingCharacters(in: .whitespaces)
        return id.hasPrefix("28:") || (id.hasPrefix("19:") && id.hasSuffix("@unq.gbl.spaces"))
    }

    /// Known non-text types (`ThreadActivity`, `Control`, …): first
    /// `messagetype` segment outside Text/RichText (history keeps those
    /// two only). Empty/unknown passes — old cores omit the field.
    public static func isSystem(_ message: RealtimeMessage) -> Bool {
        let raw = (message.messageType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let head = raw.split(separator: "/").first.map(String.init) ?? raw
        return head.caseInsensitiveCompare("Text") != .orderedSame
            && head.caseInsensitiveCompare("RichText") != .orderedSame
    }

    /// True when raw HTML carries an `<img` tag (case-insensitive open).
    /// Mirrors history's keep rule so photo messages still surface.
    public static func hasImageHTML(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.range(of: "<img", options: .caseInsensitive) != nil
    }

    /// Human lines of a meeting-thread text: non-blank lines minus card
    /// chrome, joined to one preview line. Single lines pass through
    /// untouched; nil when nothing human remains (caller keeps the row,
    /// so the preview stays the last user text).
    public static func humanLines(_ text: String) -> String? {
        let lines = contentLines(text)
        guard !lines.isEmpty else { return nil }
        guard lines.count > 1 else { return lines[0] }
        let kept = lines.filter { !isChromeLine($0) }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: " ")
    }

    /// Meeting card with human content: ≥1 chrome line and ≥1 human line.
    /// Single-line texts (even bracketed pastes) are user text, not cards.
    static func isMixedCard(_ text: String) -> Bool {
        let lines = contentLines(text)
        guard lines.count > 1 else { return false }
        return lines.contains(where: isChromeLine)
            && lines.contains(where: { !isChromeLine($0) })
    }

    /// Card-chrome line: opens with a JSON bracket or quote. Conservative
    /// (may drop a quoted prose line from a meeting preview); the full
    /// text stays in the thread.
    static func isChromeLine(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        return "{}[]\"".contains(first)
    }

    /// Non-blank trimmed lines (newline split).
    static func contentLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
