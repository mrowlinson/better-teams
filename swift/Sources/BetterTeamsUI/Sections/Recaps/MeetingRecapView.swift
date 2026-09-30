// MeetingRecapView.swift — RECAP2: the one recap viewer, used by the
// meeting chat's Recap tab, the Recaps app and the Calendar Recap button.
//
// Player (AVPlayerView over the shared recordings player: AVKit, hardware
// decode) above three parts: Transcript (speaker, time, search; a click
// seeks, the line under the playhead highlights), Notes (the Loop page's
// content, read-only; the page itself opens in the window) and Recap (intelligent recap when licensed). Each part
// shows its own state; a failed read is an error with Try Again, never
// "none" (MeetingRecapViewModel).
import AVKit
import OstMacCore
import SwiftUI

enum MeetingRecapTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case notes = "Notes"
    case recap = "Recap"
    var id: String { rawValue }
    /// Segment title. Distinct from the chat's own Notes and Recap tabs,
    /// which sit right above the viewer in a meeting chat.
    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .notes: "Meeting Notes"
        case .recap: "AI Recap"
        }
    }
    /// Evidence routes (`?recapTab=notes|recap`, demo only) open the
    /// viewer on that tab; nil = Transcript.
    static var evidenceInitial: MeetingRecapTab?
}

