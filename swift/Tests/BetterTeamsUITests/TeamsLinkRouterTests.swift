// TeamsLinkRouterTests — LINKGUARD R1/R2: every kind of Teams / Microsoft
// 365 link (sample URLs, fake ids) opens on its native screen or is
// refused with an error; anything else goes to the system. No window.
import AppKit
import OstMacCore
import XCTest

@testable import BetterTeamsUI

@MainActor
final class TeamsLinkRouterTests: XCTestCase {
    private var opened: [URL] = []
    private var refused: [URL] = []
    private var savedOpener: (@Sendable (URL) -> Bool)!
    private var savedRefusal: ((URL, AnyObject?) -> Void)?

    override func setUp() async throws {
        TeamsLinkUI.install()
        savedOpener = TeamsLinkRouter.systemOpener
        savedRefusal = TeamsLinkRouter.refusalHandler
        opened = []
        refused = []
        let box = OpenedBox()
        openedBox = box
        TeamsLinkRouter.systemOpener = { url in box.add(url); return true }
        TeamsLinkRouter.refusalHandler = { [weak self] url, _ in self?.refused.append(url) }
    }

    override func tearDown() async throws {
        TeamsLinkRouter.systemOpener = savedOpener
        TeamsLinkRouter.refusalHandler = savedRefusal
    }

    private var openedBox: OpenedBox!
    final class OpenedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: classification

    func testFamilies() {
        let teams = ["https://teams.microsoft.com/l/chat/19:aaaa_bbbb@unq.gbl.spaces/0",
                     "https://teams.cloud.microsoft/l/team/19%3Aabc%40thread.tacv2/conversations?groupId=00000000-0000-0000-0000-000000000001",
                     "https://teams.live.com/meet/9300000000001?p=fake", "msteams://teams.microsoft.com/l/chat/0/0?users=a@example.com"]
        let outlook = ["https://outlook.office.com/calendar/item/AAMkFAKE%3D", "https://outlook.office365.com/owa/?itemid=AAMkFAKE&path=/calendar/item"]
        let files = ["https://contoso.sharepoint.com/sites/x/Shared%20Documents/Plan.docx", "https://contoso-my.sharepoint.com/:w:/g/personal/a_contoso_com/EFAKE",
                     "https://onedrive.live.com/?id=FAKE", "https://1drv.ms/w/s!FAKE", "https://www.office.com/launch/word?auth=2"]
        for s in teams { XCTAssertEqual(TeamsLinkRouter.family(u(s)), .teams, s) }
        for s in outlook { XCTAssertEqual(TeamsLinkRouter.family(u(s)), .outlook, s) }
        for s in files { XCTAssertEqual(TeamsLinkRouter.family(u(s)), .files, s) }
        // Controls: not Microsoft app links (and look-alike hosts).
        for s in ["https://example.com/", "https://learn.microsoft.com/en-us/microsoftteams/", "mailto:a@example.com",
                  "https://teams.microsoft.com.evil.example/l/chat/0/0", "https://notsharepoint.com/x", "file:///tmp/a.txt",
                  "https://login.microsoftonline.com/common/oauth2/authorize"] {
            XCTAssertEqual(TeamsLinkRouter.family(u(s)), .other, s)
        }
    }

    func testOutlookEventID() {
        XCTAssertEqual(TeamsLinkRouter.outlookEventID(u("https://outlook.office.com/calendar/item/AAMkFAKE%3D")), "AAMkFAKE=")
        XCTAssertEqual(TeamsLinkRouter.outlookEventID(u("https://outlook.office.com/calendar/0/deeplink/read/AAMkFAKE?ItemID=x")), "AAMkFAKE")
        XCTAssertEqual(TeamsLinkRouter.outlookEventID(u("https://outlook.office365.com/owa/?itemid=AAMkFAKE&exvsurl=1&path=/calendar/item")), "AAMkFAKE")
        XCTAssertNil(TeamsLinkRouter.outlookEventID(u("https://outlook.office.com/mail/inbox")), "control: mail")
        XCTAssertNil(TeamsLinkRouter.outlookEventID(u("https://example.com/calendar/item/x")), "control: host")
    }

    // MARK: one parse per Teams link kind

