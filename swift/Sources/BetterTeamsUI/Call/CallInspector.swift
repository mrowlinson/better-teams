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
                            .contactHover(name: p.name, arrowEdge: .leading)
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
struct CallChatList: View {
    @ObservedObject var chat: MeetingChatStore
    let isMeeting: Bool
    @State private var draft = ""
    @State private var atBottom = true
    @Environment(\.contentTextScale) private var scale

    /// Within this many points of the end counts as "at the newest message".
    static let bottomSlack: CGFloat = 24

    /// True when the scroll position is at (within slack of) the newest message.
    static func isAtNewest(offsetY: CGFloat, containerHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        offsetY + containerHeight >= contentHeight - bottomSlack
    }

    /// A new message scrolls the list only while at the end, or when it is yours.
    static func followsNewMessage(atNewest: Bool, lastIsOwn: Bool) -> Bool { atNewest || lastIsOwn }

    var body: some View {
        if !isMeeting || chat.threadID == nil {
            EmptyPane("No Meeting Chat", systemImage: "bubble.left.and.bubble.right",
                      message: "This call has no meeting chat.")
        } else {
            VStack(spacing: 0) {
                if chat.messages.isEmpty {
                    EmptyPane("No Messages", systemImage: "bubble.left.and.bubble.right")
                } else {
                    ScrollViewReader { proxy in
                        List(chat.messages) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.isOwn ? "You" : m.sender)
                                    .font(AppFont.bodyEmphasized(scale))
                                Text(m.content)
                                    .font(AppFont.body(scale))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                            .id(m.id)
                        }
                        .onScrollGeometryChange(for: Bool.self) { g in
                            Self.isAtNewest(offsetY: g.contentOffset.y, containerHeight: g.containerSize.height, contentHeight: g.contentSize.height)
                        } action: { _, now in atBottom = now }
                        // Opens at the newest message; a new one follows only
                        // while you are at the end (or when it is yours).
                        .onAppear { scrollToNewest(proxy) }
                        .onChange(of: chat.messages.last?.id) {
                            if Self.followsNewMessage(atNewest: atBottom, lastIsOwn: chat.messages.last?.isOwn == true) { scrollToNewest(proxy) }
                        }
                        .overlay(alignment: .bottom) {
                            if !atBottom {
                                Button("Jump to Latest", systemImage: "chevron.down") { scrollToNewest(proxy) }
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .padding(.bottom, 8)
                            }
                        }
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

extension CallChatList {
    fileprivate func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let id = chat.messages.last?.id else { return }
        // After layout: the first pass has no row heights yet.
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
    }
}
