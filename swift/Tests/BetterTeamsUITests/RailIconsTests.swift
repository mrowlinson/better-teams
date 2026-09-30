// RailIconsTests.swift — APPNATIVE6-UI.
// R11: pinned catalog apps show their own manifest icon in the rail, from
// a cache that answers on the first draw (next launch included) and
// fetches only on a miss.
// R12: the selected rail label is never lighter than the unselected ones,
// in a key-appearance window and an inactive one. The XCTest process is
// never active (as a capture with the app not activated), where SwiftUI
// resolves `.tint` to an unemphasized gray even with
// `controlActiveState == .key`.
// Nothing goes on screen: windows are never ordered in, the app is never
// activated.
import AppKit
import SwiftUI
import XCTest
@testable import BetterTeamsUI
import OstMacCore

@MainActor
final class RailIconsTests: XCTestCase {
    // MARK: R12

    func testSelectedLabelIsNeverLighterThanUnselected() {
        for key in [true, false] {
            let sel = labelInk(RailButtonLabel(title: "Apps", symbol: "folder", badge: nil), selected: true, key: key)
            let unsel = labelInk(RailButtonLabel(title: "Files", symbol: "folder", badge: nil), selected: false, key: key)
            XCTAssertLessThan(unsel, 0.35, "control: unselected label draws dark (key \(key)): \(unsel)")
            XCTAssertLessThanOrEqual(sel, unsel + 0.1, "selected label lighter than unselected (key \(key)): \(sel) vs \(unsel)")
        }
    }