    func testTeamsLinkKinds() throws {
        func p(_ s: String) -> TeamsDeepLink? { TeamsDeepLink.parse(u(s)) }
        guard case .chat(let cid?, _)? = p("https://teams.microsoft.com/l/chat/19%3Aaaaa_bbbb%40unq.gbl.spaces/conversations") else { return XCTFail("chat") }
        XCTAssertEqual(cid, "19:aaaa_bbbb@unq.gbl.spaces")
        guard case .chat(nil, let users)? = p("https://teams.microsoft.com/l/chat/0/0?users=ada@example.com") else { return XCTFail("chat by user") }
        XCTAssertEqual(users, ["ada@example.com"])
        guard case .channel(let ch, let name, let grp)? = p("https://teams.microsoft.com/l/channel/19%3Aabc%40thread.tacv2/General?groupId=00000000-0000-0000-0000-000000000001&tenantId=t") else { return XCTFail("channel") }
        XCTAssertEqual([ch, name, grp ?? ""], ["19:abc@thread.tacv2", "General", "00000000-0000-0000-0000-000000000001"])
        guard case .message(let th, let msg, nil)? = p("https://teams.microsoft.com/l/message/19%3Aabc%40thread.tacv2/1700000000000?groupId=g") else { return XCTFail("channel post") }
        XCTAssertEqual([th, msg], ["19:abc@thread.tacv2", "1700000000000"])
        for s in ["https://teams.microsoft.com/l/meetup-join/19%3Ameeting_FAKE%40thread.v2/0?context=%7B%7D",
                  "https://teams.microsoft.com/meet/9300000000001?p=fake", "https://teams.live.com/meet/9300000000001",
                  "msteams://teams.microsoft.com/l/meetup-join/19%3Ameeting_FAKE%40thread.v2/0"] {
            guard case .meetupJoin? = p(s) else { return XCTFail("meeting \(s)") }
        }
        guard case .entity(let app, _, _, _)? = p("https://teams.microsoft.com/l/entity/00000000-0000-0000-0000-000000000abc/tab1") else { return XCTFail("tab") }
        XCTAssertEqual(app, "00000000-0000-0000-0000-000000000abc")
        guard case .profile(let uid)? = p("https://teams.microsoft.com/l/profile/00000000-0000-0000-0000-000000000042") else { return XCTFail("profile") }
        XCTAssertEqual(uid, "00000000-0000-0000-0000-000000000042")
        let object = "https://contoso.sharepoint.com/sites/x/Shared%20Documents/Plan.docx"
        let encoded = object.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        guard case .file(let f)? = p("https://teams.microsoft.com/l/file/00000000-0000-0000-0000-0000000000f1?fileType=docx&objectUrl=\(encoded)") else { return XCTFail("file") }
        XCTAssertEqual(f.absoluteString, object)
        // Controls: no native kind.
        XCTAssertNil(p("https://teams.microsoft.com/l/unknownkind/x"))
        XCTAssertNil(p("https://teams.microsoft.com/l/file/x?objectUrl=https%3A%2F%2Fexample.com%2Fa.docx"), "control: file off Microsoft hosts")
        XCTAssertNil(p("https://example.com/l/chat/1/0"))
    }

    // MARK: routing (demo window, nothing shown)

    func testChatAndPostLinksOpenNatively() {
        let ctx = GuardSupport.demoModel()
        for s in ["https://teams.microsoft.com/l/chat/19%3Aaaaa_bbbb%40unq.gbl.spaces/conversations",
                  "https://teams.microsoft.com/l/message/19%3Aabc%40thread.tacv2/1700000000000",
                  "https://teams.microsoft.com/l/profile/00000000-0000-0000-0000-000000000042"] {
            XCTAssertEqual(TeamsLinkRouter.route(u(s), window: ctx.model), .native, s)
        }
        XCTAssertTrue(openedBox.all.isEmpty, "a Teams link reached the system")
        XCTAssertTrue(refused.isEmpty)
    }

    /// A meeting join link starts the in-app meeting (call section), never
    /// the Teams web app or the system.
    func testMeetingJoinLinksOpenTheInAppMeeting() throws {
        for s in ["https://teams.microsoft.com/l/meetup-join/19%3Ameeting_FAKE%40thread.v2/0?context=%7B%7D",
                  "https://teams.microsoft.com/meet/9300000000001?p=fake"] {
            let ctx = GuardSupport.demoModel()
            XCTAssertNil(ctx.model.call)
            XCTAssertEqual(TeamsLinkRouter.route(u(s), window: ctx.model), .native, s)
            let call = try XCTUnwrap(ctx.model.call, "no meeting started for \(s)")
            guard case .meeting = call.kind else { return XCTFail("not a meeting: \(s)") }
            XCTAssertEqual(ctx.model.nav.section, .call)
            call.leave()
        }
        XCTAssertTrue(openedBox.all.isEmpty, "a meeting link reached the system")
        XCTAssertTrue(refused.isEmpty)
    }

