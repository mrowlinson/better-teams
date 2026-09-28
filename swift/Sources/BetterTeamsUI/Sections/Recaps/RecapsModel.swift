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

    var source: String? { recording?.source ?? transcript?.source }
    var webURL: String? { recording?.web_url ?? transcript?.web_url }

    /// "Recording and Transcript", "Recording", "Transcript".
    var kind: String {
        switch (recording != nil, transcript != nil) {
        case (true, true): "Recording and Transcript"
        case (true, false): "Recording"
        default: "Transcript"
        }
    }

    var symbol: String { recording != nil ? "film" : "doc.text" }

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
                        forced: ForcedPaneState?, offline: Bool) -> RecapsListState {
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
        if recordings == .loading || transcripts == .loading { return .loading }
        if case .error(let m) = recordings { return failed(m) }
        if case .error(let m) = transcripts { return failed(m) }
        return .empty
    }
}
