// RecapsSection.swift — Recaps native app provider (UI-SPEC §6.7).
//
// List: meeting recordings + transcripts merged per meeting, plus the
// meeting chats (RECAP2: a meeting recorded by someone else keeps its
// files in the organizer's OneDrive, so its chat is how it is found),
// filterable. Detail: the unified recap viewer (MeetingRecapView, the
// same one the chat Recap tab and Calendar use). Inspector: details,
// on-device Action Items, Save, Open in Browser.
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class RecapsSection: SectionProvider, InspectorCapable {
    let section: SectionID = .native(.recaps)
    let title = NativeAppID.recaps.title
    let hasInspector = true

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let app = m.app, let id = Self.recapID(m) else { return "" }
        return Self.row(id, in: Self.rows(app))?.title ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(RecapsListState.emptyTitle, systemImage: NativeAppID.recaps.symbol,
                                     message: RecapsListState.emptyMessage))
        }
        return AnyView(RecapsListPane(recordings: app.recordings, transcripts: app.transcripts, chats: app.chats))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane(RecapDetailState.noSelectionTitle)) }
        return AnyView(RecapDetailPane(recordings: app.recordings, transcripts: app.transcripts, chats: app.chats,
                                       store: app.meetingRecaps))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(RecapInspector(recordings: app.recordings, transcripts: app.transcripts,
                                      actionItems: app.transcripts.actionItems, chats: app.chats,
                                      store: app.meetingRecaps))
    }

    /// `app/recaps/<recap>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.dropFirst().first else { return nil }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let app = m.app else { return }
        // The viewer loads the selected recap itself (MeetingRecapView);
        // clearing the selection stops the player.
        if sel == nil, app.recordings.selectedID != nil { app.recordings.closePlayer() }
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

    /// Every Recaps row: drive recaps plus meeting chats (RECAP2).
    static func rows(_ app: AppState) -> [Recap] {
        Recap.withMeetingChats(recaps(app.recordings, app.transcripts), chats: app.chats.chats)
    }

    /// The viewer model for a row: the meeting chat's recap (drive files
    /// as its fallback), or the drive files alone.
    static func model(for recap: Recap, _ store: MeetingRecapStore) -> MeetingRecapViewModel {
        if let thread = recap.threadID {
            return store.model(threadID: thread, title: recap.title)
        }
        return store.model(fileRecording: recap.recording, fileTranscript: recap.transcript, title: recap.title)
    }

    /// The row a route id names: a row id, else a meeting chat's thread id
    /// (`app/recaps/<chat>` opens the recap its chat matched). Pure.
    static func row(_ id: String, in rows: [Recap]) -> Recap? {
        rows.first { $0.id == id } ?? rows.first { $0.threadID == id }
    }

    /// The recap on screen.
    static func current(_ m: WindowModel) -> Recap? {
        guard let app = m.app, let id = recapID(m) else { return nil }
        return row(id, in: rows(app))
    }
}
