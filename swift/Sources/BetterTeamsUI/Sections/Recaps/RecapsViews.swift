// RecapsViews.swift — Recaps list, player + transcript detail and
// inspector (UI-SPEC §6.7, §6 row conventions, R18 pane states).
import AVKit
import OstMacCore
import SwiftUI

// MARK: list

/// Recaps newest first, one row per meeting, with a search field at the
/// top of the list (HIG search fields; R23: NSSearchField, not
/// `.searchable`). Typing filters the rows on screen at once, then
/// (250 ms debounce) searches the drives on the server (recordings and
/// transcripts, the transcripts' full-drive fallback included); server
/// hits show unfiltered, as they may match inside the file. Clearing
/// the field restores the lists.
struct RecapsListPane: View {
    @ObservedObject var recordings: RecordingsViewModel
    @ObservedObject var transcripts: TranscriptsViewModel
    @State private var filter = ""
    @State private var debounce = Debounce(milliseconds: 250)
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let all = RecapsSection.recaps(recordings, transcripts)
            let resolved = RecapsListState.resolve(
                recordings: recordings.state, transcripts: transcripts.state, count: all.count,
                forced: model.forced(.native(.recaps)), offline: model.connection == .offline)
            // A search (field text or server hits) keeps the search UI:
            // zero hits read "No Results", never the no-recaps pane.
            let searching = !filter.isEmpty || recordings.isSearchResults || transcripts.isSearchResults
            let state = searching && model.forced(.native(.recaps)) == nil ? .recaps : resolved
            switch state {
            case .loading: LoadingPane("Loading Recaps\u{2026}")
            case .error(let title, let message):
                ErrorPane(title: title, message: message) {
                    recordings.refresh()
                    transcripts.refresh()
                }
            case .empty:
                EmptyPane(RecapsListState.emptyTitle, systemImage: NativeAppID.recaps.symbol,
                          message: RecapsListState.emptyMessage)
            case .recaps:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        SearchField(text: $filter, placeholder: "Search Recaps")
                            .accessibilityLabel("Search Recaps")
                        // Server search runs behind the rows on screen.
                        ProgressView()
                            .controlSize(.small)
                            .opacity(recordings.isSearching || transcripts.isSearching ? 1 : 0)
                            .accessibilityHidden(!(recordings.isSearching || transcripts.isSearching))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    if let error = recordings.searchError ?? transcripts.searchError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                    list(all, model)
                }
                // R12: a list refresh runs behind the rows on screen.
                .refreshStatus(recordings.state == .loading || transcripts.state == .loading,
                               failure: RecapsListState.failure(recordings.state, transcripts.state),
                               label: "Updating Recaps", retry: {
                                   recordings.refresh()
                                   transcripts.refresh()
                               })
                .onChange(of: filter) { _, q in search(q) }
            }
        }
    }

    /// Server search in both stores (a blank query restores the lists).
    private func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        debounce.schedule {
            Task { await recordings.search(query: q) }
            Task { await transcripts.search(query: q) }
        }
    }

    @ViewBuilder
    private func list(_ all: [Recap], _ m: WindowModel) -> some View {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let matched = f.isEmpty ? all : all.filter { r in
            r.matches(f) || (r.recording != nil && recordings.isSearchResults)
                || (r.transcript != nil && transcripts.isSearchResults)
        }
        // Nothing matches locally while the server search runs: the rows
        // on screen stay until its hits land (never a blank list).
        let rows = matched.isEmpty && (recordings.isSearching || transcripts.isSearching) ? all : matched
        if rows.isEmpty {
            EmptyPane("No Results", systemImage: "magnifyingglass",
                      message: f.isEmpty ? "No recaps found." : "No recaps match \u{201C}\(f)\u{201D}.")
        } else {
            let selection = Binding<String?>(
                get: { RecapsSection.recapID(m) },
                set: { RecapsSection.select($0, m) })
            List(rows, selection: selection) { recap in
                RecapRow(recap: recap).tag(recap.id)
            }
            .listStyle(.inset)
        }
    }
}

