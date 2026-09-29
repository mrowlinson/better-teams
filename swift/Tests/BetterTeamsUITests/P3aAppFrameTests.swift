// P3aAppFrameTests.swift — P3a acceptance (UI-SPEC §5.2, §7.3, §12 P3a):
// pin order persists, `app/<id>` opens in-window, LRU eviction keeps
// the instance across detach/attach, web nav items only in web content.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
private final class ToolbarHost: ShellHost {
    var toolbar: Set<CommandID> = []
    var layout: SectionLayout?

    func applyPanes(key: String, provider: SectionProvider, layout: SectionLayout,
                    inspectorAvailable: Bool, inspectorVisible: Bool, searching: Bool) {
        self.layout = layout
    }
    func applyToolbar(_ visible: Set<CommandID>) { toolbar = visible }
    func applyTitle(_ title: String, subtitle: String) {}
    func clearSearchField() {}
    func focusSearchField(placeholder: String) {}
}

@MainActor
final class P3aAppFrameTests: XCTestCase {
    private func makeNavigator() -> (Navigator, ToolbarHost) {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "p3a-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "p3a-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        let host = ToolbarHost()
        nav.host = host
        return (nav, host)
    }

    func testPinOrderPersistsAcrossReload() {
        let account = "p3a-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "bt.rail.\(account)") }
        let rail = RailModel(accountKey: account, persist: true)
        rail.pin(.native(.planner))
        rail.pin(.web("web-demo"))
        rail.pin(.native(.todo))
        rail.pin(.web("web-demo")) // duplicate ignored
        rail.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(rail.pinned, [.native(.todo), .native(.planner), .web("web-demo")])
        rail.unpin(.native(.planner))

        let reloaded = RailModel(accountKey: account, persist: true)
        XCTAssertEqual(reloaded.pinned, [.native(.todo), .web("web-demo")])
    }

    func testAppRouteOpensInWindowAsTransient() {
        let (nav, host) = makeNavigator()
        nav.apply(Route(string: "app/web-demo")!)
        XCTAssertEqual(nav.model.nav.section, .web("web-demo"))
        XCTAssertEqual(host.layout, .full) // in the main window's content area
        XCTAssertEqual(nav.model.rail.transient, .web("web-demo"))

        nav.apply(Route(string: "app/planner")!)
        XCTAssertEqual(nav.model.nav.section, .native(.planner))
        XCTAssertEqual(nav.model.rail.transient, .native(.planner)) // replaces the previous transient

        // Pinned apps are never transient; unpinning the app on screen keeps it listed.
        nav.model.rail.pin(.native(.planner))
        XCTAssertNil(nav.model.rail.transient)
        nav.unpin(.native(.planner))
        XCTAssertEqual(nav.model.rail.transient, .native(.planner))
    }

    func testLRUEvictionKeepsInstanceAcrossDetachAttach() {
        // Pure policy: visible never evicted; oldest hidden beyond cap first.
        let t = Date()
        let rs = [
            FramePolicy.Resident(key: "a", visible: false, lastUsed: t.addingTimeInterval(-30)),
            FramePolicy.Resident(key: "b", visible: true, lastUsed: t.addingTimeInterval(-60)),
            FramePolicy.Resident(key: "c", visible: false, lastUsed: t.addingTimeInterval(-10), suspended: true),
            FramePolicy.Resident(key: "d", visible: false, lastUsed: t.addingTimeInterval(-20)),
        ]
        XCTAssertEqual(FramePolicy.evict(rs, cap: 1), ["d", "a"])
        XCTAssertEqual(Set(FramePolicy.evict(rs, cap: 3, pressure: .warning)), ["c"])
        XCTAssertEqual(Set(FramePolicy.evict(rs, cap: 3, pressure: .critical)), ["a", "c", "d"])

        // Host: detach never destroys; eviction releases the LRU view.
        let host = FrameHost(accountKey: "demo")
        for app in DemoFrameApps.webLinks.prefix(3) { host.registerApp(app) }
        let keys = DemoFrameApps.webLinks.prefix(3).map { FrameKey.app($0.id) }
        let box = NSView()
        host.attach(keys[0], to: box)
        let first = host.webView(keys[0])
        XCTAssertNotNil(first)
        host.detach(keys[0], from: box)
        host.attach(keys[0], to: box)
        XCTAssertTrue(host.webView(keys[0]) === first)

        host.keepInMemory = 1
        host.attach(keys[1], to: NSView())
        host.attach(keys[2], to: NSView())
        XCTAssertNil(host.webView(keys[0]))
        XCTAssertNil(host.webView(keys[1]))
        XCTAssertNotNil(host.webView(keys[2]))
    }

    func testWebNavItemsOnlyInWebContent() {
        let (nav, host) = makeNavigator()
        let web: Set<CommandID> = [AppsCommands.back, AppsCommands.forward, AppsCommands.reload, AppsCommands.more]
        nav.select(section: .web("web-demo"))
        XCTAssertTrue(host.toolbar.isSuperset(of: web))
        for s in SectionID.builtIns + [.apps, .native(.planner)] {
            nav.select(section: s)
            XCTAssertTrue(host.toolbar.isDisjoint(with: web), "web items visible in \(s.key)")
        }
        // Inspector toggle stays visible and validates off in web apps (§5.4).
        nav.select(section: .web("web-demo"))
        XCTAssertTrue(host.toolbar.contains(ShellCommand.inspector))
        XCTAssertFalse(nav.hasInspector(.web("web-demo")))
    }
}