struct MeetingRecapView: View {
    @ObservedObject var recap: MeetingRecapViewModel
    @ObservedObject var recordings: RecordingsViewModel
    @State private var tab: MeetingRecapTab = MeetingRecapTab.evidenceInitial ?? .transcript
    @State private var query = ""
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(spacing: 0) {
            player
            bar
            Divider()
            Group {
                switch tab {
                case .transcript: transcriptPart
                case .notes: notesPart
                case .recap: recapPart
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { recap.load() }
    }

    // MARK: player

    @ViewBuilder
    private var player: some View {
        switch recap.recording {
        case .loaded(let item):
            playerView(item)
                .task(id: item.id) {
                    if recordings.selectedID != item.id || recordings.playback == .idle {
                        recordings.play(item, autoplay: false)
                    }
                }
            Divider()
        case .loading:
            // The no-recording line's height: nothing jumps when the
            // meeting turns out to have no recording.
            LoadingPane(rows: false)
                .frame(maxWidth: .infinity).frame(height: 36)
                .accessibilityLabel("Loading Recording")
            Divider()
        case .failed(let message):
            EmptyPane(RecapDetailState.playerErrorTitle, systemImage: "exclamationmark.triangle", message: message) {
                Button("Try Again") { recap.retry() }
            }
            .frame(maxWidth: .infinity).frame(height: 200)
            Divider()
        case .absent(let reason):
            // No recording: one quiet line, the transcript keeps the room.
            Label(reason, systemImage: "video.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier("recap.noRecording")
            Divider()
        }
    }

    @ViewBuilder
    private func playerView(_ item: RecordingItem) -> some View {
        Group {
            if recordings.selectedID == item.id, let p = recordings.player {
                RecapPlayerView(player: p)
            } else if recordings.selectedID == item.id, case .failed(let message) = recordings.playback {
                EmptyPane(RecapDetailState.playerErrorTitle, systemImage: "exclamationmark.triangle",
                          message: message) {
                    Button("Try Again") { recordings.play(item, autoplay: false) }
                }
            } else {
                LoadingPane("Loading Recording\u{2026}", rows: false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 360)
        .background(.black)
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 8) {
            Picker("Recap part", selection: $tab) {
                ForEach(MeetingRecapTab.allCases) { t in Text(t.title).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if tab == .transcript, recap.transcript.value != nil {
                SearchField(text: $query, placeholder: "Search Transcript")
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Search Transcript")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: transcript

    @ViewBuilder
    private var transcriptPart: some View {
        switch recap.transcript {
        case .loading: LoadingPane("Loading Transcript\u{2026}", rows: false)
        case .failed(let message):
            ErrorPane(title: RecapDetailState.transcriptErrorTitle, message: message) { recap.retry() }
        case .absent(let reason):
            EmptyPane(RecapDetailState.noTranscriptTitle, systemImage: "doc.text", message: reason) {}
        case .loaded(let cues):
            transcriptList(cues)
        }
    }

    @ViewBuilder
    private func transcriptList(_ cues: [TranscriptCue]) -> some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = Set(TranscriptSearch.matches(cues, query: q))
        let rows = q.isEmpty ? cues : cues.filter { hits.contains($0.id) }
        let playing = recap.recording.value.map { recordings.selectedID == $0.id } ?? false
        let current = playing ? TranscriptPlayhead.currentCueID(cues, at: recordings.playheadMs) : nil
        let seekable = playing && recordings.player != nil
        if rows.isEmpty {
            EmptyPane("No Results", systemImage: "magnifyingglass",
                      message: "Nothing in the transcript matches \u{201C}\(q)\u{201D}.") {}
        } else {
            VStack(spacing: 0) {
                if !q.isEmpty {
                    Text(rows.count == 1 ? "1 line" : "\(rows.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("recap.searchCount")
                }
                ScrollViewReader { proxy in
                    List(rows) { cue in
                        TranscriptTurnRow(cue: cue, seekable: seekable, isCurrent: cue.id == current) {
                            seek(to: cue)
                        }
                        .listRowBackground(cue.id == current
                            ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.15)).padding(.horizontal, 4)
                            : nil)
                    }
                    .listStyle(.inset)
                    // Follow the line under the playhead (moves only while
                    // playing or on a seek).
                    .onChange(of: current) { _, id in
                        guard let id, q.isEmpty else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func seek(to cue: TranscriptCue) {
        guard let p = recordings.player else { return }
        p.seek(to: CMTime(value: CMTimeValue(cue.startMs), timescale: 1000),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: notes

    @ViewBuilder
    private var notesPart: some View {
        switch recap.notes {
        case .loading: LoadingPane("Loading Notes\u{2026}", rows: false)
        case .failed(let message):
            EmptyPane("Couldn\u{2019}t Load Notes", systemImage: "exclamationmark.triangle", message: message) {
                Button("Try Again") { recap.retry() }
                if let url = recap.notesURL { Button("Open Notes") { openNotes(url, title: "Meeting notes") } }
            }
        case .absent(let reason):
            EmptyPane("No Meeting Notes", systemImage: "note.text", message: reason) {}
        case .loaded(let notes):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(notes.title, systemImage: "note.text")
                        .font(.headline)
                    Spacer()
                    Button("Open in Loop") { openNotes(notes.webURL, title: notes.title) }
                        .help("Opens the Loop page in this window")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if notes.text?.isEmpty == true {
                    EmptyPane("No Text in These Notes", systemImage: "note.text",
                              message: "These notes have no text to show here. Open them in Loop to see everything.") {
                        Button("Open in Loop") { openNotes(notes.webURL, title: notes.title) }
                    }
                } else if let text = notes.text {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    EmptyPane("Notes Open in the Window", systemImage: "note.text",
                              message: "These notes are a Loop page. Open them to read them here.") {
                        Button("Open Notes") { openNotes(notes.webURL, title: notes.title) }
                    }
                }
            }
        }
    }

    private func openNotes(_ url: URL, title: String) {
        guard let m = model, let app = m.frameHost.library.page(name: title, webURL: url) else { return }
        m.navigator?.select(section: .web(app.id))
    }

    // MARK: recap

    /// Row ids unique across the list's sections: offset ids alone collide
    /// (both sections' rows are 0, 1, …), and SwiftUI then shows the first
    /// section's rows in the second.
    static func rows(_ texts: [String], _ section: String) -> [(id: String, text: String)] {
        texts.enumerated().map { ("\(section)-\($0.offset)", $0.element) }
    }

    @ViewBuilder
    private var recapPart: some View {
        switch recap.aiRecap {
        case .loading: LoadingPane("Loading Recap\u{2026}", rows: false)
        case .failed(let message):
            ErrorPane(title: "Couldn\u{2019}t Load Recap", message: message) { recap.retry() }
        case .absent(let reason):
            EmptyPane("No AI Recap", systemImage: "sparkles", message: reason) {}
        case .loaded(let ai):
            List {
                if !ai.notes.isEmpty {
                    Section("Meeting Notes") {
                        ForEach(Self.rows(ai.notes, "note"), id: \.id) { r in Text(r.text).textSelection(.enabled) }
                    }
                }
                if !ai.followUps.isEmpty {
                    Section("Follow-up Tasks") {
                        ForEach(Self.rows(ai.followUps, "task"), id: \.id) { r in
                            Label(r.text, systemImage: "checkmark.circle").textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
