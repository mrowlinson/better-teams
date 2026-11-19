// PraiseGuardTests — PRAISE lane guards.
//
// (a) The Praise composer entry is native chrome: the strip keeps its
//     vertical shape, the popover content uses only native controls
//     (source scan of the two new view files — no Capsule chrome, no
//     custom tabs, no brand palette).
// (b) The evidence route `popover=praise` opens the Praise composer.
// (c) Every badge glyph resolves to a real SF Symbol (headless-safe:
//     no window, image lookup only) and the catalog stays at ten.
import AppKit
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class PraiseGuardTests: XCTestCase {
    private var uiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private func source(_ rel: String) -> String {
        // swiftlint:disable:next force_try
        try! String(contentsOf: uiDir.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The Praise strip button lives in the vertical leading strip and
    /// the popover slot renders the native Praise composer.
    func testPraiseEntryIsNativeStripAndPopover() {
        let composer = source("Conversation/Composer.swift")
        XCTAssertTrue(composer.contains("\"medal\""), "strip carries a Praise medal button")
        XCTAssertTrue(composer.contains("ComposerPopover.praise") || composer.contains(".praise"),
                      "strip opens the praise popover")
        let popovers = source("Conversation/ComposerPopovers.swift")
        XCTAssertTrue(popovers.contains("PraiseComposer"), "popover slot renders PraiseComposer")
    }

    /// The two new views use native controls only.
    func testPraiseViewsUseNativeControlsOnly() {
        for rel in ["Conversation/PraiseComposer.swift", "Timeline/PraiseCardView.swift"] {
            let src = source(rel)
            let code = src.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }
            for (i, line) in code.enumerated() {
                XCTAssertFalse(line.contains("Capsule("), "\(rel):\(i + 1): Capsule chrome")
                XCTAssertFalse(line.contains("UnderlineTab") || line.contains("TabStrip"),
                               "\(rel):\(i + 1): custom tab chrome")
                XCTAssertFalse(line.contains("foregroundColor("), "\(rel):\(i + 1): foregroundColor (use foregroundStyle)")
            }
        }
    }

    /// `popover=praise` opens the Praise composer (captures drive it).
    func testPraiseEvidenceRoute() {
        XCTAssertEqual(ChatCommands.praisePopover, "praise")
        let p = ComposerPopover(evidenceName: "praise", lastMessageID: nil)
        XCTAssertEqual(p, .praise)
        XCTAssertEqual(p?.id, "praise")
    }

    /// Ten badges, unique wire tokens, every glyph a real symbol.
    func testBadgeCatalogStaysAtTenWithRealSymbols() {
        XCTAssertEqual(PraiseBadge.allCases.count, 10)
        XCTAssertEqual(Set(PraiseBadge.allCases.map(\.wireToken)).count, 10)
        for b in PraiseBadge.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.displayName),
                            "missing SF Symbol \(b.symbol) for \(b.displayName)")
        }
    }
}
