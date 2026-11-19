// MeetBgReplaceGuardTests — MEETBGFX: background replace on the self view
// (gallery + custom) next to meetlocal-a's blur. No camera, no mic, no
// network: Vision only ever sees synthetic images here, and the live
// engine is never constructed in tests.
import AppKit
import CoreImage
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class MeetBgReplaceGuardTests: XCTestCase {
    // MARK: effect value semantics

    func testEffectChoiceSlotsAndTitles() {
        XCTAssertEqual(BackgroundEffect.off.choice, 0)
        XCTAssertEqual(BackgroundEffect.blur.choice, 1)
        XCTAssertEqual(BackgroundEffect.replace(.office).choice, 2)
        XCTAssertEqual(BackgroundEffect.custom.choice, 2)
        XCTAssertEqual(BackgroundEffect.off.title, "Off")
        XCTAssertEqual(BackgroundEffect.blur.title, "Blur")
        XCTAssertEqual(BackgroundEffect.replace(.dune).title, "Dune")
        XCTAssertEqual(BackgroundEffect.custom.title, "Custom")
        XCTAssertFalse(BackgroundEffect.off.isOn)
        XCTAssertTrue(BackgroundEffect.blur.isOn)
        XCTAssertFalse(BackgroundEffect.blur.isReplace)
        XCTAssertTrue(BackgroundEffect.replace(.cove).isReplace)
        XCTAssertTrue(BackgroundEffect.custom.isReplace)
    }

    func testGalleryRoundTrip() {
        XCTAssertEqual(BuiltInBackground.allCases.map(\.title), ["Office", "Cove", "Dune", "Atrium"])
        XCTAssertEqual(BackgroundEffect.replace(.atrium).gallery, .atrium)
        XCTAssertNil(BackgroundEffect.blur.gallery)
        XCTAssertNil(BackgroundEffect.custom.gallery)
        XCTAssertNil(BackgroundEffect.off.gallery)
    }

    // MARK: replace composite (synthetic frames only)

    func testCompositeReplaceKeepsThePersonAndSwapsTheBackground() {
        let size = 64
        let frame = Self.personOnChecker(size: size)
        let mask = Self.halfMask(size: size)
        guard let teal = PersonBackgroundBlur.solidImage(red: 0.15, green: 0.45, blue: 0.55, size: size) else {
            XCTFail("gallery stand-in image")
            return
        }
        guard let out = PersonBackgroundBlur.compositeReplace(frame, mask: mask, background: teal) else {
            XCTFail("composite of a synthetic frame with a synthetic mask + background")
            return
        }
        XCTAssertEqual(out.width, size)
        XCTAssertEqual(out.height, size)
        // Person half (left): untouched. Sample well inside, away from the edge.
        XCTAssertEqual(Self.pixel(out, x: size / 4, y: size / 2).0, 255, accuracy: 3)
        // Background half (right): now the flat teal, not the checker.
        // (Compared against the stand-in's own pixel: Core Image
        // colorspace round-trips shift absolute values.)
        let want = Self.pixel(teal, x: size * 3 / 4, y: size / 2)
        let bg = Self.pixel(out, x: size * 3 / 4, y: size / 2)
        XCTAssertEqual(bg.0, want.0, accuracy: 2)
        XCTAssertEqual(bg.1, want.1, accuracy: 2)
        XCTAssertEqual(bg.2, want.2, accuracy: 2)
        XCTAssertLessThan(Self.variance(out, x0: size / 2, y0: 0, w: size / 2, h: size),
                          Self.variance(frame, x0: size / 2, y0: 0, w: size / 2, h: size))
    }

    func testCompositeReplaceScalesABackgroundToFill() {
        let frame = Self.personOnChecker(size: 64)
        let mask = Self.halfMask(size: 64)
        guard let tiny = PersonBackgroundBlur.solidImage(red: 1, green: 0, blue: 0, size: 8) else {
            XCTFail("tiny background image")
            return
        }
        guard let out = PersonBackgroundBlur.compositeReplace(frame, mask: mask, background: tiny) else {
            XCTFail("composite scales a tiny background up to the frame")
            return
        }
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
        let want = Self.pixel(tiny, x: 4, y: 4)
        let bg = Self.pixel(out, x: 48, y: 32)
        XCTAssertEqual(bg.0, want.0, accuracy: 2)
        XCTAssertEqual(bg.1, want.1, accuracy: 2)
        XCTAssertEqual(bg.2, want.2, accuracy: 2)
    }

    func testReplacePipelineRejectsPersonlessFrames() {
        // A solid-black frame has no person: nil, never a full-frame swap.
        guard let teal = PersonBackgroundBlur.solidImage(red: 0.15, green: 0.45, blue: 0.55) else {
            XCTFail("gallery stand-in image")
            return
        }
        XCTAssertNil(PersonBackgroundBlur.replacedBackground(Self.solid(size: 64, white: false), background: teal))
    }

    func testVisionReplacePathNeverCrashesAndKeepsTheSize() {
        // A cartoon has no person: Vision returns nil (fallback path) or a
        // same-size image. Either is correct; the test pins no-crash.
        guard let teal = PersonBackgroundBlur.solidImage(red: 0.15, green: 0.45, blue: 0.55, size: 64) else {
            XCTFail("gallery stand-in image")
            return
        }
        let frame = Self.checker(size: 64)
        let out = PersonBackgroundBlur.replacedBackground(frame, background: teal)
        if let out {
            XCTAssertEqual(out.width, frame.width)
            XCTAssertEqual(out.height, frame.height)
        }
    }

    // MARK: procedural gallery (deterministic, no assets)

    func testGalleryImagesAreDeterministicAndDistinct() {
        var pixels: [String] = []
        for bg in BuiltInBackground.allCases {
            guard let a = PersonBackgroundBlur.backgroundImage(for: bg, size: CGSize(width: 64, height: 64)),
                  let b = PersonBackgroundBlur.backgroundImage(for: bg, size: CGSize(width: 64, height: 64)) else {
                XCTFail("gallery image for \(bg)")
                return
            }
            XCTAssertEqual(a.width, 64)
            XCTAssertEqual(a.height, 64)
            // Deterministic: two renders match at sampled points.
            XCTAssertEqual(Self.pixel(a, x: 8, y: 8).0, Self.pixel(b, x: 8, y: 8).0, accuracy: 0.5)
            XCTAssertEqual(Self.pixel(a, x: 48, y: 48).1, Self.pixel(b, x: 48, y: 48).1, accuracy: 0.5)
            let p = Self.pixel(a, x: 32, y: 32)
            pixels.append("\(Int(p.0))-\(Int(p.1))-\(Int(p.2))")
        }
        // Four rooms, four looks.
        XCTAssertEqual(Set(pixels).count, BuiltInBackground.allCases.count)
    }

    // MARK: native controls (source pins, per NATIVEUI)

    func testReplaceSurfacesUseNativeControlsWithStableLabels() {
        let dir = Self.sourcesURL
        let prejoin = Self.read("Call/PreJoinView.swift", under: dir)
        XCTAssertTrue(prejoin.contains("Toggle(\"Blur Background\""), "prejoin blur toggle stays")
        XCTAssertTrue(prejoin.contains("Picker(\"Background\""), "background picker label")
        XCTAssertTrue(prejoin.contains(".pickerStyle(.segmented)"), "segmented, never web-look tabs")
        XCTAssertTrue(prejoin.contains("Picker(\"Room\""), "gallery picker label")
        XCTAssertTrue(prejoin.contains(".pickerStyle(.menu)"), "gallery is a native pop-up menu")
        XCTAssertTrue(prejoin.contains("Choose Custom"), "custom image picker entry")
        let tile = Self.read("Call/CallStageViewController.swift", under: dir)
        XCTAssertTrue(tile.contains("Toggle(\"Blur Background\""), "self-tile context menu item stays")
        XCTAssertTrue(tile.contains("Menu(\"Background\")"), "self-tile background menu")
        XCTAssertTrue(tile.contains("DemoReplaceView"), "demo replace ground truth")
        let evidence = Self.read("Evidence/CallEvidence.swift", under: dir)
        XCTAssertTrue(evidence.contains("&bg="), "evidence bg param documented")
        XCTAssertTrue(evidence.contains("applyEvidenceBackground"), "evidence bg wiring")
    }

    // MARK: helpers (mirror MeetLocalGuardTests' synthetic scenes)

    /// Solid opaque frame (no features, no person).
    private static func solid(size: Int, white: Bool) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: white ? 1 : 0, green: white ? 1 : 0, blue: white ? 1 : 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
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

    /// Left opaque white (person), right transparent black (background).
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

    /// Luminance variance over a rect (a flat replacement lowers it).
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

    private static var sourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private static func read(_ name: String, under dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}
