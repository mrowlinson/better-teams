// MeetLocalGuardTests — C2a local-only meeting controls (meetlocal-a):
// layout resolve, captions buffer, on-device background-blur math,
// and native-control labels for the new surfaces. No camera, no mic,
// no network: the Vision call only ever sees synthetic images here,
// and the live Speech engine is never constructed in tests.
import AppKit
import CoreImage
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class MeetLocalGuardTests: XCTestCase {
    // MARK: layout

    func testAutomaticMirrorsTheOldGridSpotlightRule() {
        let auto = MeetingLayoutMode.automatic
        XCTAssertFalse(auto.resolve(pinnedID: nil, shareUp: false, demoPresenting: false))
        XCTAssertTrue(auto.resolve(pinnedID: "p1", shareUp: false, demoPresenting: false))
        XCTAssertTrue(auto.resolve(pinnedID: nil, shareUp: true, demoPresenting: false))
        XCTAssertTrue(auto.resolve(pinnedID: nil, shareUp: false, demoPresenting: true))
    }

    func testExplicitModesIgnoreTheStage() {
        XCTAssertFalse(MeetingLayoutMode.grid.resolve(pinnedID: "p1", shareUp: true, demoPresenting: true))
        XCTAssertTrue(MeetingLayoutMode.spotlight.resolve(pinnedID: nil, shareUp: false, demoPresenting: false))
    }

    func testLayoutPickerListsThreeTitledModes() {
        XCTAssertEqual(MeetingLayoutMode.allCases.map(\.title), ["Automatic", "Grid", "Spotlight"])
    }

    // MARK: captions

    func testCaptionsAppendKeepsOrderAndDropsBlanks() {
        var log = LiveCaptionsLog()
        log.append("  ")
        log.append("Ava Lindqvist: Thursday works.")
        log.append("Marco Chen: QA signs off.", isFinal: false)
        XCTAssertEqual(log.lines.map(\.text),
                       ["Ava Lindqvist: Thursday works.", "Marco Chen: QA signs off."])
        XCTAssertEqual(log.recent.count, 2)
        XCTAssertEqual(log.recent.last?.isFinal, false)
    }

    func testCaptionsCapAtFiftyAndShowTheNewestThree() {
        var log = LiveCaptionsLog()
        for i in 0..<55 { log.append("line \(i)") }
        XCTAssertEqual(log.lines.count, LiveCaptionsLog.maxLines)
        XCTAssertEqual(log.lines.first?.text, "line 5")
        XCTAssertEqual(log.lines.last?.text, "line 54")
        XCTAssertEqual(log.recent.map(\.text), ["line 52", "line 53", "line 54"])
        log.clear()
        XCTAssertTrue(log.lines.isEmpty)
    }

    // MARK: blur (synthetic frames only)

    func testCompositeKeepsThePersonAndBlursTheBackground() {
        let size = 64
        let frame = Self.personOnChecker(size: size)
        let mask = Self.halfMask(size: size)
        guard let out = PersonBackgroundBlur.composite(frame, mask: mask, radius: 8) else {
            XCTFail("composite of a synthetic frame with a synthetic mask")
            return
        }
        XCTAssertEqual(out.width, size)
        XCTAssertEqual(out.height, size)
        // Person half (left): untouched. Sample well inside, away from the edge.
        XCTAssertEqual(Self.pixel(out, x: size / 4, y: size / 2).0, 255, accuracy: 3)
        // Background half (right): the checker variance blurs down.
        XCTAssertLessThan(Self.variance(out, x0: size / 2, y0: 0, w: size / 2, h: size),
                          Self.variance(frame, x0: size / 2, y0: 0, w: size / 2, h: size))
    }

    func testCoverageGateRejectsPersonlessFrames() {
        // Black mask: no person. White mask: all person. Half: half.
        XCTAssertEqual(PersonBackgroundBlur.coverage(of: Self.solidMask(white: false)), 0, accuracy: 0.01)
        XCTAssertEqual(PersonBackgroundBlur.coverage(of: Self.solidMask(white: true)), 1, accuracy: 0.01)
        let half = PersonBackgroundBlur.coverage(of: Self.halfMask(size: 32))
        XCTAssertGreaterThan(half, 0.3)
        XCTAssertLessThan(half, 0.7)
        // A solid-black frame has no person: the pipeline yields nil so
        // the caller shows it unblurred, never fully blurred.
        XCTAssertNil(PersonBackgroundBlur.blurredBackground(Self.solid(size: 64, white: false)))
    }

    func testVisionPipelineNeverCrashesAndKeepsTheSize() {
        // A cartoon has no person: Vision returns nil (fallback path) or a
        // same-size image. Either is correct; the test pins no-crash.
        let frame = Self.checker(size: 64)
        let out = PersonBackgroundBlur.blurredBackground(frame)
        if let out {
            XCTAssertEqual(out.width, frame.width)
            XCTAssertEqual(out.height, frame.height)
        }
    }

    // MARK: native controls (source pins, per NATIVEUI)

    func testNewSurfacesUseNativeControlsWithStableLabels() {
        let dir = Self.sourcesURL
        let stage = Self.read("Call/MeetingVideoStage.swift", under: dir)
        XCTAssertTrue(stage.contains("Picker(\"Layout\""), "layout picker label")
        XCTAssertTrue(stage.contains(".pickerStyle(.segmented)"), "segmented, never web-look tabs")
        XCTAssertTrue(stage.contains("Toggle(\"Live Captions\""), "captions toggle label")
        let prejoin = Self.read("Call/PreJoinView.swift", under: dir)
        XCTAssertTrue(prejoin.contains("Toggle(\"Blur Background\""), "prejoin blur toggle label")
        XCTAssertTrue(prejoin.contains(".toggleStyle(.switch)"), "native switch")
        let tile = Self.read("Call/CallStageViewController.swift", under: dir)
        XCTAssertTrue(tile.contains("Toggle(\"Blur Background\""), "self-tile context menu item")
    }

    // MARK: helpers

    /// Solid opaque frame (no features, no person).
    private static func solid(size: Int, white: Bool) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: white ? 1 : 0, green: white ? 1 : 0, blue: white ? 1 : 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// Solid mask: opaque white (all person) or opaque black (none).
    private static func solidMask(white: Bool, size: Int = 32) -> CIImage {
        CIImage(cgImage: solid(size: size, white: white))
    }

    private static var sourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private static func read(_ name: String, under dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Solid white left half (the person), checker right half (the room).
    private static func personOnChecker(size: Int, cell: Int = 8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let white = ((x + y) / cell) % 2 == 0 || x < size / 2
                ctx.setFillColor(CGColor(red: white ? 1 : 0, green: white ? 1 : 0, blue: white ? 1 : 0, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// Black/white checker (high-frequency background).
    private static func checker(size: Int, cell: Int = 8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let white = ((x + y) / cell) % 2 == 0
                ctx.setFillColor(CGColor(red: white ? 1 : 0, green: white ? 1 : 0, blue: white ? 1 : 0, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// Left opaque white (person), right transparent black (background):
    /// foreground under either luminance or alpha mask reading.
    private static func halfMask(size: Int) -> CIImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size - size / 2, height: size))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// (red, green, blue) of one pixel.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let data = NSMutableData(length: 4)!
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: data.mutableBytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        let b = data.bytes.assumingMemoryBound(to: UInt8.self)
        return (CGFloat(b[0]), CGFloat(b[1]), CGFloat(b[2]))
    }

    /// Luminance variance over a rect (blur lowers it on texture).
    private static func variance(_ image: CGImage, x0: Int, y0: Int, w: Int, h: Int) -> Double {
        var sum = 0.0, sum2 = 0.0, n = 0.0
        var y = y0
        while y < y0 + h {
            var x = x0
            while x < x0 + w {
                let p = pixel(image, x: x, y: y)
                let l = Double(p.0 + p.1 + p.2) / (3 * 255)
                sum += l
                sum2 += l * l
                n += 1
                x += 2
            }
            y += 2
        }
        let mean = sum / n
        return sum2 / n - mean * mean
    }
}