    /// A channel link selects that channel of its team; one for a channel
    /// this account does not have is refused (never the browser).
    func testChannelLinkOpensTheChannelNatively() async throws {
        let ctx = GuardSupport.demoModel()
        await ctx.app.teams.load()
        let team = try XCTUnwrap(ctx.app.teams.teams.first { !$0.channels.isEmpty }, "demo has a team with channels")
        let channel = try XCTUnwrap(team.channels.last)
        let thread = channel.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let link = u("https://teams.microsoft.com/l/channel/\(thread)/General?groupId=\(team.teamId)")
        XCTAssertNotEqual(ctx.model.nav.section, .teams)
        XCTAssertEqual(TeamsLinkRouter.route(link, window: ctx.model), .native)
        XCTAssertEqual(ctx.model.nav.section, .teams)
        let sel = try XCTUnwrap(TeamsSelection(ctx.model.nav.selection(in: .teams)))
        XCTAssertEqual([sel.teamID, sel.channelID ?? ""], [team.teamId, channel.id])
        XCTAssertTrue(openedBox.all.isEmpty)
        // Control: a channel this account does not have.
        XCTAssertEqual(TeamsLinkRouter.route(u("https://teams.microsoft.com/l/channel/19%3Anotmine%40thread.tacv2/x"),
                                             window: ctx.model), .refused)
        XCTAssertEqual(refused.count, 1)
    }

    /// A channel tab link (`tab::<id>`) opens that tab of the channel.
    func testChannelTabLinkOpensTheTabNatively() async throws {
        let ctx = GuardSupport.demoModel()
        await ctx.app.teams.load()
        let channel = DemoTeams.threadedChannelID
        let team = try XCTUnwrap(ctx.app.teams.teams.first { $0.channels.contains { $0.id == channel } })
        let thread = channel.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(TeamsLinkRouter.route(u("https://teams.microsoft.com/l/channel/\(thread)/tab%3A%3Ademo-tab-roadmap"),
                                             window: ctx.model), .native)
        let sel = try XCTUnwrap(TeamsSelection(ctx.model.nav.selection(in: .teams)))
        XCTAssertEqual([sel.teamID, sel.channelID ?? ""], [team.teamId, channel])
        XCTAssertEqual(sel.tab, .web("demo-tab-roadmap"))
        XCTAssertTrue(openedBox.all.isEmpty)
    }

    /// A calendar event link for an event already loaded opens it on the
    /// Calendar screen; demo (no such event, nothing to read) is refused.
    func testCalendarEventLinkOpensTheEventNatively() async throws {
        let ctx = GuardSupport.demoModel()
        await ctx.app.calWeek.load()
        let event = try XCTUnwrap(ctx.app.calWeek.meetings.first, "demo has an event")
        let id = event.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(TeamsLinkRouter.route(u("https://outlook.office.com/calendar/item/\(id)"), window: ctx.model), .native)
        XCTAssertEqual(ctx.model.nav.section, .calendar)
        XCTAssertEqual(CalendarSelection(ctx.model.nav.selection(in: .calendar)).meetingID, event.id)
        XCTAssertTrue(openedBox.all.isEmpty)
        XCTAssertTrue(refused.isEmpty)
    }

    /// OneNote page text (an NSTextView, whose default link click opens the
    /// browser itself) hands link clicks to the router.
    func testOneNotePageLinkClicksGoThroughTheRouter() {
        _ = NSApplication.shared // no window: only so `NSApp` exists for the window lookup
        let c = NotesPageTextView.Coordinator()
        let tv = NSTextView()
        XCTAssertTrue(c.textView(tv, clickedOnLink: u("https://teams.microsoft.com/l/unknownkind/x"), at: 0))
        XCTAssertEqual(refused.count, 1, "unknown Teams link: error alert, not the browser")
        XCTAssertTrue(openedBox.all.isEmpty)
        // String-typed link values (HTML import) and non-Microsoft links.
        XCTAssertTrue(c.textView(tv, clickedOnLink: "https://outlook.office.com/mail/inbox", at: 0))
        XCTAssertEqual(refused.count, 2)
        XCTAssertTrue(c.textView(tv, clickedOnLink: "https://example.com/page", at: 0))
        XCTAssertEqual(openedBox.all.map(\.absoluteString), ["https://example.com/page"])
    }

