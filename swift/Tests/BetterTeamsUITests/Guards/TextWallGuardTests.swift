// Guard: TEXTWALL — no explanatory text laid out inline in Settings.
// Owner (repeated, 09-29): info text goes ONLY behind (i) buttons, never
// as footers, captions or paragraphs on the page.
// (a) source scan of Settings/ panes: no Text literal over the short-label
//     limit and no multi-sentence Text, footer closures included; positive
//     and negative controls for the scanner;
// (b) the (i) button is a labelled, focusable Button (VoiceOver, keyboard);
// (c) Settings > Apps changes reach every window's host, not just one.
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

enum TextWallScanner {
    /// Longest Text literal allowed inline: labels, values, short statuses.
    static let maxInlineLiteral = 48

    /// String literals on `line`, interpolations removed.
    static func literals(in line: String) -> [String] {
        var out: [String] = []
        let ns = line as NSString
        let re = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range(at: 1))
            s = s.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
            out.append(s)
        }
        return out
    }

    static func isWall(_ literal: String) -> Bool {
        literal.count > maxInlineLiteral
            || literal.range(of: #"[.!?;] +[A-Z]"#, options: .regularExpression) != nil
    }

    /// Findings for one Settings source file. `path` is relative to BetterTeamsUI.
    static func violations(in source: String, path: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let lines = source.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let code = raw.components(separatedBy: "//").first ?? raw
            // A Text( call (its literal may wrap onto the next line), or the
            // first lines of a footer: closure.
            var scan: [String] = []
            if code.contains("Text(") { scan += [code] + (i + 1 < lines.count ? [lines[i + 1]] : []) }
            if code.contains("footer:") { scan += lines[i..<min(lines.count, i + 6)].map { $0 } }
            for l in scan where !l.contains("InfoButton(") && !l.contains("InfoLabel(") && !l.contains("InfoHeader(") {
                for lit in literals(in: l) where isWall(lit) && seen.insert(lit).inserted {
                    out.append("\(path):\(i + 1): inline text \"\(lit.prefix(40))\u{2026}\" (use an (i) button)")
                }
            }
        }
        return out
    }
}

@MainActor
final class TextWallGuardTests: XCTestCase {
    private var settingsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Settings")
    }

    // MARK: (a) scan

    func testNoInlineExplanatoryTextInSettings() throws {
        let files = try FileManager.default.contentsOfDirectory(at: settingsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var found: [String] = []
        var infoUses = 0
        for url in files {
            let src = try String(contentsOf: url, encoding: .utf8)
            found += TextWallScanner.violations(in: src, path: url.lastPathComponent)
            infoUses += src.components(separatedBy: "InfoLabel(").count - 1
            infoUses += src.components(separatedBy: "InfoHeader(").count - 1
        }
        XCTAssertGreaterThan(files.count, 10, "control: scan found the Settings panes")
        XCTAssertGreaterThan(infoUses, 10, "control: the panes use (i) buttons")
        XCTAssertTrue(found.isEmpty, "inline text in Settings:\n" + found.joined(separator: "\n"))
    }

    func testAppsPaneAppliesToEveryHost() throws {
        let src = try String(contentsOf: settingsDir.appendingPathComponent("AppsPane.swift"), encoding: .utf8)
        for direct in ["host.keepInMemory =", "host.unloadIdleApps =", "host.pauseInBackground =", "host.keepAlive =", "host.downloadsFolder ="] {
            XCTAssertFalse(src.contains(direct), "\(direct) reaches only this window's host")
        }
    }

    /// Positive control: walls are flagged. Negative control: labels, short statuses and (i) text pass.
    func testScannerPositiveAndNegativeControls() {
        let footer = """
            } footer: {
                Text("More apps in memory switch faster and use more memory.")
                    .font(.caption)
            }
            """
        XCTAssertEqual(TextWallScanner.violations(in: footer, path: "P.swift").count, 1, "long footer flagged")
        let twoSentences = #"Text("Saved. Try again.").font(.caption)"#
        XCTAssertEqual(TextWallScanner.violations(in: twoSentences, path: "P.swift").count, 1, "two sentences flagged")
        let wrapped = "Text(\n    \"A shortcut that opens a small window to message a recent chat from any app.\")"
        XCTAssertEqual(TextWallScanner.violations(in: wrapped, path: "P.swift").count, 1, "wrapped literal flagged")
        let ok = """
            Toggle("Show in menu bar", isOn: $x)
            Text("Key saved.").font(.caption)
            Text("Rebuilding: \\(p.done) of \\(p.total).")
            InfoLabel(title: "Dock", subject: "the Dock", text: "The Dock shows unread chats plus channels that mention you. It is long.")
            """
        XCTAssertTrue(TextWallScanner.violations(in: ok, path: "P.swift").isEmpty, "labels, statuses and (i) text pass")
    }

    // MARK: (b) accessibility

    /// SwiftUI buttons are not inspectable in an unwindowed hosting view (its
    /// accessibility tree is empty), so this pins the component's source: a
    /// real Button with a spoken label, keyboard-focusable, and the label
    /// every use resolves to.
    func testInfoButtonIsAccessibleButton() throws {
        XCTAssertEqual(InfoButton.label(for: "pausing apps"), "About pausing apps")
        let url = settingsDir.deletingLastPathComponent().appendingPathComponent("Shared/InfoButton.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let button = try XCTUnwrap(src.range(of: "struct InfoButton"))
        let body = String(src[button.lowerBound...].prefix(1200))
        XCTAssertTrue(body.contains("Button {"), "a real Button, so VoiceOver and Full Keyboard Access act on it")
        XCTAssertTrue(body.contains(".accessibilityLabel(Self.label(for: subject))"), "spoken label")
        XCTAssertTrue(body.contains(".focusable()"), "keyboard focusable")
        XCTAssertTrue(body.contains(".help(Self.label(for: subject))"), "tooltip matches")
        XCTAssertFalse(body.contains(".accessibilityHidden(true)"), "never hidden from VoiceOver")
    }

    // MARK: (c) every window's host

    func testForEachHostReachesAllWindows() {
        let a = FrameHost(accountKey: "demo")
        let b = FrameHost(accountKey: "demo")
        FrameHost.forEachHost { $0.keepInMemory = 6; $0.unloadIdleApps = false; $0.pauseInBackground = false }
        XCTAssertEqual([a.keepInMemory, b.keepInMemory], [6, 6])
        XCTAssertEqual([a.unloadIdleApps, b.unloadIdleApps], [false, false])
        XCTAssertEqual([a.pauseInBackground, b.pauseInBackground], [false, false])
        FrameHost.forEachHost { $0.keepAlive = 5 * 60 }
        XCTAssertEqual([a.keepAlive, b.keepAlive], [300, 300])
    }
}
