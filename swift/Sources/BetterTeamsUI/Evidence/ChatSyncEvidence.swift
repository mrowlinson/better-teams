// ChatSyncEvidence.swift — CHATSYNC2b demo evidence (UI-SPEC §11.3):
//
//   chat/<id>?window=popout            the chat in its own window (row
//                                      menu ▸ Pop Out Chat), focused
//   chat/<id>?menu=row                 prints the chat row context menu
//   chat/<id>?menu=message             prints the newest message's menu
//   chat/<id>?policy=allowed|denied|unknown   Teams delete-chat policy
//
// Menus print as text between "EVIDENCE MENU BEGIN <kind>" and
// "EVIDENCE MENU END" (title, key, ✓, disabled, help), built from the
// same SwiftUI menu content the app shows, in an off-screen host (never
// ordered in, no events posted).
import AppKit
import OstMacCore
import SwiftUI

@MainActor
enum ChatSyncEvidence {
    /// After startup (the route's chat is open).
    static func afterStartup(_ wc: ShellWindowController) {
        let m = wc.model
        guard m.options.demo, let app = m.app, let raw = m.options.route, let route = Route(string: raw),
              route.head == "chat", let id = route.tail.first else { return }
        // ?density=compact|comfortable: demo stores are in-memory, so the
        // Settings ▸ Chats choice is set here for density captures.
        if let raw = route.query["density"], let d = MessageDensity(rawValue: raw) { app.density.mode = d }
        switch route.query["policy"] {
        case "allowed": app.chats.deletePolicy = .allowed
        case "denied": app.chats.deletePolicy = .denied
        case "unknown": app.chats.deletePolicy = .unknown
        default: break
        }
        switch route.query["menu"] {
        case "row":
            let menu = ChatRowMenu(id: id, chats: app.chats, unread: app.unread, rules: app.rules,
                                   snooze: app.snooze, folders: app.chats.folders, model: m)
            emit("row", menuText(menu))
        case "message":
            Task {
                guard await waitFor({ m.graph.conv.chatID == id && !m.graph.conv.messages.isEmpty }),
                      let newest = m.graph.conv.messages.last else { return }
                let row = MessageRowData(message: newest, showsHeader: true, send: .none, quote: nil,
                                         receipt: .none, translation: nil, isPinned: false, isSaved: false,
                                         ownName: nil, chatID: id)
                let actions = TimelineActions(conv: m.graph.conv, model: m, services: ConversationServices.of(m))
                emit("message", menuText(MessageContextMenu(row: row, actions: actions)))
            }
        default: break
        }
        if route.query["window"] == "popout" {
            ChatWindowController.show(m, chatID: id)
            let w = ChatWindowController.window(for: id)
            CallEvidence.focus(w, over: wc)
            // Timeline geometry of the pop-out (stale row heights = clip
            // or gaps), once it has settled.
            Task {
                for delay in [2_500_000_000, 5_000_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard let w, let root = w.contentView else { return }
                    func r(_ v: NSView) -> String {
                        let f = v.convert(v.bounds, to: nil)
                        return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
                    }
                    let tls = timelines(in: root)
                    let scrolls = tls.compactMap { $0.view.subviews.first { $0 is NSScrollView } }.map(r)
                    let texts = textViews(in: root).filter { tv in !scrollsContain(tls, tv) }.map(r)
                    let safe = root.safeAreaInsets
                    print("EVIDENCE POPOUT GEOMETRY window=\(Int(w.frame.width))x\(Int(w.frame.height)) "
                          + "layout=\(Int(w.contentLayoutRect.height)) content=\(r(root)) "
                          + "safe=\(Int(safe.top)),\(Int(safe.bottom)) timelineScroll=\(scrolls) composerText=\(texts) "
                          + "timelines[\(tls.map { $0.geometryAudit() }.joined(separator: "; "))]")
                    fflush(stdout)
                }
            }
        }
    }

    private static func textViews(in v: NSView) -> [NSView] {
        var out: [NSView] = v is NSTextView || v is NSTextField ? [v] : []
        for s in v.subviews { out += textViews(in: s) }
        return out
    }

    private static func scrollsContain(_ tls: [TimelineViewController], _ v: NSView) -> Bool {
        tls.contains { v.isDescendant(of: $0.view) }
    }

    private static func timelines(in v: NSView) -> [TimelineViewController] {
        var out: [TimelineViewController] = []
        if let t = (v as? NSTableView)?.delegate as? TimelineViewController { out.append(t) }
        for s in v.subviews { out += timelines(in: s) }
        return out
    }

    private static func emit(_ kind: String, _ text: String) {
        print("EVIDENCE MENU BEGIN \(kind)\n\(text)EVIDENCE MENU END")
        fflush(stdout)
    }

    /// The context menu SwiftUI builds for `content` (never shown).
    static func menuText<V: View>(_ content: V) -> String {
        // NSHostingMenu: the AppKit menu SwiftUI builds from the same
        // menu content (items appear on the menu's update pass).
        let menu = NSHostingMenu(rootView: content)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.isEmpty ? "(no menu)\n" : dump(menu)
    }

    private static func dump(_ menu: NSMenu, depth: Int = 0) -> String {
        menu.update()
        var out = ""
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem { out += "\(pad)---\n"; continue }
            let state = item.state == .on ? " ✓" : ""
            let enabled = item.isEnabled ? "" : " (disabled)"
            let help = item.toolTip.map { "  [help: \($0)]" } ?? ""
            out += "\(pad)\(item.title)\(state)\(enabled)\(help)\n"
            if let sub = item.submenu { out += dump(sub, depth: depth + 1) }
        }
        return out
    }

    /// Re-checks `ok` once per main-queue turn until it holds or 3 s pass.
    private static func waitFor(_ ok: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ok() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ok()
    }
}
