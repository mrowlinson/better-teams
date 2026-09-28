// CallInspector.swift — the call's People | Chat inspector (UI-SPEC
// §8), shared by both hosts: the main window's inspector column and
// the call window's inspector split item. The segment lives in
// `WindowModel.inspectorSegment` (route `inspector=people|chat`).
import OstMacCore
import SwiftUI

struct CallInspector: View {
    let session: CallSession
    @Environment(\.windowModel) private var model

    var body: some View {
        if let app = session.model?.app {
            content(app)
        } else {
            EmptyPane("No Call", systemImage: "phone")
        }
    }

    private func content(_ app: AppState) -> some View {
        VStack(spacing: 0) {
            Picker("Show", selection: Binding(get: { model?.inspectorSegment == "chat" ? "chat" : "people" },
                                              set: { model?.setInspectorSegment($0) })) {
                Text("People").tag("people")
                Text("Chat").tag("chat")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if model?.inspectorSegment == "chat" {
                CallChatList(chat: app.meetingChat, isMeeting: session.isMeeting)
            } else {
                CallPeopleList(session: session, roster: app.meeting)
            }
        }
    }
}

/// People: the stage's tiles as a list (name, speaking, muted).
private struct CallPeopleList: View {
    let session: CallSession
    @ObservedObject var roster: MeetingRosterStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let own = model?.ownDisplayName ?? "You"
        let people = CallTiles.make(
            roster: session.isMeeting ? roster.participants : [], peer: session.peerName, ownName: own,
            isOwn: { p in model?.isOwnID(p.id) == true || p.name == own || p.name == "Me" },
            muted: session.controls.muted, cameraOn: session.controls.cameraOn, sharing: false)
        List {
            Section("In This Call (\(people.count))") {
                ForEach(people) { p in
                    HStack(spacing: 8) {
                        Avatar(name: p.name)
                        Text(p.kind == .selfView ? "\(p.name) (You)" : p.name)
                            .font(AppFont.body(scale))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if p.speaking {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Speaking")
                        }
                        if p.muted {
                            Image(systemName: "mic.slash.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Muted")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// Chat: the meeting chat thread (read + send); person calls have no
/// meeting chat (their chat stays in Chat).
private struct CallChatList: View {
    @ObservedObject var chat: MeetingChatStore
    let isMeeting: Bool
    @State private var draft = ""
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if !isMeeting || chat.threadID == nil {
            EmptyPane("No Meeting Chat", systemImage: "bubble.left.and.bubble.right",
                      message: "This call has no meeting chat.")
        } else {
            VStack(spacing: 0) {
                if chat.messages.isEmpty {
                    EmptyPane("No Messages", systemImage: "bubble.left.and.bubble.right")
                } else {
                    List(chat.messages) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.isOwn ? "You" : m.sender)
                                .font(AppFont.bodyEmphasized(scale))
                            Text(m.content)
                                .font(AppFont.body(scale))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Divider()
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                    .onSubmit {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        chat.send(text: t)
                        draft = ""
                    }
            }
        }
    }
}
