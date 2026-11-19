// ConversationEvidence.swift — demo-only evidence states for the
// conversation (UI-SPEC §11.3 `state=`-style modifiers, P2a):
//
//   chat/<id>?conv=error|loading|reauth
//   chat/<id>?seed=reply,edit,attach,typing,pending,scheduled,delete,pins,rich,share,praise,poll,loop
//   chat/<id>?seed=deletefail        (own last bubble shows failed delete + Retry)
//   (+ `pollsheet=1` opens the poll create sheet — Composer evidence)
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

    /// AUTH-UX: seeds the expired-session error in its fixed
    /// single-wrap shape (what the core reports after the R2 unwrap:
    /// lowercase display, one "session expired"), so captures show the
    /// clean sign-in prompt instead of raw protocol text.
    private static func seedReauth(_ m: WindowModel) {
        m.graph.conv.seedDemoError(
            "failed(\"messages: stored session expired (refresh token "
            + "rejected: AADSTS70043 ... Trace ID ... Correlation ID ...); "
            + "run `teams-cli login` to sign in again.\")")
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
        if conv.chatID == id, conv.error == nil {
            if route.query["conv"] == "reauth" { seedReauth(m) }
            else if route.query["conv"] == "error" { seedError(m) }
        }
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
        case "reauth": seedReauth(m)
        case "loading":
            conv.close()
        default: break
        }
        // Polls lane: open the create sheet from the route (bound to
        // shared composer state, so it is up on first appear).
        if route.query["pollsheet"] == "1" { services.composer.showPollSheet = true }
        // ADAPTIVE-ACTIONS: ShowCards start expanded for captures.
        if route.query["cards"] == "expanded" { CardDemo.expandShowCards = true }
        let seeds = Set((route.query["seed"] ?? "").split(separator: ",").map(String.init))
        guard !seeds.isEmpty else { return }
        let others = conv.messages.filter { !$0.isOwn && !$0.deleted }
        let own = conv.messages.filter { $0.isOwn && !$0.deleted && !conv.failedIDs.contains($0.id) }
        if seeds.contains("pending") {
            conv.ingest(ChatMessage(id: "pending-evidence", sender: "Me", timestamp: Date().ISO8601Format(),
                                    content: "Uploading the review deck now…", isOwn: true),
                        keepOwnership: true)
        }
        if seeds.contains("poll") {
            // Polls lane: a received poll with one vote cast, so
            // captures show the vote + results card (device-local vote,
            // in memory only like every other seed).
            let poll = PollValidation.make(
                question: "Friday lunch?",
                options: ["Pizza", "Sushi", "Salads"])
            // Register (and vote) before ingest so the first measure
            // and render see the poll, never an empty card.
            PollRegistry.register(poll, messageID: "poll-evidence")
            try? PollRegistry.vote(messageID: "poll-evidence", optionIDs: ["o1"])
            conv.ingest(ChatMessage(id: "poll-evidence", sender: "Megan Harper",
                                    timestamp: Date().ISO8601Format(),
                                    content: PollPayload.fallbackText(poll: poll),
                                    isOwn: false),
                        keepOwnership: true)
        }
        if seeds.contains("rich") {
            // COMPOSER-A: a received message holding the toolbar's
            // markdown, so captures show the emphasis render.
            conv.ingest(ChatMessage(id: "rich-evidence", sender: "Megan Harper",
                                    timestamp: Date().ISO8601Format(),
                                    content: "**Budget** approved, *see notes*\n__Sign here__ and ~~old total~~\n`deploy.sh` at 10",
                                    isOwn: false),
                        keepOwnership: true)
        }
        if seeds.contains("praise") {
            // PRAISE: a received Praise card (badge + note), so captures
            // show the native badge render in the timeline.
            let raw = PraiseCard.envelopeJSON(
                badge: .awesome, recipient: "Jordan Blake",
                note: "Shipped the release a day early — thank you!",
                sender: "Megan Harper", attachmentID: "evidence-praise-1")
            conv.ingest(ChatMessage(id: "praise-evidence", sender: "Megan Harper",
                                    timestamp: Date().ISO8601Format(),
                                    content: "",
                                    isOwn: false, raw: raw),
                        keepOwnership: true)
        }
        if seeds.contains("sticker") {
            // Lane stickers: a received official-shape sticker (demo
            // image URL, so it renders offline) for render captures.
            conv.ingest(ChatMessage(id: "sticker-evidence", sender: "Megan Harper",
                                    timestamp: Date().ISO8601Format(),
                                    content: "",
                                    isOwn: false,
                                    raw: "<p><readonly aria-label=\"Party!\" contenteditable=\"false\" itemtype=\"http://schema.skype.com/Sticker\" title=\"Party!\"><img src=\"demo://photo-1\" width=\"480\" height=\"320\" itemscope=\"image/png\" itemtype=\"http://schema.skype.com/AMSImage\" alt=\"Party!\" id=\"demo-sticker-1\" itemid=\"demo-sticker-1\" href=\"demo://photo-1\" target-src=\"demo://photo-1\"></readonly></p>"),
                        keepOwnership: true)
        }
        if seeds.contains("cards") {
            // ADAPTIVE-ACTIONS: one submit card, one showcard+toggle
            // card, one approval card — the R3 capture set.
            for m in DemoData.actionCardSeeds() {
                conv.ingest(m, keepOwnership: true)
            }
        }
        if seeds.contains("loop") {
            // LOOPBUILD: one received Loop component — the static
            // card + gated live row (R3 capture set).
            for m in DemoData.loopSeeds() {
                conv.ingest(m, keepOwnership: true)
            }
        }
        if seeds.contains("reply"), let target = others.last { conv.beginReply(to: target) }
        if seeds.contains("share"), let target = others.last {
            // Next turn: the window is on screen by then (the route is
            // applied before the window is first shown, same as delete).
            DispatchQueue.main.async {
                m.presentSheet(SheetRequest(ChatCommands.shareOutlookSheet, in: .chat, arg: target.id))
            }
        }
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
        if seeds.contains("deletefail"), let target = own.last {
            // Demo has no server to refuse the delete: run the real path
            // (the demo ids are not live, so the wire throws and the row
            // takes the failed-delete form with Retry, via the same catch
            // as a live refusal). Next turn, like `delete` above.
            DispatchQueue.main.async {
                conv.deleteMessage(id: target.id, isOneToOne: false)
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
