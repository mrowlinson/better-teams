// MeetLinkNeverBrowserTests.swift — FIXPACK F12: a pasted Microsoft Teams
// link never opens a browser; short /meet/ links resolve natively; other
// meeting sites may open in the default browser.
import XCTest

@testable import OstMacCore

@MainActor
final class MeetLinkNeverBrowserTests: XCTestCase {
    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        func add(_ u: URL) { lock.withLock { _urls.append(u) } }
        var urls: [URL] { lock.withLock { _urls } }
    }

    private let thread = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%7d"

    private func settle(_ vm: MeetingsViewModel) async {
        // parsing is set synchronously by submitJoin and a chained stage
        // (short-link resolve) flips false -> true in one main-actor step, so
        // a condition wait sees the end. Yield count (not wall time) drains
        // any trailing main-actor hop, then wait again.
        let first = await TestWait.until(interval: 0.002) { !vm.parsing }
        XCTAssertTrue(first, "join never finished parsing")
        for _ in 0 ..< 100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000) // negative window: a trailing hop must not reopen parsing
        let second = await TestWait.until(interval: 0.002) { !vm.parsing }
        XCTAssertTrue(second, "join never finished parsing (chained stage)")
    }

    private func join(_ raw: String, resolver: @escaping MeetingsViewModel.LinkResolver = { _ in nil }) async -> (MeetingsViewModel, [URL]) {
        let opened = Opened()
        let vm = MeetingsViewModel(opener: { opened.add($0) }, linkResolver: resolver)
        vm.joinText = raw
        vm.submitJoin()
        await settle(vm)
        return (vm, opened.urls)
    }

    func testNoMicrosoftTeamsHostEverOpensABrowser() async {
        let links = [
            "https://teams.microsoft.com/meet/123456789012?p=abc",
            "https://teams.live.com/meet/9312345678901?p=abc",
            "https://gov.teams.microsoft.com/meet/123456789012?p=x",
            "https://emea.teams.microsoft.com/l/message/19:x@thread.v2/1",
            "https://teams.cloud.microsoft/meet/123456789012?p=x",
            "https://teams.cloud.microsoft/l/team/xyz",
            "https://teams.microsoft.com/l/meetup-join/nothread",
            "https://TEAMS.MICROSOFT.COM/meet/123456789012",
            "https://teams.microsoft.com./meet/123456789012",
        ]
        for link in links {
            let (vm, opened) = await join(link)
            XCTAssertTrue(opened.isEmpty, "\(link) opened \(opened)")
            XCTAssertNotNil(vm.joinLinkError, "\(link) must say why it can't join")
            XCTAssertFalse(vm.showPreJoin)
        }
    }

    func testShortMeetLinkResolvesNativelyToThePreJoinSheet() async {
        for link in ["https://teams.microsoft.com/meet/123456789012?p=abc", "https://teams.live.com/meet/9312345678901?p=abc",
                     "https://teams.cloud.microsoft/meet/123456789012?p=abc"] {
            let seen = Opened()
            let (vm, opened) = await join(link, resolver: { url in seen.add(url); return self.thread })
            XCTAssertTrue(opened.isEmpty, "\(link)")
            XCTAssertEqual(seen.urls.map(\.absoluteString), [link])
            XCTAssertNil(vm.joinLinkError)
            XCTAssertTrue(vm.showPreJoin, link)
            XCTAssertEqual(vm.pendingJoin?.threadID, "19:meeting_ABC@thread.v2")
        }
    }

    func testUnresolvableShortLinkIsAnErrorThatSaysSo() async {
        let (vm, opened) = await join("https://teams.microsoft.com/meet/123456789012?p=abc")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(vm.showPreJoin)
        XCTAssertTrue(vm.joinLinkError?.contains("without opening Teams in a browser") == true, vm.joinLinkError ?? "")
        XCTAssertEqual(vm.joinHint, vm.joinLinkError)
        // A resolver that answers a non-thread page is the same error.
        let (vm2, opened2) = await join("https://teams.microsoft.com/meet/123456789012", resolver: { _ in "https://teams.microsoft.com/dl/launcher" })
        XCTAssertTrue(opened2.isEmpty)
        XCTAssertNotNil(vm2.joinLinkError)
        // A new paste clears the old error.
        vm2.joinText = self.thread
        vm2.submitJoin()
        await settle(vm2)
        XCTAssertNil(vm2.joinLinkError)
    }

    func testOtherMeetingSitesMayOpenInTheDefaultBrowser() async {
        for link in ["https://zoom.us/j/123456789", "https://acme.webex.com/meet/room", "https://meet.google.com/abc-defg-hij",
                     "https://teams.microsoft.com.example.net/meet/123456789012"] {
            let (vm, opened) = await join(link)
            XCTAssertEqual(opened.map(\.absoluteString), [link], link)
            XCTAssertNil(vm.joinLinkError)
        }
    }

    func testHostRuleIsExactAndCoversTheFourFamilies() {
        for h in ["teams.microsoft.com", "TEAMS.live.com", "a.b.teams.microsoft.com", "teams.cloud.microsoft", "x.teams.cloud.microsoft", "teams.microsoft.com."] {
            XCTAssertTrue(MeetLinkResolver.isMicrosoftTeamsHost(h), h)
        }
        for h in ["zoom.us", "teams.microsoft.com.evil.net", "eviltems.microsoft.com", "microsoft.com", "", "xteams.live.com"] {
            XCTAssertFalse(MeetLinkResolver.isMicrosoftTeamsHost(h), h)
        }
        XCTAssertNil(MeetJoin.hint(for: JoinTarget(kind: "thread", threadID: "19:a@thread.v2", url: "u")))
        XCTAssertEqual(MeetJoin.buttonLabel(for: JoinTarget(kind: "url", url: "https://zoom.us/j/1")), "Open")
        XCTAssertEqual(MeetJoin.buttonLabel(for: JoinTarget(kind: "url", url: "https://teams.microsoft.com/meet/1")), "Join")
    }

    /// The redirect walk over a fake transport: /meet -> launcher -> meetup-join.
    func testResolverFollowsRedirectsOnlyThroughMicrosoftHostsAndStopsAtAThread() async {
        let calls = Opened()
        let launcher = "https://teams.microsoft.com/dl/launcher/launcher.html?url=%2F_%23%2Fl%2Fmeetup-join%2F19%3Ameeting_XYZ%40thread.v2%2F0"
        let table: [String: String] = [
            "https://teams.microsoft.com/meet/123456789012?p=a": "https://teams.microsoft.com/dl/launcher/start",
            "https://teams.microsoft.com/dl/launcher/start": launcher,
        ]
        let hop: MeetLinkResolver.Hop = { url in
            calls.add(url)
            return table[url.absoluteString].flatMap(URL.init(string:))
        }
        let got = await MeetLinkResolver.resolve(URL(string: "https://teams.microsoft.com/meet/123456789012?p=a")!, hop: hop)
        XCTAssertEqual(got, "19:meeting_XYZ@thread.v2")
        XCTAssertEqual(calls.urls.count, 2)
        // A chain that leaves Microsoft (login page) is not followed further.
        let off: MeetLinkResolver.Hop = { url in
            calls.add(url)
            return URL(string: "https://login.example.net/x")
        }
        let none = await MeetLinkResolver.resolve(URL(string: "https://teams.microsoft.com/meet/1")!, hop: off)
        XCTAssertNil(none)
        // A loop is bounded.
        let loop: MeetLinkResolver.Hop = { url in url }
        let bounded = await MeetLinkResolver.resolve(URL(string: "https://teams.microsoft.com/meet/1")!, maxHops: 3, hop: loop)
        XCTAssertNil(bounded)
    }
}