/// Recap row: kind symbol, meeting title, then kind · duration · source.
struct RecapRow: View {
    let recap: Recap
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: recap.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(recap.title)
                    .font(AppFont.body(scale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([recap.kind, recap.recording?.durationLabel, recap.source]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(AppFont.subheadline(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: detail

enum RecapDetailState {
    static let noSelectionTitle = "No Recap Selected"
    static let noTranscriptTitle = "No Transcript"
    static let noTranscriptMessage = "This meeting has no transcript."
    static let transcriptErrorTitle = "Couldn\u{2019}t Load Transcript"
    static let playerErrorTitle = "Couldn\u{2019}t Load Recording"
}

/// The recording's player above the transcript turns; a turn click
/// seeks the player to the turn's start.
struct RecapDetailPane: View {
    @ObservedObject var recordings: RecordingsViewModel
    @ObservedObject var transcripts: TranscriptsViewModel
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            if model.forced(.native(.recaps)) == nil, let recap = RecapsSection.current(model) {
                VStack(spacing: 0) {
                    if let r = recap.recording {
                        player(r)
                        Divider()
                    }
                    turns(recap)
                }
            } else {
                NoSelectionPane(RecapDetailState.noSelectionTitle)
            }
        }
    }

    @ViewBuilder
    private func player(_ r: RecordingItem) -> some View {
        Group {
            if recordings.selectedID == r.id, let p = recordings.player {
                RecapPlayerView(player: p)
            } else if recordings.selectedID == r.id, case .failed(let message) = recordings.playback {
                EmptyPane(RecapDetailState.playerErrorTitle, systemImage: "exclamationmark.triangle",
                          message: message) {
                    Button("Try Again") { recordings.play(r, autoplay: false) }
                }
            } else {
                LoadingPane("Loading Recording\u{2026}", rows: false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 360)
        .background(.black)
    }

    @ViewBuilder
    private func turns(_ recap: Recap) -> some View {
        if let t = recap.transcript {
            if transcripts.selectedID != t.id {
                LoadingPane("Loading Transcript\u{2026}", rows: false)
            } else {
                switch transcripts.content {
                case .idle, .loading: LoadingPane("Loading Transcript\u{2026}", rows: false)
                case .failed(let message):
                    ErrorPane(title: RecapDetailState.transcriptErrorTitle, message: message) {
                        transcripts.select(t)
                    }
                case .loaded:
                    let current = recap.recording != nil && recordings.selectedID == recap.recording?.id
                        ? TranscriptPlayhead.currentCueID(transcripts.cues, at: recordings.playheadMs) : nil
                    ScrollViewReader { proxy in
                        List(transcripts.cues) { cue in
                            TranscriptTurnRow(cue: cue, seekable: recordings.player != nil,
                                              isCurrent: cue.id == current) { seek(to: cue) }
                                .listRowBackground(cue.id == current
                                    ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Palette.messageHighlight).padding(.horizontal, 4)
                                    : nil)
                        }
                        .listStyle(.inset)
                        // Follow the turn under the playhead (it moves only
                        // while playing or on a seek).
                        .onChange(of: current) { _, id in
                            guard let id else { return }
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
        } else {
            EmptyPane(RecapDetailState.noTranscriptTitle, systemImage: "doc.text",
                      message: RecapDetailState.noTranscriptMessage)
        }
    }

    private func seek(to cue: TranscriptCue) {
        guard let p = recordings.player else { return }
        p.seek(to: CMTime(value: CMTimeValue(cue.startMs), timescale: 1000),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// One speaker turn: start time, speaker, text. Clicking seeks when a
/// recording is playing beside it.
struct TranscriptTurnRow: View {
    let cue: TranscriptCue
    let seekable: Bool
    /// The turn under the playhead (highlighted band).
    var isCurrent = false
    let seek: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Button(action: seek) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(cue.startLabel)
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(seekable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    if let speaker = cue.speaker, !speaker.isEmpty {
                        Text(speaker)
                            .font(AppFont.bodyEmphasized(scale))
                    }
                    Text(cue.text)
                        .font(AppFont.body(scale))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!seekable)
        .padding(.vertical, 2)
        .help(seekable ? "Play from \(cue.startLabel)" : "")
        .accessibilityHint(seekable ? "Plays the recording from here" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// AppKit island: the stock inline player with its own transport.
struct RecapPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
    }
}

// MARK: inspector

/// The selected recap (§6.7 inspector): details, on-device Action Items,
/// Save to Downloads, Open in Browser.
struct RecapInspector: View {
    @ObservedObject var recordings: RecordingsViewModel
    @ObservedObject var transcripts: TranscriptsViewModel
    @ObservedObject var actionItems: ActionItemsStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if let model, model.forced(.native(.recaps)) == nil, let recap = RecapsSection.current(model) {
            detail(recap)
        } else {
            NoSelectionPane(RecapDetailState.noSelectionTitle)
        }
    }

    private func detail(_ recap: Recap) -> some View {
        Form {
            Section {
                Text(recap.title)
                    .font(AppFont.title3(scale))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Contains", value: recap.kind)
                if let d = recap.recording?.durationLabel { LabeledContent("Duration", value: d) }
                if let s = recap.source { LabeledContent("Location", value: s) }
            }
            Section("Action Items") { items(recap) }
            Section {
                if let r = recap.recording {
                    Button("Save Recording to Downloads") { recordings.save(r) }
                        .disabled(r.drive_id == nil)
                }
                if let t = recap.transcript {
                    Button("Save Transcript to Downloads") { transcripts.save(t) }
                        .disabled(t.drive_id == nil)
                }
                if let saved = recordings.savedPath ?? transcripts.savedPath {
                    Label("Saved \u{201C}\((saved as NSString).lastPathComponent)\u{201D}",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let error = recordings.actionError ?? transcripts.actionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Button("Open in Browser") {
                    if let r = recap.recording { recordings.open(r) } else if let t = recap.transcript { transcripts.open(t) }
                }
                .disabled(recap.webURL == nil)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func items(_ recap: Recap) -> some View {
        let ready = recap.transcript != nil && transcripts.selectedID == recap.transcript?.id
            && transcripts.content == .loaded
        switch actionItems.state {
        case .idle:
            if recap.transcript == nil {
                Text("Action items come from the meeting transcript.").foregroundStyle(.secondary)
            } else {
                Button("Find Action Items") {
                    Task { await transcripts.extractActionItems() }
                }
                .disabled(!ready)
                .help("Finds action items on this Mac")
            }
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded(let list):
            ForEach(list) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    Text(item.owner).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .empty(let copy):
            Text(copy).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}
