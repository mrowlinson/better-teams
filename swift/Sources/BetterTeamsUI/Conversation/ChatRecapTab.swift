// ChatRecapTab.swift — a meeting chat's Recap tab (RECAP2): the unified
// recap viewer (MeetingRecapView) on this meeting's recap, read from the
// meeting chat the way Teams reads it (the organizer's recording and its
// transcript, the Loop notes, the intelligent recap). Drive files whose
// name matches the meeting (ChatRecapMatch) back it up when the chat
// names none. Each part shows its own state; a failed read is an error
// with Try Again, never "no recording".
import OstMacCore
import SwiftUI

struct ChatRecapTab: View {
    let chatID: String
    let chatName: String
    let store: MeetingRecapStore
    @ObservedObject var recordings: RecordingsViewModel
    @ObservedObject var transcripts: TranscriptsViewModel

    var body: some View {
        let files = ChatRecapMatch.recap(forChatNamed: chatName, in: RecapsSection.recaps(recordings, transcripts))
        let recap = store.model(threadID: chatID, title: chatName)
        MeetingRecapView(recap: recap, recordings: recordings)
            .id(chatID)
            .task(id: (files?.recording?.id ?? "-") + "|" + (files?.transcript?.id ?? "-")) {
                recap.updateFiles(recording: files?.recording, transcript: files?.transcript)
            }
    }
}
