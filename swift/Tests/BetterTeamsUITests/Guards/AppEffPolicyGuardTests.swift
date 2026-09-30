// AppEffPolicyGuardTests.swift — guards for the two app-pane efficiency
// settings (APPEFF2; owner 09-29: "enabled by default. allow them to be
// turned off in settings"): unload apps hidden for 30 minutes (O2) and
// pause the panes while Better Teams is in the background (O5). Offline;
// no window is ever shown.
import AppKit
import WebKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppEffPolicyGuardTests: XCTestCase {
    private func waitFor(_ seconds: Double, _ cond: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func offscreenWindow(_ container: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        w.contentView = container
        return w
    }

    /// A demo host (local pages, no network) with the settings under test on.
    private func host(apps n: Int) -> (FrameHost, [FrameKey]) {
        let host = FrameHost(accountKey: "demo")
        host.unloadIdleApps = true
        host.pauseInBackground = true
        let apps = Array(DemoFrameApps.webLinks.prefix(n))
        for a in apps { host.registerApp(a) }
        return (host, apps.map { FrameKey.app($0.id) })
    }

    // MARK: defaults

    func testBothSettingsAreOnByDefaultAndPersistOff() {
        let d = UserDefaults(suiteName: "appeff2-\(UUID().uuidString)")!
        XCTAssertTrue(FramePolicy.unloadIdleApps(d), "unload hidden apps: on by default")
        XCTAssertTrue(FramePolicy.pauseInBackground(d), "pause in background: on by default")
        d.set(false, forKey: FramePolicy.unloadIdleAppsKey)
        d.set(false, forKey: FramePolicy.pauseInBackgroundKey)
        XCTAssertFalse(FramePolicy.unloadIdleApps(d))
        XCTAssertFalse(FramePolicy.pauseInBackground(d))
        XCTAssertEqual(FramePolicy.idleUnloadAfter, 30 * 60, "hidden for 30 minutes")
    }

    func testProductHostStartsWithBothOn() {
        UserDefaults.standard.removeObject(forKey: FramePolicy.unloadIdleAppsKey)
        UserDefaults.standard.removeObject(forKey: FramePolicy.pauseInBackgroundKey)
        let h = FrameHost(accountKey: "appeff2-product", store: .nonPersistent())
        XCTAssertTrue(h.unloadIdleApps)
        XCTAssertTrue(h.pauseInBackground)
        XCTAssertEqual(h.idleUnloadAfter, 30 * 60)
    }

    func testIdlePolicyTakesOnlyHiddenAppsPastTheLimit() {
        let now = Date()
        let rs = [
            FramePolicy.Resident(key: "old-hidden", visible: false, lastUsed: now.addingTimeInterval(-31 * 60)),
            FramePolicy.Resident(key: "new-hidden", visible: false, lastUsed: now.addingTimeInterval(-29 * 60)),
            FramePolicy.Resident(key: "old-visible", visible: true, lastUsed: now.addingTimeInterval(-90 * 60)),
        ]
        XCTAssertEqual(FramePolicy.idle(rs, now: now, after: FramePolicy.idleUnloadAfter), ["old-hidden"])
    }

    // MARK: O2 unload hidden apps

    func testIdleHiddenAppIsUnloadedAndRestoresOnOpen() async throws {
        let (h, keys) = host(apps: 2)
        h.idleUnloadAfter = 0
        let shown = NSView()
        let win = offscreenWindow(shown)
        let a = NSView(), b = NSView()
        shown.addSubview(a)
        h.attach(keys[0], to: a)
        await waitFor(10) { h.page(keys[0])?.state == .loaded }
        h.detach(keys[0], from: a)
        h.attach(keys[1], to: NSView())
        XCTAssertNotNil(h.webView(keys[0]), "hidden but resident until the limit")
        // The visible app is never unloaded; the hidden one is.
        shown.addSubview(b)
        h.attach(keys[1], to: b)
        XCTAssertEqual(h.unloadIdle(), [keys[0].raw])
        XCTAssertNil(h.webView(keys[0]), "unloaded")
        XCTAssertNotNil(h.webView(keys[1]), "on screen: kept")
        // Opening it again restores it.
        h.detach(keys[1], from: b)
        h.attach(keys[0], to: b)
        XCTAssertNotNil(h.webView(keys[0]), "back in memory on open")
        await waitFor(10) { h.page(keys[0])?.state == .loaded }
        XCTAssertEqual(h.page(keys[0])?.state, .loaded, "and loads")
        h.unload(keys[0]); h.unload(keys[1])
        withExtendedLifetime(win) {}
    }

    func testTurningUnloadOffKeepsHiddenApps() {
        let (h, keys) = host(apps: 1)
        h.idleUnloadAfter = 0
        h.attach(keys[0], to: NSView())
        h.attach(FrameKey("tab:none"), to: NSView())
        let live = FrameContainerView(key: keys[0], host: h)
        h.detach(keys[0], from: live)
        XCTAssertNotNil(h.webView(keys[0]))
        h.unloadIdleApps = false
        XCTAssertEqual(h.unloadIdle(), [], "off: nothing unloads")
        XCTAssertNotNil(h.webView(keys[0]))
        h.unloadIdleApps = true
        XCTAssertEqual(h.unloadIdle(), [keys[0].raw], "on: it does")
    }

    /// The timer path: one timer, aimed at the deadline, unloads by itself.
    func testTimerUnloadsAHiddenAppWhenDue() async {
        let (h, keys) = host(apps: 1)
        h.idleUnloadAfter = 0.3
        let box = NSView()
        let win = offscreenWindow(NSView())
        win.contentView?.addSubview(box)
        h.attach(keys[0], to: box)
        box.removeFromSuperview() // hidden
        h.attach(keys[0], to: box)
        h.detach(keys[0], from: box)
        XCTAssertNotNil(h.webView(keys[0]))
        await waitFor(5) { h.webView(keys[0]) == nil }
        XCTAssertNil(h.webView(keys[0]), "the timer unloaded it")
        withExtendedLifetime(win) {}
    }

    // MARK: O5 pause in the background

    private func shownPane() async throws -> (FrameHost, FrameKey, NSView, NSWindow, WKWebView) {
        let (h, keys) = host(apps: 1)
        let root = NSView()
        let win = offscreenWindow(root)
        let box = FrameContainerView(key: keys[0], host: h)
        root.addSubview(box)
        box.frame = root.bounds
        h.attach(keys[0], to: box)
        await waitFor(10) { h.page(keys[0])?.committed == true }
        let web = try XCTUnwrap(h.webView(keys[0]))
        return (h, keys[0], box, win, web)
    }

    func testPausedPaneLeavesTheWindowAndResumesOnActivate() async throws {
        let (h, key, box, win, web) = try await shownPane()
        XCTAssertTrue(web.superview === box)
        win.makeFirstResponder(web)
        XCTAssertTrue(win.firstResponder === web, "focused before the pause")
        h.pauseForBackground()
        await waitFor(10) { h.page(key)?.pausedInBackground == true }
        XCTAssertEqual(h.page(key)?.pausedInBackground, true, "paused")
        XCTAssertNil(web.superview, "out of the view tree: WebKit suspends it")
        XCTAssertNotNil(h.page(key)?.snapshot, "its last picture stands in")
        XCTAssertTrue(h.webView(key) === web, "not unloaded: no reload")
        XCTAssertTrue(h.page(key)?.isOnScreen ?? false, "still the on-screen app for policy and Settings")
        // A SwiftUI update while paused must not wake it.
        h.attach(key, to: box)
        XCTAssertNil(web.superview)
        // Activate: back at once.
        h.appDidBecomeActive()
        XCTAssertTrue(web.superview === box, "resumed in the same container")
        XCTAssertTrue(win.firstResponder === web, "keyboard focus given back")
        XCTAssertEqual(h.page(key)?.pausedInBackground, false)
        h.unload(key)
        withExtendedLifetime(win) {}
    }

    func testTurningPauseOffPutsThePaneBackAndNeverPauses() async throws {
        let (h, key, box, win, web) = try await shownPane()
        h.pauseInBackground = false
        h.pauseForBackground()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(web.superview === box, "off: never paused")
        XCTAssertEqual(h.page(key)?.pausedInBackground, false)
        // On, paused, then off again: the pane returns.
        h.pauseInBackground = true
        h.pauseForBackground()
        await waitFor(10) { h.page(key)?.pausedInBackground == true }
        h.pauseInBackground = false
        XCTAssertTrue(web.superview === box)
        XCTAssertEqual(h.page(key)?.pausedInBackground, false)
        h.unload(key)
        withExtendedLifetime(win) {}
    }

    func testActivatingBeforeThePictureIsTakenCancelsThePause() async throws {
        let (h, key, box, win, web) = try await shownPane()
        h.pauseForBackground()
        h.appDidBecomeActive() // back before the snapshot answers
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(web.superview === box, "never removed")
        XCTAssertEqual(h.page(key)?.pausedInBackground, false)
        h.unload(key)
        withExtendedLifetime(win) {}
    }

    /// Notifications, calls and unread badges run in the core, not in a
    /// pane: none of their sources reaches a web pane, so pausing or
    /// unloading a pane cannot stop them.
    func testNotificationsCallsAndBadgesNeverDependOnAPane() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let fm = FileManager.default
        var files = ["OstMacCore/Notifications.swift", "OstMacCore/Notifier.swift", "OstMacCore/NcDelivery.swift",
                     "OstMacCore/UnreadStore.swift", "OstMacCore/MentionStore.swift",
                     "BetterTeamsUI/App/DockBadge.swift", "BetterTeamsUI/App/Notifications.swift",
                     "BetterTeamsUI/App/AppDelegate.swift"]
        let calls = sources.appendingPathComponent("BetterTeamsUI/Call")
        files += try fm.contentsOfDirectory(atPath: calls.path).filter { $0.hasSuffix(".swift") }
            .map { "BetterTeamsUI/Call/\($0)" }
        for f in files {
            let text = try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.contains("FrameHost") || text.contains("FramePage") || text.contains("WKWebView"),
                           "\(f) must not depend on a web pane")
        }
        XCTAssertGreaterThan(files.count, 12, "sources found (positive control)")
        // Positive control: the check does see a pane user.
        let pane = try String(contentsOf: sources.appendingPathComponent("BetterTeamsUI/Frame/FrameContainer.swift"), encoding: .utf8)
        XCTAssertTrue(pane.contains("FrameHost"))
    }
}
