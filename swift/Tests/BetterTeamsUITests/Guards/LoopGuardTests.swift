// LoopGuardTests — LOOPBUILD lane guards.
//
// (a) The Loop composer entry is native chrome: the strip keeps its
//     shape, the popover content uses only native controls (source
//     scan of the new view files — no Capsule chrome, no custom
//     tabs, no brand palette).
// (b) The evidence route `popover=loop` opens the Loop composer,
//     and `?seed=loop` stages a minable component message.
// (c) Every kind glyph resolves to a real SF Symbol
//     (headless-safe: no window, image lookup only) and the
//     catalog stays at eleven.
import AppKit
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class LoopGuardTests: XCTestCase {
    private var uiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private func source(_ rel: String) -> String {
        // swiftlint:disable:next force_try
        try! String(contentsOf: uiDir.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The Loop strip button opens the loop popover, and the
    /// popover slot renders the native Loop composer.
    func testLoopEntryIsNativeStripAndPopover() {
        let composer = source("Conversation/Composer.swift")
        XCTAssertTrue(composer.contains("\"infinity\""), "strip carries a Loop button")
        XCTAssertTrue(composer.contains("ComposerPopover.loop") || composer.contains(".loop"),
                      "strip opens the loop popover")
        let popovers = source("Conversation/ComposerPopovers.swift")
        XCTAssertTrue(popovers.contains("LoopComposer"), "popover slot renders LoopComposer")
    }

    /// The new views use native controls only.
    func testLoopViewsUseNativeControlsOnly() {
        for rel in ["Conversation/LoopComposer.swift", "Timeline/LoopComponentView.swift"] {
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

    /// `popover=loop` opens the Loop composer (captures drive it).
    func testLoopEvidenceRoute() {
        XCTAssertEqual(ChatCommands.loopPopover, "loop")
        let p = ComposerPopover(evidenceName: "loop", lastMessageID: nil)
        XCTAssertEqual(p, .loop)
        XCTAssertEqual(p?.id, "loop")
    }

    /// `?seed=loop` is documented and stages one minable message.
    func testLoopSeedStagesMinableMessage() {
        let evidence = source("Conversation/ConversationEvidence.swift")
        XCTAssertTrue(evidence.contains("seed=reply,edit,attach,typing,pending,scheduled,delete,pins,rich,share,praise,poll,loop"),
                      "seed list documents loop")
        XCTAssertTrue(evidence.contains("DemoData.loopSeeds()"), "evidence ingests loop seeds")
        let seeds = DemoData.loopSeeds()
        XCTAssertEqual(seeds.count, 1)
        XCTAssertNotNil(LoopComponent.first(fromCards: seeds[0].loopCards), "seed mines a Loop embed")
    }

    /// Eleven kinds, unique ids, every glyph a real symbol.
    func testKindCatalogStaysAtElevenWithRealSymbols() {
        XCTAssertEqual(LoopComponent.kinds.count, 11)
        XCTAssertEqual(Set(LoopComponent.kinds.map(\.id)).count, 11)
        for k in LoopComponent.kinds {
            XCTAssertNotNil(NSImage(systemSymbolName: k.symbol, accessibilityDescription: k.displayName),
                            "missing SF Symbol \(k.symbol) for \(k.displayName)")
        }
        XCTAssertNotNil(NSImage(systemSymbolName: "infinity", accessibilityDescription: "Loop"),
                        "missing strip symbol infinity")
    }

    /// The gate ships closed with a reason (live proof is phase 2).
    func testGateShipsClosedWithReason() {
        let saved = LoopGate.probe
        defer { LoopGate.probe = saved }
        LoopGate.probe = { .disabled(reason: LoopGate.defaultReason) }
        XCTAssertFalse(LoopGate.isLive)
        XCTAssertFalse(LoopGate.defaultReason.isEmpty)
    }
}
