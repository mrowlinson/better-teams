// RecapsSection.swift — Recaps native app provider (UI-SPEC §6.7).
//
// List: meeting recordings + transcripts merged per meeting, filterable.
// Detail: the recording's player (AVPlayerView, AppKit island) above the
// transcript turns; clicking a turn seeks. Inspector: on-device Action
// Items, Save, Open in Browser. Selection opens the recap (R24); a
// selection that arrives before the lists load opens once they land.
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class RecapsSection: SectionProvider, InspectorCapable {
    let section: SectionID = .native(.recaps)
    let title = NativeAppID.recaps.title
    let hasInspector = true

    /// Selected recap id waiting for the lists (route at launch).
    private var pendingID: String?
    private var listsChange: AnyCancellable?

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let app = m.app, let id = Self.recapID(m) else { return "" }
        return Self.recaps(app.recordings, app.transcripts).first { $0.id == id }?.title ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(RecapsListState.emptyTitle, systemImage: NativeAppID.recaps.symbol,
                                     message: RecapsListState.emptyMessage))
        }
        return AnyView(RecapsListPane(recordings: app.recordings, transcripts: app.transcripts))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane(RecapDetailState.noSelectionTitle)) }
        return AnyView(RecapDetailPane(recordings: app.recordings, transcripts: app.transcripts))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(RecapInspector(recordings: app.recordings, transcripts: app.transcripts,
                                      actionItems: app.transcripts.actionItems))
    }

    /// `app/recaps/<recap>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.dropFirst().first else { return nil }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let app = m.app else { return }
        pendingID = sel?.path.first
        Self.open(pendingID, app.recordings, app.transcripts)
        if listsChange == nil {
            // @Published fires before the value lands: hop once, then read.
            listsChange = app.recordings.$items.map { _ in () }
                .merge(with: app.transcripts.$items.map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak recordings = app.recordings, weak transcripts = app.transcripts] _ in
                    guard let self, let recordings, let transcripts, self.pendingID != nil else { return }
                    Self.open(self.pendingID, recordings, transcripts)
                }
        }
    }

    // MARK: shared helpers

    static func recapID(_ m: WindowModel) -> String? {
        m.nav.selection(in: .native(.recaps))?.path.first
    }

    static func recaps(_ recordings: RecordingsViewModel, _ transcripts: TranscriptsViewModel) -> [Recap] {
        Recap.merge(recordings: recordings.items, transcripts: transcripts.items)
    }

    static func select(_ id: String?, _ m: WindowModel) {
        guard recapID(m) != id else { return }
        m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .native(.recaps))
    }

    /// Load the recap's player (paused) and transcript turns. Idempotent:
    /// what is already open stays (no reload, no restart). Nil or an
    /// unknown id closes both.
    static func open(_ id: String?, _ recordings: RecordingsViewModel, _ transcripts: TranscriptsViewModel) {
        guard let id, let recap = recaps(recordings, transcripts).first(where: { $0.id == id }) else {
            if id == nil {
                if recordings.selectedID != nil { recordings.closePlayer() }
                if transcripts.selectedID != nil { transcripts.closeTranscript() }
            }
            return
        }
        if let r = recap.recording {
            if recordings.selectedID != r.id || recordings.playback == .idle {
                recordings.play(r, autoplay: false)
            }
        } else if recordings.selectedID != nil {
            recordings.closePlayer()
        }
        if let t = recap.transcript {
            if transcripts.selectedID != t.id { transcripts.select(t) }
        } else if transcripts.selectedID != nil {
            transcripts.closeTranscript()
        }
    }

    /// The recap on screen, when both stores show it.
    static func current(_ m: WindowModel) -> Recap? {
        guard let app = m.app, let id = recapID(m) else { return nil }
        return recaps(app.recordings, app.transcripts).first { $0.id == id }
    }
}
