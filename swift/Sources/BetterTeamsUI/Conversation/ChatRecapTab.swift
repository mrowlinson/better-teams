// ChatRecapTab.swift — a meeting chat's Recap tab: the meeting's
// recording, transcript and action items, native (the Recaps views on
// the recap matched by meeting title, ChatRecapMatch). The placeholder
// shows only when no recording or transcript exists for the meeting.
import OstMacCore
import SwiftUI

struct ChatRecapTab: View {
    let chatID: String
    let chatName: String
    @ObservedObject var recordings: RecordingsViewModel
    @ObservedObject var transcripts: TranscriptsViewModel

    var body: some View {
        let recaps = RecapsSection.recaps(recordings, transcripts)
        if let recap = ChatRecapMatch.recap(forChatNamed: chatName, in: recaps) {
            HStack(spacing: 0) {
                RecapDetailPane(recordings: recordings, transcripts: transcripts, pinned: recap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                RecapInspector(recordings: recordings, transcripts: transcripts,
                               actionItems: transcripts.actionItems, pinned: recap)
                    .frame(width: 280)
            }
        } else if recaps.isEmpty && (recordings.state == .loading || transcripts.state == .loading) {
            LoadingPane("Loading Recap\u{2026}", rows: false)
        } else {
            ChatTabPlaceholder(title: "No Recap", symbol: ChatTabLayout.symbol(.recap),
                               message: "This meeting has no recording or transcript yet.")
        }
    }
}
