// NotesTab.swift — cross-lane seam (UI-SPEC §6.2, §6.7, §11.3). Final
// signature. A chat's or a channel's Notes tab: the OneNote page list,
// the page, and the Append field, over the account's Notes store, which
// opens with the conversation (R24: no fetch here). Channels read the
// team notebook, chats the user's own OneNote.
import OstMacCore
import SwiftUI

public enum NotesScope: Hashable, Sendable {
    case conversation(ConversationRef)
    case channel(team: String, channel: String)
}

public struct NotesTab: View {
    public let scope: NotesScope
    @Environment(\.windowModel) private var model

    public init(scope: NotesScope) { self.scope = scope }

    public var body: some View {
        if let model, let app = model.app {
            HStack(spacing: 0) {
                NotesPageList(store: app.notes)
                    .frame(width: NotesPageList.width)
                Divider()
                NotesPageView(store: app.notes, forced: nil)
            }
        } else {
            EmptyPane(NotesPaneState.noNotebooksTitle, systemImage: NativeAppID.onenote.symbol,
                      message: NotesStore.noNotebooksBody(groupID: nil))
        }
    }
}
