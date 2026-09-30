// RecapsModel.swift — Recaps rows and pane states (UI-SPEC §6.7, R18).
// Pure values: one row per meeting, merging the recording and the
// transcript Teams writes side by side (same file stem).
import Foundation
import OstMacCore

/// One meeting's recap: its recording, its transcript, or both.
struct Recap: Identifiable, Equatable {
    /// Recording id when there is one, else the transcript id (route key).
    let id: String
    let title: String
    let recording: RecordingItem?
    let transcript: TranscriptItem?
    let date: Date?
    /// RECAP2: the meeting chat this recap belongs to (read the way Teams
    /// reads it); nil for drive files with no matched meeting chat.
    var threadID: String? = nil

    var source: String? { recording?.source ?? transcript?.source }
    var webURL: String? { recording?.web_url ?? transcript?.web_url }

    /// "Recording and Transcript", "Recording", "Transcript", or
    /// "Meeting" (a meeting chat, parts read when opened).
    var kind: String {
        switch (recording != nil, transcript != nil) {
        case (true, true): "Recording and Transcript"
        case (true, false): "Recording"
        case (false, true): "Transcript"
        default: "Meeting"
        }
    }

    var symbol: String {
        if recording != nil { return "film" }
        return transcript != nil ? "doc.text" : "person.2.wave.2"
    }

    func matches(_ filter: String) -> Bool {
        filter.isEmpty || title.localizedCaseInsensitiveContains(filter)
            || (source?.localizedCaseInsensitiveContains(filter) ?? false)
    }

    /// Recordings and transcripts merged per meeting (file stem), newest
    /// first; undated rows keep their service order after dated ones.
    static func merge(recordings: [RecordingItem], transcripts: [TranscriptItem]) -> [Recap] {
        var byStem: [String: TranscriptItem] = [:]
        for t in transcripts where byStem[t.stem] == nil { byStem[t.stem] = t }
        var used = Set<String>()
        var out: [Recap] = []
        for r in recordings {
            let stem = TranscriptItem.stem(of: r.name)
            let t = byStem[stem]
            if let t { used.insert(t.id) }
            out.append(Recap(id: r.id, title: r.displayName, recording: r, transcript: t,
                             date: PlannerFormat.dueDate(r.created ?? r.modified)))
        }
        for t in transcripts where !used.contains(t.id) {
            out.append(Recap(id: t.id, title: t.displayName, recording: nil, transcript: t,
                             date: PlannerFormat.dueDate(t.created ?? t.modified)))
        }
        return out.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

extension Recap {
    /// RECAP2: meeting chats join the drive recaps (Recaps app), so a
    /// meeting whose recording and transcript live in the ORGANIZER's
    /// OneDrive (never in the signed-in user's drive lists) is listed
    /// too. A drive recap whose name matches a meeting chat takes the
    /// chat's thread (one row per meeting); other meeting chats active in
    /// the last `days` days add a row each (newest `limit`).
    static func withMeetingChats(_ recaps: [Recap], chats: [ChatItem], now: Date = Date(),
                                 days: Int = 90, limit: Int = 60) -> [Recap] {
        let meetings = chats.filter { ChatKind.of(chatID: $0.chatId, isGroup: $0.is_group) == .meeting }
        guard !meetings.isEmpty else { return recaps }
        var out = recaps
        var claimed = Set<Int>()
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var extra: [Recap] = []
        for chat in meetings {
            let key = ChatRecapMatch.meetingKey(chat.name)
            if !key.isEmpty, let i = out.indices.first(where: { !claimed.contains($0) && out[$0].threadID == nil
                && [out[$0].recording?.name, out[$0].transcript?.name, out[$0].title].compactMap { $0 }
                    .contains { ChatRecapMatch.meetingKey($0) == key } }) {
                out[i].threadID = chat.chatId
                claimed.insert(i)
                continue
            }
            let date = PlannerFormat.dueDate(chat.last_message_time)
            guard let date, date >= cutoff else { continue }
            extra.append(Recap(id: chat.chatId, title: chat.name, recording: nil, transcript: nil,
                               date: date, threadID: chat.chatId))
        }
        extra.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let all = out + extra.prefix(limit)
        return all.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// A meeting chat's recap (chat Recap tab): the newest recap whose
/// meeting title is the chat's name. Teams names the recording and the
/// transcript after the meeting (`<title>-<yyyyMMdd_HHmmss>-Meeting
/// Recording.mp4`), and the meeting chat after the meeting too.
enum ChatRecapMatch {
    static func recap(forChatNamed name: String, in recaps: [Recap]) -> Recap? {
        let want = key(name)
        guard !want.isEmpty else { return nil }
        return recaps.first { r in
            [r.recording?.name, r.transcript?.name, r.title].compactMap { $0 }.contains { meetingKey($0) == want }
        }
    }

    /// The meeting-title part of a recording/transcript file name or a
    /// recap title: extension, ` · date`, and the Teams
    /// `-<date>_<time>-Meeting Recording|Transcript` tail dropped.
    static func meetingKey(_ raw: String) -> String {
        var s = raw
        if let dot = s.range(of: ".", options: .backwards), s[dot.upperBound...].count <= 4 { s = String(s[..<dot.lowerBound]) }
        if let mid = s.range(of: " \u{00B7} ") { s = String(s[..<mid.lowerBound]) }
        if let tail = s.range(of: #"-\d{8}_\d{6}.*$"#, options: .regularExpression) { s = String(s[..<tail.lowerBound]) }
        return key(s)
    }

    private static func key(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

/// What the recaps list shows. Titles state the condition (R18).
enum RecapsListState: Equatable {
    case loading
    case error(title: String, message: String)
    case empty
    case recaps

    static let emptyTitle = "No Recaps"
    static let emptyMessage = "Meeting recordings and transcripts appear here."
    static let errorTitle = "Couldn\u{2019}t Load Recaps"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "Your recaps appear when you\u{2019}re back online."

    /// Either source loading or failing counts only while nothing is
    /// listed (R12: rows on screen stay).
    static func resolve(recordings: RecordingsState, transcripts: TranscriptsState, count: Int,
                        forced: ForcedPaneState?, offline: Bool, chatsLoading: Bool = false,
                        chatsError: String? = nil) -> RecapsListState {
        func failed(_ m: String) -> RecapsListState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        if count > 0 { return .recaps }
        // RECAP2: meeting chats are rows too; "No Recaps" waits for them.
        if recordings == .loading || transcripts == .loading || chatsLoading { return .loading }
        if case .error(let m) = recordings { return failed(m) }
        if case .error(let m) = transcripts { return failed(m) }
        if let m = chatsError { return failed(m) }
        return .empty
    }

    /// A failed list refresh behind the rows on screen (quiet notice).
    static func failure(_ recordings: RecordingsState, _ transcripts: TranscriptsState) -> String? {
        if case .error(let m) = recordings { return m }
        if case .error(let m) = transcripts { return m }
        return nil
    }
}

/// The transcript turn under the playhead (Recaps highlights it).
enum TranscriptPlayhead {
    /// The last turn that started at or before `ms` while `ms` is still
    /// inside it; nil between turns, before the first, or without a
    /// playhead.
    static func currentCueID(_ cues: [TranscriptCue], at ms: Int?) -> Int? {
        guard let ms else { return nil }
        guard let cue = cues.last(where: { $0.startMs <= ms }), ms < cue.endMs else { return nil }
        return cue.id
    }
}
