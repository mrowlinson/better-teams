// MeetingPopOutStore.swift — gap-g8: per-meeting pop-out registry.
//
// E1-POPOUT contract mirrored for meetings (the Meeting window is a
// single slot; this registry gives every meeting its own window):
// one key = max one pop-out window; re-pop focuses (pop returns
// false); live chat + roster events fan out to popped meetings; close
// loses no state (chat + roster stores and the display name stay
// cached — re-pop restores with no reload).
//
// Keys are opaque meeting ids: a live thread id
// (`19:meeting_*@thread.v2`, popped from the Meeting window) or a
// calendar meeting id (popped from an upcoming row, pre-thread — the
// chat store adopts its thread on first sight, same as the main
// panel). Fan-in matches the store's adopted thread id OR the key
// itself, so both key shapes take live updates without cross-talk.
//
//   let pops = MeetingPopOutStore()
//   if pops.pop(key: id, subject: name) { openWindow(value: MeetingPopoutValue(key: id)) }
//   pops.ingest(realtime: msg) // fan-out beside meetingChat
//   pops.ingest(roster: ev) // fan-out beside meeting
//   pops.close(key: id) // red dot: visible drops, stores stay
import Combine
import Foundation

/// Value-driven window value for one popped meeting. A distinct type
/// (not String) so `openWindow(value:)` routes to the meeting scene
/// even though the chat + account scenes share `String.self`.
public struct MeetingPopoutValue: Codable, Hashable, Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Popped-meeting registry + per-meeting stores + name cache.
@MainActor
public final class MeetingPopOutStore: ObservableObject {
    /// Currently visible pop-outs (one key per window).
    @Published public private(set) var poppedKeys: Set<String> = []
    /// Session chat cache (key → store). Plain (never @Published):
    /// resolved during window-body eval, must not republish mid-render.
    public private(set) var chatStores: [String: MeetingChatStore] = [:]
    /// Session roster cache (key → store). Same plain rule.
    public private(set) var rosterStores: [String: MeetingRosterStore] = [:]
    /// Display-name cache (subject at pop time; close-proof).
    private var names: [String: String] = [:]
    /// Per-meeting draft cache (continuous save, close-proof).
    private var drafts: [String: String] = [:]
    private let makeChat: () -> MeetingChatStore
    private let makeRoster: () -> MeetingRosterStore

    public init(
        makeChat: @escaping () -> MeetingChatStore = { MeetingChatStore() },
        makeRoster: @escaping () -> MeetingRosterStore = { MeetingRosterStore() }
    ) {
        self.makeChat = makeChat
        self.makeRoster = makeRoster
    }

    /// Pop a meeting: true when newly popped, false when already popped
    /// (caller focuses the existing window) or the key is blank. The
    /// subject seeds the name cache (blank subjects keep any earlier
    /// name; the window title falls back to the key).
    @discardableResult
    public func pop(key: String, subject: String? = nil) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !poppedKeys.contains(k) else { return false }
        _ = chatStore(for: k) // window content exists before it renders
        _ = rosterStore(for: k)
        if let s = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty
        {
            names[k] = s
        }
        poppedKeys.insert(k)
        return true
    }

    /// True while the meeting has a visible pop-out window.
    public func isPopped(key: String) -> Bool {
        poppedKeys.contains(key)
    }

    /// Window closed (red dot): the key leaves the visible set while
    /// its stores and name stay cached for the session — re-pop
    /// restores both with no reload.
    public func close(key: String) {
        poppedKeys.remove(key)
    }

    /// Cached chat store for a key, created on demand.
    public func chatStore(for key: String) -> MeetingChatStore {
        if let s = chatStores[key] { return s }
        let s = makeChat()
        chatStores[key] = s
        return s
    }

    /// Cached roster store for a key, created on demand.
    public func rosterStore(for key: String) -> MeetingRosterStore {
        if let s = rosterStores[key] { return s }
        let s = makeRoster()
        rosterStores[key] = s
        return s
    }

    /// Display name for a key: pop-time subject, else the store's
    /// header title, else the key itself (missing-from-list precedent).
    public func name(for key: String) -> String {
        if let n = names[key] { return n }
        if let s = chatStores[key], s.threadID != nil { return s.headerTitle }
        return key
    }

    /// Cached draft for a key ("" when none).
    public func draft(for key: String) -> String {
        drafts[key] ?? ""
    }

    /// Continuous draft save (blank keys are a no-op).
    public func saveDraft(_ text: String, for key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        drafts[k] = text
    }

    /// Drop a cached draft (unknown keys are a no-op).
    public func purgeDraft(for key: String) {
        drafts.removeValue(forKey: key)
    }

    /// Live-event fan-out: routes to every popped meeting whose key or
    /// adopted thread id matches. True when at least one visible
    /// pop-out consumed the event (caller refreshes Seen state).
    /// Pre-thread (calendar-id) keys adopt their thread on first
    /// sight via `ingestIfMeeting` — but only when the key itself is
    /// NOT already a *different* meeting thread (a popped thread
    /// never adopts another thread's traffic), and only ONE adopter
    /// per event (sorted-first, deterministic): without a
    /// calendar→thread map the thread is unattributable, so a second
    /// unclaimed key stays empty rather than mirroring the wrong
    /// meeting.
    @discardableResult
    public func ingest(realtime message: RealtimeMessage) -> Bool {
        var consumed = false
        var adopted = false
        for key in poppedKeys.sorted() {
            guard let s = chatStores[key] else { continue }
            if key == message.chatID || s.threadID == message.chatID {
                // Unclaimed stores only take meeting threads
                // (ingestIfMeeting would no-op anything else — don't
                // report those as consumed).
                guard s.threadID != nil
                    || MeetingSignal.isMeetingThread(message.chatID)
                else { continue }
                s.ingestIfMeeting(realtime: message)
                consumed = true
            } else if !adopted,
                      s.threadID == nil,
                      !MeetingSignal.isMeetingThread(key),
                      MeetingSignal.isMeetingThread(message.chatID)
            {
                s.ingestIfMeeting(realtime: message)
                consumed = true
                adopted = true
            }
        }
        return consumed
    }

    /// Roster fan-out: routes to every popped meeting whose key or
    /// adopted meeting id matches. Unattributed frames (empty
    /// meeting id) stay main-window-only (no cross-talk).
    @discardableResult
    public func ingest(roster event: MeetingRosterEvent) -> Bool {
        guard !event.meetingID.isEmpty else { return false }
        var consumed = false
        for key in poppedKeys {
            guard let s = rosterStores[key] else { continue }
            if key == event.meetingID || s.meetingID == event.meetingID {
                s.ingest(event)
                consumed = true
            }
        }
        return consumed
    }
}
