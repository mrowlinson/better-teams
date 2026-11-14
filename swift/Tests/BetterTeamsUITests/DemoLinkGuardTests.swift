// DemoLinkGuardTests.swift — P2#14: demo never opens the system
// browser (or Mail): Search Email / Open in Browser copy, and
// non-Microsoft card links copy, while Microsoft links still route
// natively.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

/// Test-local URL trap (the system opener is a `@Sendable` closure).
private final class OpenedBox: @unchecked Sendable {
    var urls: [URL] = []
}

@MainActor
final class DemoLinkGuardTests: XCTestCase {
    // Save/restore: nativeHandler is installed one-shot (TeamsLinkUI.install
    // no-ops after the first call), so blind-nil teardown strands every later
    // router test on "refused" in full-suite order. Mirror the router tests'
    // own save/restore pattern instead.
    private var savedHandler: ((URL, AnyObject?) -> Bool)?
    private var savedOpener: (@Sendable (URL) -> Bool)!
    private var hadHandler = false

    override func setUp() {
        super.setUp()
        savedOpener = TeamsLinkRouter.systemOpener
        // XCTest-safe equivalent of the default (never opens under test).
        TeamsLinkRouter.systemOpener = { _ in false }
    }

    override func tearDown() {
        TeamsLinkRouter.systemOpener = savedOpener
        if hadHandler { TeamsLinkRouter.nativeHandler = savedHandler }
        CardLinks.demoStaysInApp = false
        CardLinks.lastDemoCopy = nil
        super.tearDown()
    }

    private func trapOpener() -> OpenedBox {
        let box = OpenedBox()
        TeamsLinkRouter.systemOpener = { url in
            box.urls.append(url)
            return true
        }
        return box
    }

    func testDemoCopiesNonMicrosoftCardLink() {
        let box = trapOpener()
        CardLinks.demoStaysInApp = true
        defer {
            CardLinks.demoStaysInApp = false
            CardLinks.lastDemoCopy = nil
        }
        CardLinks.open("https://example.com/shared-doc")
        XCTAssertTrue(box.urls.isEmpty, "demo never reaches the system browser")
        XCTAssertEqual(CardLinks.lastDemoCopy, "https://example.com/shared-doc")
    }

    func testDemoStillRoutesMicrosoftLinksNatively() {
        let box = trapOpener()
        savedHandler = TeamsLinkRouter.nativeHandler
        hadHandler = true
        CardLinks.demoStaysInApp = true
        defer {
            CardLinks.demoStaysInApp = false
            CardLinks.lastDemoCopy = nil
        }
        var natived: [URL] = []
        TeamsLinkRouter.nativeHandler = { url, _ in natived.append(url); return true }
        CardLinks.open("https://teams.microsoft.com/l/chat/0/0")
        XCTAssertEqual(natived.count, 1)
        XCTAssertTrue(box.urls.isEmpty)
        XCTAssertNil(CardLinks.lastDemoCopy,
                      "Microsoft links route, never copy")
    }

    func testLiveOpensNonMicrosoftCardLink() {
        let box = trapOpener()
        CardLinks.open("https://example.com/shared-doc")
        XCTAssertEqual(box.urls.map(\.absoluteString), ["https://example.com/shared-doc"])
        XCTAssertNil(CardLinks.lastDemoCopy)
    }

    func testCopyRecordsLink() {
        CardLinks.copy("ava@example.com")
        XCTAssertEqual(CardLinks.lastDemoCopy, "ava@example.com")
    }
}
