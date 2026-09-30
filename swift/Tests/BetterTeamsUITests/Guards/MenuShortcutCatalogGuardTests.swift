// MenuShortcutCatalogGuardTests — R8 (REGFIX-B): the menu bar, command by
// command, with every keyboard shortcut. The real menu is built from the
// command catalog and dumped as text (menus cannot be screen-captured);
// any command or shortcut that is added, dropped, renamed or moved fails
// here and must be changed on purpose. Key legend: ^ control, ~ option,
// $ shift, @ command. (A silent shortcut loss - Join Meeting, Saved
// Messages, Sign In - went unseen for days because nothing pinned this.)
import AppKit
import XCTest

@testable import BetterTeamsUI

@MainActor
final class MenuShortcutCatalogGuardTests: XCTestCase {
    /// The built menu bar: "Menu > Item [keys]", nested submenus indented by path.
    static func lines() -> [String] {
        _ = NSApplication.shared
        var out: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    let k = item.keyEquivalent == "\u{8}" ? "\u{232B}" : item.keyEquivalent.uppercased()
                    key = (m.contains(.control) ? "^" : "") + (m.contains(.option) ? "~" : "")
                        + (m.contains(.shift) ? "$" : "") + (m.contains(.command) ? "@" : "") + k
                }
                let name = path + item.title
                if let sub = item.submenu, item.title != "Services" {
                    out.append(name + " >")
                    walk(sub, name + " > ")
                } else {
                    out.append(key.isEmpty ? name : "\(name) [\(key)]")
                }
            }
        }
        walk(MainMenu.build(), "")
        return out
    }

    static let expected: [String] = [
        "Better Teams >",
        "Better Teams > About Better Teams",
        "Better Teams > Settings… [@,]",
        "Better Teams > Status >",
        "Better Teams > Sign In Again… [$@I]",
        "Better Teams > Sign Out…",
        "Better Teams > Services",
        "Better Teams > Hide Better Teams [@H]",
        "Better Teams > Hide Others [~@H]",
        "Better Teams > Show All",
        "Better Teams > Quit Better Teams [@Q]",
        "File >",
        "File > New Chat [@N]",
        "File > Join or Create Team >",
        "File > Create Channel…",
        "File > New Meeting…",
        "File > Join with ID or Link…",
        "File > Meet Now…",
        "File > New Call…",
        "File > New Quick Message… [^@M]",
        "File > Add Web Link…",
        "File > Cancel Meeting…",
        "File > Upload… [@U]",
        "File > Open [@O]",
        "File > Open in Browser",
        "File > Quick Look [@Y]",
        "File > Show in Finder",
        "File > Open Conversation",
        "File > Open in New Window",
        "File > Download",
        "File > Save As…",
        "File > Copy Link",
        "File > Share…",
        "File > Mark as Complete",
        "File > Rename…",
        "File > Move To…",
        "File > Copy To…",
        "File > Delete… [@⌫]",
        "File > Close Window [@W]",
        "Edit >",
        "Edit > Undo [@Z]",
        "Edit > Redo [$@Z]",
        "Edit > Cut [@X]",
        "Edit > Copy [@C]",
        "Edit > Paste [@V]",
        "Edit > Paste and Match Style [~$@V]",
        "Edit > Delete",
        "Edit > Select All [@A]",
        "Edit > Find >",
        "Edit > Find > Find… [@F]",
        "Edit > Find > Search [~@F]",
        "Edit > Find > Find Next [@G]",
        "Edit > Find > Find Previous [$@G]",
        "View >",
        "View > Show Toolbar [~@T]",
        "View > Show Inspector [~@I]",
        "View > Chat [~@1]",
        "View > Files [~@2]",
        "View > Notes [~@3]",
        "View > Filter >",
        "View > Filter Activity >",
        "View > Previous",
        "View > Refresh Library",
        "View > Today",
        "View > Customize Tab Bar…",
        "View > Next",
        "View > Calendar View >",
        "View > Actual Size [@0]",
        "View > Shifts >",
        "View > Shifts > Team >",
        "View > Shifts > Previous Week",
        "View > Shifts > Today",
        "View > Shifts > Next Week",
        "View > Zoom In [@+]",
        "View > Zoom Out [@-]",
        "View > Show Completed Tasks",
        "View > Back [@[]",
        "View > Forward [@]]",
        "View > Reload Page [@R]",
        "View > Stop Loading [@.]",
        "View > More >",
        "View > Enter Full Screen [^@F]",
        "View > Transfers [~@L]",
        "Go >",
        "Go > Activity [@1]",
        "Go > Chat [@2]",
        "Go > Teams [@3]",
        "Go > Calendar [@4]",
        "Go > Calls [@5]",
        "Go > Files [@6]",
        "Go > Pinned App 1 [@7]",
        "Go > Pinned App 2 [@8]",
        "Go > Pinned App 3 [@9]",
        "Go > Apps",
        "Go > Go To… [@K]",
        "Go > Next Unread Chat [~@]",
        "Go > Previous Unread Chat [~@]",
        "Go > Saved Messages [$@S]",
        "Conversation >",
        "Conversation > Mark as Unread [$@U]",
        "Conversation > Pin Chat",
        "Conversation > Mute",
        "Conversation > Snooze >",
        "Conversation > Notifications >",
        "Conversation > Move to Folder >",
        "Conversation > Hide Chat",
        "Conversation > Catch Up",
        "Conversation > Leave Chat…",
        "Conversation > Mark All Activity as Read",
        "Conversation > Block…",
        "Conversation > Mark Item as Read",
        "Conversation > Manage Members…",
        "Conversation > Mark Team as Read",
        "Conversation > Hide Team",
        "Conversation > Copy Team Link",
        "Conversation > Leave Team…",
        "Conversation > Open Channel in New Window",
        "Conversation > Mark Channel as Read",
        "Conversation > Channel Notifications >",
        "Conversation > Move Channel to Section >",
        "Conversation > Pin Channel",
        "Conversation > Hide Channel",
        "Conversation > Edit Channel…",
        "Conversation > Manage Channel…",
        "Conversation > Copy Channel Link",
        "Conversation > Copy Channel Email Address",
        "Conversation > Channel Workflows…",
        "Conversation > Delete Channel…",
        "Call >",
        "Call > Start Audio Call",
        "Call > Start Video Call",
        "Call > Meet Now",
        "Call > Show Call",
        "Call > Call Back",
        "Call > Message",
        "Call > Leave Call [$@H]",
        "Call > Join Meeting [@J]",
        "Call > Copy Join Link",
        "Call > Meeting Details…",
        "Call > Open Meeting in New Window",
        "Call > Mute Microphone [$@M]",
        "Call > Turn Camera On [$@O]",
        "Call > Share Screen… [$@E]",
        "Call > Devices…",
        "Call > Test Call",
        "Call > Add to Speed Dial",
        "Call > Remove from Speed Dial",
        "Call > Remove from Recents",
        "Call > Clear Call History\u{2026}",
        "Window >",
        "Window > Minimize [@M]",
        "Window > Zoom",
        "Window > Bring All to Front",
        "Window > Open Catch Up in New Window",
        "Help >",
        "Help > Better Teams Help [@?]",
    ]

    func testMenuBarCatalogAndShortcutsArePinned() {
        let actual = Self.lines()
        let missing = Set(Self.expected).subtracting(actual).sorted()
        let added = Set(actual).subtracting(Self.expected).sorted()
        XCTAssertTrue(missing.isEmpty && added.isEmpty, "menu bar changed. Removed: \(missing). Added: \(added)")
        XCTAssertEqual(actual, Self.expected, "order changed")
    }

    /// The owner-named shortcuts (REGFIX-B R3/R4), spelled out.
    func testOwnerNamedShortcutsExist() {
        let all = Set(Self.lines())
        for line in ["Call > Join Meeting [@J]", "Go > Saved Messages [$@S]", "Better Teams > Sign In Again\u{2026} [$@I]",
                     "Conversation > Mark as Unread [$@U]", "File > New Quick Message\u{2026} [^@M]"] {
            XCTAssertTrue(all.contains(line), "\(line) missing")
        }
        // Save As keeps no shortcut (it lost \u{21E7}\u{2318}S to Saved Messages); Mark as Read is not in the Conversation menu.
        XCTAssertTrue(all.contains("File > Save As\u{2026}"))
        XCTAssertFalse(all.contains { $0.hasPrefix("Conversation > Mark as Read") })
    }

    func testEveryShortcutIsUnique() {
        var seen: [String: String] = [:]
        for c in CommandCatalog.all where !c.shortcut.isEmpty {
            if let other = seen[c.shortcut] { XCTFail("\(c.id) and \(other) share a shortcut") }
            seen[c.shortcut] = c.id.rawValue
        }
    }
}