    /// Negative control: a `.tint` label (the old selected foreground) in
    /// this inactive process draws gray even with `.key`, and the check
    /// above would flag it.
    func testTintLabelControlIsCaught() {
        let tint = labelInk(Text("Apps").font(.subheadline).foregroundStyle(.tint)
            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 6), selected: true, key: true)
        let unsel = labelInk(RailButtonLabel(title: "Files", symbol: "folder", badge: nil), selected: false, key: true)
        XCTAssertGreaterThan(tint, unsel + 0.1, "harness sees the unemphasized tint: \(tint) vs \(unsel)")
    }

    /// Darkest luminance (over white) in the label band of one 54 pt rail
    /// button.
    private func labelInk<L: View>(_ label: L, selected: Bool, key: Bool) -> Double {
        let button = Button {} label: { label }
            .buttonStyle(RailButtonStyle(selected: selected, height: 54))
            .transformEnvironment(\.controlActiveState) { if key { $0 = .key } }
        let rep = render(button, size: NSSize(width: RailModel.itemWidth, height: 54))
        var ink = 1.0
        for y in 34..<51 { for x in 6..<Int(RailModel.itemWidth) - 6 { ink = min(ink, lum(rep, x, y)) } }
        return ink
    }

    // MARK: Rail symbol contrast (CALDETAIL T3)

    /// Unselected rail symbols were nearly invisible in light mode
    /// (`.secondary` in the rail's vibrant sidebar pane): the symbol must be
    /// at least as dark as its own label text, in vibrant and plain light.
    func testUnselectedSymbolIsAsDarkAsItsLabel() {
        for name in [NSAppearance.Name.vibrantLight, .aqua] {
            let (symbol, text) = inks(RailButtonLabel(title: "Files", symbol: "folder", badge: nil), appearance: name)
            XCTAssertLessThan(text, 0.6, "control: label text measured (\(name.rawValue)): \(text)")
            XCTAssertLessThanOrEqual(symbol, text + 0.05, "symbol lighter than its label (\(name.rawValue)): \(symbol) vs \(text)")
        }
    }

    /// Controls: an invisible symbol measures light; the old `.secondary`
    /// symbol measures lighter than its label, so the check above flags it.
    func testSymbolInkControls() {
        let clear = inks(VStack(spacing: 3) {
            Image(systemName: "folder").font(.title2).foregroundStyle(.clear).frame(height: 24)
            Text("Files").font(.subheadline)
        }, appearance: .aqua)
        XCTAssertGreaterThan(clear.symbol, 0.95, "invisible symbol: \(clear)")
        let old = inks(VStack(spacing: 3) {
            Image(systemName: "folder").font(.title2).foregroundStyle(.secondary).frame(height: 24)
            Text("Files").font(.subheadline)
        }, appearance: .aqua)
        XCTAssertGreaterThan(old.symbol, old.text + 0.05, "old .secondary symbol: \(old)")
    }

    /// Darkest luminance in the symbol band and the label band of one
    /// unselected 54 pt rail button.
    private func inks<L: View>(_ label: L, appearance: NSAppearance.Name) -> (symbol: Double, text: Double) {
        let button = Button {} label: { label }
            .buttonStyle(RailButtonStyle(selected: false, height: 54))
        let rep = render(button, size: NSSize(width: RailModel.itemWidth, height: 54), appearance: appearance)
        var symbol = 1.0, text = 1.0
        for x in 6..<Int(RailModel.itemWidth) - 6 {
            for y in 4..<30 { symbol = min(symbol, lum(rep, x, y)) }
            for y in 34..<51 { text = min(text, lum(rep, x, y)) }
        }
        return (symbol, text)
    }

    // MARK: R11

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterTeamsTest/RailIcons-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private nonisolated static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private nonisolated static func png(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func manifest(_ id: String, icon: String?) -> TeamsAppManifest {
        var m = TeamsAppManifest(id: id, name: id, staticTabs: [])
        m.colorIcon = icon
        return m
    }

    func testCatalogIconCachedOnDiskAnswersFirstDrawWithoutNetwork() async {
        let dir = tempDir()
        let url = URL(string: "https://cdn.example.com/icons/red.png")!
        let red = Self.png(Self.red)
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let first = AppIconCache(directory: dir) { _ in count.n += 1; return red }
        first.register([manifest("ABC", icon: url.absoluteString), manifest("Plain", icon: "http://x/y.png"),
                        manifest("None", icon: nil)],
                       appID: AppsLibrary.appID(forCatalogApp:))
        XCTAssertEqual(first.url(for: SectionID.web("ta.abc")), url)
        XCTAssertNil(first.url(for: FrameAppID("ta.plain")), "non-https icons are never fetched")
        XCTAssertNil(first.url(for: FrameAppID("ta.none")))
        XCTAssertNil(first.url(for: SectionID.apps), "built-ins keep their symbols")
        XCTAssertNil(first.image(url), "nothing cached yet")
        await first.load(url)
        await first.load(url)
        XCTAssertEqual(count.n, 1, "fetched once")
        XCTAssertNotNil(first.image(url))

        // Next launch: a fresh cache on the same folder answers
        // synchronously and never fetches.
        let next = AppIconCache(directory: dir) { _ in XCTFail("cached icon refetched"); return nil }
        XCTAssertNotNil(next.image(url), "disk hit on first lookup")
        await next.load(url)
    }

    /// The rail button draws the cached icon on its very first render (no
    /// run loop turn, no task), not the symbol.
    func testRailLabelDrawsCachedIconOnFirstRender() async {
        let url = URL(string: "https://cdn.example.com/icons/rail-\(UUID().uuidString).png")!
        let seeded = AppIconCache(directory: AppIconCache.defaultDirectory()) { _ in Self.png(Self.red) }
        await seeded.load(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: AppIconCache.defaultDirectory()) }
        XCTAssertTrue(AppIconCache.defaultDirectory().path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "tests never write the user's caches")
        let label = RailButtonLabel(title: "Red", symbol: "square.grid.2x2", badge: nil, icon: url)
        let view = Button {} label: { label }.buttonStyle(RailButtonStyle(selected: false, height: 54))
        let rep = render(view, size: NSSize(width: RailModel.itemWidth, height: 54), settle: false)
        var redPixels = 0
        for y in 0..<34 { for x in 0..<Int(RailModel.itemWidth) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.7, c.greenComponent < 0.35, c.blueComponent < 0.35, c.alphaComponent > 0.9 { redPixels += 1 }
        } }
        XCTAssertGreaterThan(redPixels, 200, "icon drawn on first render: \(redPixels) red px")
    }

    func testDemoRegistersNoIcons() {
        let before = AppIconCache.shared.urls
        _ = AppsLibrary(accountKey: "demo")
        XCTAssertEqual(AppIconCache.shared.urls, before, "demo never registers icons (no network)")
    }

    // MARK: helpers

    /// Renders `view` in a borderless window that is never ordered in.
    private func render<V: View>(_ view: V, size: NSSize, settle: Bool = true,
                                 appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if settle { RunLoop.current.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        // Point → pixel rows/columns in the flipped host (top-left origin).
        let scale = Double(rep.pixelsWide) / size.width
        if scale == 1 { return rep }
        let one = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: one)
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return one
    }

    private func lum(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
        let a = c.alphaComponent
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l * a + (1 - a)
    }
}
