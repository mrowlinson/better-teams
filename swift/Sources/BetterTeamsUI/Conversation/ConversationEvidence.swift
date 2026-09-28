// ConversationEvidence.swift — demo-only evidence states for the
// conversation (UI-SPEC §11.3 `state=`-style modifiers, P2a):
//
//   chat/<id>?conv=error|loading
//   chat/<id>?seed=reply,edit,attach,typing,pending,scheduled,delete,pins
//   chat/<id>?jump=pinned            (after seed=pins: jump to the first pin)
//
// A route chat the demo list doesn't have (e.g. `demo-new`) joins the
// list as a new 1:1 chat with no messages, so empty and error states
// show a real name and a selected row.
//
// Honored only with `--demo`. Nothing here touches persisted user data:
// scheduled items go to the demo queue (`ConversationServices`), never
// the real `scheduled.json`, and ghost/translation settings are left
// alone.
import AppKit
import OstMacCore

@MainActor
enum ConversationEvidence {
    /// Applies the route's evidence seeds after a demo chat opened.
    static let newChatName = "Piper Shaw"
    private static let pinsKey = "evidence.pinnedMessages"

    private static func route(_ m: WindowModel, chatID: String?) -> Route? {
        guard m.options.demo, let raw = m.options.route, let route = Route(string: raw),
              route.head == "chat", let id = route.tail.first, chatID == nil || chatID == id else { return nil }
        return route
    }

    private static func seedError(_ m: WindowModel) {
        m.graph.conv.seedDemoError(m.connection == .offline
            ? "Showing saved content." : "The server didn't respond. Check your connection and try again.")
    }

    /// After startup (the list loaded and the demo chat re-opened, which
    /// clears a seeded error): list row, error, and pinned jump.
    static func afterStartup(_ m: WindowModel) {
        guard let route = route(m, chatID: nil), let id = route.tail.first else { return }
        let conv = m.graph.conv
        if m.graph.chats.chat(id: id) == nil, DemoData.messages(for: id).isEmpty {
            m.graph.chats.insertLocally(ChatItem(chatId: id, name: newChatName))
            // A new 1:1 knows the person's status like any other (header
            // subtitle, list badge).
            m.app?.presence.adoptChatPeer(chatID: id, response: UserPresenceResponse(
                ok: true, id: "demo-u-piper", availability: "Available", activity: "Available"))
        }
        if route.query["conv"] == "error", conv.chatID == id, conv.error == nil { seedError(m) }
        if route.query["jump"] == "pinned",
           let pin = m.graph.pinnedMessages.rows(for: id, messages: conv.messages).first(where: \.isAvailable) {
            conv.seek(messageID: pin.messageID)
        }
    }

    static func seed(_ m: WindowModel, chatID: String) {
        guard let route = route(m, chatID: chatID) else { return }
        let conv = m.graph.conv
        let services = ConversationServices.of(m)
        switch route.query["conv"] {
        case "error": seedError(m)
        case "loading":
            conv.close()
        default: break
        }
        let seeds = Set((route.query["seed"] ?? "").split(separator: ",").map(String.init))
        guard !seeds.isEmpty else { return }
        let others = conv.messages.filter { !$0.isOwn && !$0.deleted }
        let own = conv.messages.filter { $0.isOwn && !$0.deleted && !conv.failedIDs.contains($0.id) }
        if seeds.contains("pending") {
            conv.ingest(ChatMessage(id: "pending-evidence", sender: "Me", timestamp: Date().ISO8601Format(),
                                    content: "Uploading the review deck now…", isOwn: true),
                        keepOwnership: true)
        }
        if seeds.contains("reply"), let target = others.last { conv.beginReply(to: target) }
        if seeds.contains("edit"), let target = own.last { services.composer.beginEdit(target, chatID: chatID) }
        if seeds.contains("attach") { services.attachments.stage(paths: demoFiles()) }
        if seeds.contains("typing"), let typing = m.app?.typing {
            typing.timeout = 3600
            let json = #"{"chat_id":"\#(chatID)","sender":"Megan Harper","time":"\#(Date().ISO8601Format())"}"#
            if let ev = try? JSONDecoder().decode(TypingEvent.self, from: Data(json.utf8)) { typing.ingest(ev) }
        }
        if seeds.contains("scheduled"), let q = services.scheduled(m) {
            let name = m.graph.chats.chat(id: chatID)?.name ?? "Conversation"
            q.enqueue(chatID: chatID, chatName: name, text: "Reminder: design review moves to 10 AM.",
                      fireAt: ScheduledPresets.tomorrow9AM())
            q.enqueue(chatID: chatID, chatName: name, text: "Weekly status: the review deck is ready for comments.",
                      fireAt: ScheduledPresets.tonight8PM(now: Date().addingTimeInterval(86_400)))
        }
        if seeds.contains("pins"), let app = m.app {
            // Evidence-only pin store (its own key, reset per run, in the
            // demo's in-memory defaults), so captures never pin anything
            // in the demo account's pins or write a real key.
            app.storageDefaults.removeObject(forKey: pinsKey)
            let store = PinnedMessageStore(defaults: app.storageDefaults, key: pinsKey)
            let start = Date().addingTimeInterval(-600)
            for (i, target) in others.prefix(2).enumerated() {
                store.pin(chatID: chatID, message: target, at: start.addingTimeInterval(Double(i) * 60))
            }
            app.pinnedMessages = store
        }
        if seeds.contains("delete"), let target = own.last {
            // Next turn: the window is on screen by then (the route is
            // applied before the window is first shown).
            DispatchQueue.main.async {
                TimelineActions.confirmDelete(target, conv: conv, model: m, services: services)
            }
        }
    }

    /// Two small demo files in the app's temporary directory.
    private static func demoFiles() -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeams-Demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return [("Q3 Roadmap.pdf", 182_400), ("Review Notes.txt", 2_300)].map { name, size in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data(count: size).write(to: url)
            }
            return url.path
        }
    }
}
