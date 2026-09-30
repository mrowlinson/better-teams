// CalendarDetailGuardTests.swift — CALDETAIL R5: the calendar details
// stay macOS-native (owner 09-29: "every other surface must be macos
// native ui deisgn compliant").
// Source scans of Sections/Calendar: `.buttonStyle(.link)` only on a real
// link (the Teams join link), never on an action; no fake window-title
// strip in the sheet; the details commands are native toolbar items /
// control groups. Behavior: suggestions rank a zero-conflict slot first,
// the Tracking organizer row says "(You)", the instances sheet starts on
// the opened occurrence. Nothing goes on screen.
import SwiftUI
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

enum CalendarDetailScanner {
    /// Link-styled buttons whose target is a real link (label, reason).
    static let realLinks: [(label: String, reason: String)] = [
        ("Join the meeting now", "the invitation's Teams join link"),
    ]

    /// `.buttonStyle(.link)` not within 4 lines after a real-link label or a `Link(`.
    static func linkStyleViolations(in source: String, path: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            guard code.contains(".buttonStyle(.link)") else { continue }
            let before = lines[max(0, i - 4)...i].joined(separator: "\n")
            let real = before.contains("Link(") || realLinks.contains { before.contains("\"\($0.label)\"") }
            if !real { out.append("\(path):\(i + 1): link-styled action (use .bordered .controlSize(.small))") }
        }
        return out
    }

    /// A sheet title strip: a caption title row with its own close/pop-out glyphs.
    static func titleStripViolations(in source: String, path: String) -> [String] {
        var out: [String] = []
        for (i, line) in source.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            if code.contains("titleRow(") { out.append("\(path):\(i + 1): titleRow") }
            if code.contains("Image(systemName: \"xmark\")") { out.append("\(path):\(i + 1): xmark close glyph") }
            if code.contains("EventDetailsWindowController.title(") {
                out.append("\(path):\(i + 1): window title drawn in content")
            }
        }
        return out
    }
}

@MainActor
final class CalendarDetailGuardTests: XCTestCase {
    private var calendarDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Sections/Calendar")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: calendarDir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: source scans

    func testLinkStyleOnlyOnRealLinks() throws {
        let files = try FileManager.default.contentsOfDirectory(at: calendarDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "control: scan found the calendar sources")
        var found: [String] = []
        var links = 0
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            links += text.components(separatedBy: ".buttonStyle(.link)").count - 1
            found += CalendarDetailScanner.linkStyleViolations(in: text, path: url.lastPathComponent)
        }
        XCTAssertGreaterThan(links, 0, "control: the join link is still link-styled")
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    func testLinkScannerControls() {
        let action = """
        Button("Copy link") { copy() }
            .buttonStyle(.link)
        """
        XCTAssertEqual(CalendarDetailScanner.linkStyleViolations(in: action, path: "x").count, 1, "positive control")
        let join = """
        Button("Join the meeting now") {
            close()
            join()
        }
        .buttonStyle(.link)
        """
        XCTAssertTrue(CalendarDetailScanner.linkStyleViolations(in: join, path: "x").isEmpty, "negative control")
    }

    func testNoFakeTitleStripInDetails() throws {
        let found = CalendarDetailScanner.titleStripViolations(in: try source("CalendarDetails.swift"),
                                                                path: "CalendarDetails.swift")
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
        let strip = """
        HStack { Text(EventDetailsWindowController.title(m)); Button(action: close) { Image(systemName: "xmark") } }
        """
        XCTAssertEqual(CalendarDetailScanner.titleStripViolations(in: strip, path: "x").count, 2, "positive control")
    }

    func testSheetHasOpenInNewWindowAndCloseBottomBar() throws {
        let s = try source("CalendarDetails.swift")
        XCTAssertTrue(s.contains("Button(\"Open in New Window\")"))
        XCTAssertTrue(s.contains("Button(\"Close\", action: close)\n                        .keyboardShortcut(.cancelAction)"))
    }

    func testDetailsCommandsAreNativeToolbarAndControlGroups() throws {
        let tb = try source("CalendarDetailToolbar.swift")
        for needle in ["struct EventDetailsWindowToolbar: ToolbarContent", "ToolbarItemGroup(placement:",
                       "ControlGroup {", ".menuStyle(.button)", ".buttonStyle(.bordered)", "\"sidebar.trailing\""] {
            XCTAssertTrue(tb.contains(needle), "CalendarDetailToolbar.swift lacks \(needle)")
        }
        for banned in [".menuStyle(.borderlessButton)", ".buttonStyle(.borderless)"] {
            XCTAssertFalse(tb.contains(banned), "CalendarDetailToolbar.swift uses \(banned)")
        }
        XCTAssertTrue(try source("CalendarDetails.swift").contains(".toolbar {\n                            EventDetailsWindowToolbar("))
        XCTAssertTrue(try source("CalendarDetailWindow.swift").contains("bridging: [.toolbars]"),
                      "the details window bridges SwiftUI toolbar items to its NSToolbar")
    }

