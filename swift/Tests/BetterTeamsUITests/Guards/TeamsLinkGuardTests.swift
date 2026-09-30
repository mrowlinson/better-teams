// TeamsLinkGuardTests — LINKGUARD R4. Owner rule: a Teams / Microsoft 365
// link never opens the browser or the Teams web app; it opens natively or
// is refused with an error. The only code allowed to hand a URL to
// NSWorkspace is `TeamsLinkRouter` (OstMacCore/TeamsLinkRouter.swift);
// every other caller goes through `TeamsLinkRouter.open` /
// `.openInBrowser`, which classify the host.
import Foundation
import XCTest

final class TeamsLinkGuardTests: XCTestCase {
    /// Lines that hand a URL to the system directly.
    static let banned = try! NSRegularExpression(
        pattern: #"NSWorkspace\s*(\.shared|\(\))\s*\.\s*(open|openURL)\b|NSWorkspace\s*(\.shared|\(\))\s*$|=\s*NSWorkspace(\.shared|\(\))\s*;|\bLSOpenCFURLRef\b|/usr/bin/open\b"#)

    /// (line number, text) of banned calls, comments skipped.
    static func violations(in source: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        for (i, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            let code = line.components(separatedBy: " // ").first ?? line
            if banned.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { out.append((i + 1, line)) }
        }
        return out
    }

    func testNoDirectSystemOpenOutsideTheRouter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var bad: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            if url.lastPathComponent == "TeamsLinkRouter.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in Self.violations(in: text) { bad.append("\(url.lastPathComponent):\(n): \(line)") }
        }
        XCTAssertGreaterThan(scanned, 100, "scanner found no sources: wrong path")
        XCTAssertEqual(bad, [], "route URLs through TeamsLinkRouter.open / openInBrowser")
    }

    func testRouterIsTheOneCaller() throws {
        // Control: the router itself does call NSWorkspace, and the scanner sees it.
        let router = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OstMacCore/TeamsLinkRouter.swift")
        let text = try String(contentsOf: router, encoding: .utf8)
        XCTAssertEqual(Self.violations(in: text).count, 1)
    }

    func testScannerFlagsTeamsHostOpens() {
        // Positive controls.
        for src in [#"NSWorkspace.shared.open(URL(string: "https://teams.microsoft.com/l/chat/0/0")!)"#,
                    #"    NSWorkspace.shared.open(url)"#,
                    #"_ = NSWorkspace.shared.openURL(u)"#,
                    #"let w = NSWorkspace(); NSWorkspace().open(u)"#,
                    "NSWorkspace.shared\n    .open(url)",
                    "let ws = NSWorkspace.shared",
                    #"Process().executableURL = URL(fileURLWithPath: "/usr/bin/open")"#] {
            XCTAssertEqual(Self.violations(in: src).count, 1, src)
        }
        // Negative controls.
        for src in ["TeamsLinkRouter.open(url)", "TeamsLinkRouter.openInBrowser(url)",
                    "// NSWorkspace.shared.open(url) is banned", "let openURLFn = x", "store.open(chatID: id)"] {
            XCTAssertEqual(Self.violations(in: src).count, 0, src)
        }
    }
}
