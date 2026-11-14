// DeepLinkTests.swift — P2#12: `betterteams://` URLs resolve to section
// routes (applied in the main window) or to a wrapped link; anything
// else under the scheme is ignored.
import XCTest

@testable import BetterTeamsUI
import Foundation

@MainActor
final class DeepLinkTests: XCTestCase {
    func testSectionRoute() {
        let route = AppDelegate.deepLinkRoute(URL(string: "betterteams://chat/19:abc?tab=files")!)
        XCTAssertEqual(route?.head, "chat")
        XCTAssertEqual(route?.tail, ["19:abc"])
        XCTAssertEqual(route?.section, .chat)
    }

    func testNonSectionRouteIgnored() {
        // "open" names no section: the wrapped-link path handles it.
        XCTAssertNil(AppDelegate.deepLinkRoute(URL(string: "betterteams://open?url=https%3A%2F%2Fexample.com")!))
        XCTAssertNil(AppDelegate.deepLinkRoute(URL(string: "betterteams://")!))
        XCTAssertNil(AppDelegate.deepLinkRoute(URL(string: "https://teams.microsoft.com/")!))
        XCTAssertNil(AppDelegate.deepLinkRoute(URL(string: "msteams:/l/chat/0/0")!))
    }

    func testWrappedURL() {
        let wrapped = AppDelegate.deepLinkWrappedURL(
            URL(string: "betterteams://open?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fchat")!)
        XCTAssertEqual(wrapped?.absoluteString, "https://teams.microsoft.com/l/chat")
        XCTAssertNil(AppDelegate.deepLinkWrappedURL(URL(string: "betterteams://chat/19:abc")!))
        XCTAssertNil(AppDelegate.deepLinkWrappedURL(URL(string: "https://example.com/?url=https://x.com")!))
    }
}