    func testNoCapsuleChromeInDetails() throws {
        for name in ["CalendarDetails.swift", "CalendarDetailToolbar.swift", "CalendarAttendeeChips.swift"] {
            XCTAssertFalse(try source(name).contains("Capsule("), name)
        }
    }

    // MARK: behavior

    /// MF7: a zero-conflict slot ranks first even when a conflicted one is earlier.
    func testSuggestionsRankEveryoneFreeFirst() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 30)))  // Wednesday
        func at(_ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day)! }
        let busy = CalendarFreeBusy(email: "a@example.com", blocks: [.init(status: "busy", start: at(8), end: at(14))])
        let other = CalendarFreeBusy(email: "b@example.com", blocks: [])
        let ranked = CalendarFreeBusy.rankedSuggestions([busy, other], from: at(8), to: at(18), length: 5400,
                                                        hours: 8 ..< 17, calendar: cal)
        let first = try XCTUnwrap(ranked.first)
        XCTAssertTrue(first.conflicts.isEmpty, "zero-conflict slot first: \(ranked)")
        XCTAssertEqual(first.slot.start, at(14))
        XCTAssertTrue(ranked.allSatisfy { $0.slot.end <= at(17) }, "all in working hours")
    }

    func testTrackingOrganizerSaysYou() {
        let mine = MeetingItem(meetingId: "o", subject: "Mine", organizer: "Jordan Fox",
                               organizerEmail: "jordan@example.com", isOrganizer: true)
        let theirs = MeetingItem(meetingId: "t", subject: "Theirs", organizer: "Luis Ortega",
                                 organizerEmail: "luis@example.com", isOrganizer: false)
        XCTAssertEqual(CalendarDetailsText.organizerLabel(mine), "Jordan Fox (You)")
        XCTAssertEqual(CalendarDetailsText.organizerLabel(theirs), "Luis Ortega")
        XCTAssertNil(CalendarDetailsText.organizerLabel(MeetingItem(meetingId: "n", subject: "None")))
    }

    func testInstancesSheetStartsOnOpenedOccurrence() {
        let rows = ["2026-09-21", "2026-09-28", "2026-10-05"].enumerated().map { i, d in
            MeetingItem(meetingId: "i\(i)", subject: "Standup", utcStart: d + "T09:00:00")
        }
        let now = CalendarTime.instant("2026-09-30T12:00:00")!
        XCTAssertEqual(EventInstancesSheet.focusID(rows, openedFrom: "i1", now: now), "i1", "opened occurrence wins")
        XCTAssertEqual(EventInstancesSheet.focusID(rows, openedFrom: nil, now: now), "i2", "else first from now")
        XCTAssertEqual(EventInstancesSheet.focusID(rows, openedFrom: "gone", now: now), "i2")
    }

    func testRSVPPopUpShowsCurrentResponse() {
        XCTAssertEqual(EventRespondControl.title(.accepted), RSVPResponse.accepted.label)
        XCTAssertEqual(EventRespondControl.title(.notResponded), "Respond")
    }

    /// Owner-visible window toolbar (r3 approval W1-W4): the RSVP pop-up shows its
    /// value (HStack label: an NSToolbar drops a Label's title), the secondary
    /// commands fold into one "More" pull-down so nothing overflows into ">>",
    /// the window title is the event subject, and only the toolbar toggles Tracking.
    func testWindowToolbarShowsRSVPFoldsMoreTitleAndSingleTrackingToggle() throws {
        let bar = try source("CalendarDetailToolbar.swift")
        XCTAssertTrue(bar.contains("Label(Self.title(info.myResponse), systemImage: CalendarDetailsText.responseSymbol(info.myResponse))\n                }\n                // Applied to the Menu itself (as on Edit): an NSToolbar item keeps the title only then.\n                .labelStyle(.titleAndIcon)"),
                      "RSVP pop-up titled with the current response; labelStyle on the Menu so the toolbar keeps the title")
        let window = try XCTUnwrap(bar.range(of: "struct EventDetailsWindowToolbar"))
        let end = try XCTUnwrap(bar.range(of: "struct EventTrackingToggle"))
        let body = String(bar[window.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("EventMoreMenu("), "window toolbar folds personal/files into More")
        XCTAssertFalse(body.contains("EventPersonalGroup(") || body.contains("EventFilesGroup("), "no unfolded groups in window toolbar")
        let win = try source("CalendarDetailWindow.swift")
        XCTAssertTrue(win.contains("?.subject"), "window title = subject")
        XCTAssertFalse(win.contains("Event instance"), "no generic Event - Calendar title")
        let tracking = try source("CalendarTracking.swift")
        XCTAssertFalse(tracking.contains("sidebar.trailing"), "Tracking header has no second inspector toggle")
        XCTAssertTrue(bar.contains("sidebar.trailing"), "toolbar toggle stays")
    }
}