    func testFileLinkOpensInAppPane() throws {
        let ctx = GuardSupport.demoModel()
        let link = u("https://contoso.sharepoint.com/sites/x/Shared%20Documents/Plan.docx")
        XCTAssertEqual(TeamsLinkRouter.route(link, window: ctx.model), .native)
        let app = try XCTUnwrap(FrameAppDirectory.app(TeamsLinkFiles.appID(for: link)))
        XCTAssertEqual(app.launch, .direct(link))
        XCTAssertEqual(app.label, "Plan.docx")
        XCTAssertNotNil(ctx.model.frameHost.page(.app(app.id)))
        XCTAssertTrue(openedBox.all.isEmpty, "a SharePoint link reached the browser")
    }

    func testUnknownMicrosoftLinksAreRefusedNeverBrowsed() {
        let ctx = GuardSupport.demoModel()
        let links = ["https://teams.microsoft.com/l/unknownkind/x", "https://teams.microsoft.com/shifts-web-app/x",
                     "msteams://teams.microsoft.com/l/whatever", "https://teams.microsoft.com/_#/conversations/x",
                     "https://outlook.office.com/calendar/item/AAMkNOTLOADED", "https://outlook.office.com/mail/inbox",
                     "https://contoso.sharepoint.com/sites/x/Shared%20Documents/Plan.docx".replacingOccurrences(of: "https", with: "http")]
        for s in links {
            XCTAssertEqual(TeamsLinkRouter.route(u(s), window: ctx.model), .refused, s)
        }
        XCTAssertEqual(refused.map(\.absoluteString), links)
        XCTAssertTrue(openedBox.all.isEmpty, "refused link reached the system")
    }

    func testOpenEntryPointRefusesToo() {
        let ctx = GuardSupport.demoModel()
        TeamsLinkRouter.open(u("https://teams.microsoft.com/l/unknownkind/x"), window: ctx.model)
        XCTAssertEqual(refused.count, 1)
        // Explicit "Open in Browser" on a Teams address takes the same route.
        TeamsLinkRouter.openInBrowser(u("https://teams.microsoft.com/l/unknownkind/y"), window: ctx.model)
        XCTAssertEqual(refused.count, 2)
        XCTAssertTrue(openedBox.all.isEmpty)
    }

    func testNonMicrosoftLinksStillGoToTheSystem() {
        let ctx = GuardSupport.demoModel()
        let links = ["https://example.com/page", "https://learn.microsoft.com/en-us/", "mailto:ada@example.com", "tel:+15555550100"]
        for s in links { XCTAssertEqual(TeamsLinkRouter.route(u(s), window: ctx.model), .system, s) }
        XCTAssertEqual(openedBox.all.map(\.absoluteString), links)
        XCTAssertTrue(refused.isEmpty)
        // Explicit Open in Browser: SharePoint / Outlook pages the user asked for.
        TeamsLinkRouter.openInBrowser(u("https://outlook.office.com/calendar/item/AAMkFAKE"))
        XCTAssertEqual(openedBox.all.count, links.count + 1)
    }

    func testRefusalAlertOffersCopyLink() {
        let a = TeamsLinkUI.refusalAlert(for: u("https://teams.microsoft.com/l/unknownkind/x"))
        XCTAssertEqual(a.buttons.map(\.title), ["OK", "Copy Link"])
        XCTAssertTrue(a.informativeText.contains("Teams"))
    }
}

// Evidence capture for the visual review (LINKGUARD R5): renders the
// error alert off-screen, light and dark, when LINKGUARD_SHOT_DIR is set.
@MainActor
final class TeamsLinkAlertEvidenceTests: XCTestCase {
    func testRenderRefusalAlert() throws {
        guard let dir = ProcessInfo.processInfo.environment["LINKGUARD_SHOT_DIR"] else { return }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let alert = TeamsLinkUI.refusalAlert(for: URL(string: "https://teams.microsoft.com/l/unknownkind/x")!)
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            let view = try XCTUnwrap(alert.window.contentView)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("refusal-alert-\(name).png"))
        }
    }
}
