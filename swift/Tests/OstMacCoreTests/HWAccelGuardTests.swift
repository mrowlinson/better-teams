// HWAccelGuardTests.swift — HWACCEL guard. Every video decode/encode
// session goes through HWVideo (hardware asked for, checked, logged):
// a source lint fails any VT session, AVPlayer, asset reader/generator or
// AVAssetWriter video setting built elsewhere, and the helper's own
// sessions must report hardware on this Mac for H.264 and HEVC.
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import OstMacCore

final class HWAccelGuardTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // OstMacCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // swift
        .deletingLastPathComponent() // repo

    private static let helper = "swift/Sources/OstMacCore/HWVideo.swift"

    /// Patterns only the helper may spell (outside comments; matched
    /// with all whitespace removed, so `Create (` and line breaks count).
    private static let helperOnly = [
        "VTCompressionSessionCreate(",
        "VTDecompressionSessionCreate(",
        "AVPlayer(",
        "AVPlayerItem(",
        "AVQueuePlayer(",
        "AVAssetImageGenerator(",
        "AVAssetReader(",
        "AVAssetExportSession(",
        "AVCaptureMovieFileOutput(",
        "AVVideoCodecKey",
    ]

    /// Copies left on purpose, and why (the lint fails any new one).
    private static let copyAllowlist: [String: String] = [
        "swift/Sources/OstMacCore/ScreenShareModel.swift":
            "4Hz share preview outlives the callback; holding ScreenCaptureKit's surface would starve its queue",
    ]

    private static func swiftSources() -> [String] {
        let base = root.appendingPathComponent("swift/Sources")
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [String] = []
        for case let u as URL in e where u.pathExtension == "swift" {
            out.append(String(u.path.dropFirst(root.path.count + 1)))
        }
        return out.sorted()
    }

    /// Source with block and line comments blanked (line numbers kept).
    static func stripComments(_ text: String) -> [String] {
        let noBlocks = text.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlocks.components(separatedBy: "\n").map { line in
            guard let r = line.range(of: "//") else { return line }
            return String(line[..<r.lowerBound])
        }
    }

    /// Every bypass of the helper in one file's text (`rel` = repo path).
    static func violations(rel: String, text: String) -> [String] {
        guard rel != helper else { return [] }
        let lines = stripComments(text)
        let squeeze = { (s: String) in s.filter { !$0.isWhitespace } }
        var hits: [String] = []
        for (i, line) in lines.enumerated() {
            let sq = squeeze(line)
            for p in helperOnly where sq.contains(p) {
                hits.append("\(rel):\(i + 1) \(p)")
            }
            if sq.contains("VTCreateCGImageFromCVPixelBuffer"), copyAllowlist[rel] == nil {
                hits.append("\(rel):\(i + 1) CGImage copy of a video frame (use HWVideo.cgImage(wrapping:))")
            }
        }
        let whole = squeeze(lines.joined(separator: "\n"))
        if whole.contains("Specification:nil") {
            hits.append("\(rel) nil codec specification")
        }
        if whole.contains("AVAssetWriterInput(") || whole.contains("AVAssetWriter("),
           !whole.contains("HWVideo.writerVideoSettings(")
        {
            hits.append("\(rel) AVAssetWriter without HWVideo.writerVideoSettings")
        }
        return hits
    }

    // MARK: - Source lint

    func testNoVideoSessionOrPlayerOutsideHelper() throws {
        let files = Self.swiftSources()
        XCTAssertGreaterThan(files.count, 50, "scan found the sources")
        var hits: [String] = []
        for rel in files {
            let text = try String(contentsOf: Self.root.appendingPathComponent(rel), encoding: .utf8)
            hits += Self.violations(rel: rel, text: text)
        }
        XCTAssertEqual(hits, [], "route through HWVideo (hardware-first + logged):\n" + hits.joined(separator: "\n"))
    }

    /// Negative control: each bypass shape trips the lint; comments do not.
    func testLintCatchesEveryBypassShape() {
        let rel = "swift/Sources/OstMacCore/New.swift"
        let bad = [
            "let st = VTDecompressionSessionCreate (allocator: nil,",
            "let st = VTCompressionSessionCreate(\n allocator: nil,",
            "x(encoderSpecification:\n    nil, y)",
            "let p = AVPlayer(url: u)",
            "let i = AVPlayerItem(asset: a)",
            "let w = try AVAssetWriter(outputURL: u, fileType: .mp4)",
            "let e = AVAssetExportSession(asset: a, presetName: p)",
            "let o = AVCaptureMovieFileOutput()",
            "let g = AVAssetImageGenerator(asset: a)",
            "VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)",
        ]
        for b in bad {
            XCTAssertFalse(Self.violations(rel: rel, text: b).isEmpty, b)
        }
        let clean = [
            "// let p = AVPlayer(url: u)",
            "/* VTCompressionSessionCreate(\n encoderSpecification: nil */",
            "let p = HWVideo.makePlayer(url: u, path: \"x\")",
            "let w = try AVAssetWriter(outputURL: u, fileType: .mp4)\nlet s = HWVideo.writerVideoSettings(codec: .h264, width: 1, height: 1)",
            "let player: AVPlayer?",
        ]
        for c in clean {
            XCTAssertEqual(Self.violations(rel: rel, text: c), [], c)
        }
        // The helper itself is exempt; any other file is not.
        XCTAssertEqual(Self.violations(rel: Self.helper, text: bad[0]), [])
    }

    /// Positive control: the lint's patterns do match the helper itself.
    func testLintPatternsMatchTheHelper() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent(Self.helper), encoding: .utf8)
        let code = Self.stripComments(text).joined(separator: "\n")
        for p in ["VTCompressionSessionCreate(", "VTDecompressionSessionCreate(", "AVPlayer(", "AVVideoCodecKey",
                  "RequireHardwareAcceleratedVideoEncoder", "RequireHardwareAcceleratedVideoDecoder",
                  "encoderSpecification: encoderSpecification(", "decoderSpecification: decoderSpecification("] {
            XCTAssertTrue(code.contains(p), p)
        }
        XCTAssertFalse(code.filter { !$0.isWhitespace }.contains("Specification:nil"))
    }

    /// No software codec is linked: vendored ost's openh264 stays behind
    /// its `video-capture` feature, which nothing enables.
    func testNoSoftwareCodecLinked() throws {
        let toml = try String(contentsOf: Self.root.appendingPathComponent("rust/ostmac-core/Cargo.toml"), encoding: .utf8)
        XCTAssertFalse(toml.contains("video-capture"))
        let ost = try String(contentsOf: Self.root.appendingPathComponent("rust/ost/Cargo.toml"), encoding: .utf8)
        let defaults = ost.components(separatedBy: "\n").first { $0.hasPrefix("default") } ?? ""
        XCTAssertFalse(defaults.contains("video-capture"), defaults)
        let lock = try String(contentsOf: Self.root.appendingPathComponent("rust/ostmac-core/Cargo.lock"), encoding: .utf8)
        for bad in ["openh264", "ffmpeg", "vpx", "dav1d", "x264", "x265", "rav1e", "gstreamer", "libav"] {
            XCTAssertFalse(lock.contains("name = \"\(bad)"), bad)
        }
    }

    // MARK: - Helper

    func testSpecificationsAskForHardware() {
        let d = HWVideo.decoderSpecification(requireHardware: true)
        XCTAssertEqual(d[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] as? Bool, true)
        XCTAssertEqual(d[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] as? Bool, true)
        let e = HWVideo.encoderSpecification(requireHardware: true, lowLatency: true)
        XCTAssertEqual(e[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, true)
        XCTAssertEqual(e[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool, true)
        XCTAssertEqual(e[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] as? Bool, true)
        let soft = HWVideo.encoderSpecification(requireHardware: false)
        XCTAssertEqual(soft[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, true)
        XCTAssertNil(soft[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String])
        let s = HWVideo.surfaceAttributes()
        XCTAssertNotNil(s[kCVPixelBufferIOSurfacePropertiesKey as String])
    }

    func testAttemptLadderIsHardwareFirst() {
        typealias A = HWVideo.Attempt
        XCTAssertEqual(HWVideo.attempts(codec: kCMVideoCodecType_H264, lowLatency: true), [
            A(requireHardware: true, lowLatency: true),
            A(requireHardware: true, lowLatency: false),
            A(requireHardware: false, lowLatency: false),
        ])
        XCTAssertEqual(HWVideo.attempts(codec: kCMVideoCodecType_HEVC, lowLatency: true), [
            A(requireHardware: true, lowLatency: false),
            A(requireHardware: false, lowLatency: false),
        ])
        XCTAssertEqual(HWVideo.attempts(codec: kCMVideoCodecType_MPEG2Video, lowLatency: false), [
            A(requireHardware: false, lowLatency: false),
        ])
    }

    func testLiveEncodeAndDecodeRunInHardware() throws {
        let w = 640, h = 480
        let enc = try XCTUnwrap(H264StreamEncoder(width: w, height: h, path: "test-enc"))
        XCTAssertTrue(enc.hardware)
        XCTAssertFalse(enc.lowLatency) // opt-in (energy, see H264StreamEncoder.init)
        // Zero-copy input: an IOSurface buffer straight to the encoder.
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                           HWVideo.surfaceAttributes() as CFDictionary, &pb), kCVReturnSuccess)
        let buf = try XCTUnwrap(pb)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buf))
        CVPixelBufferLockBaseAddress(buf, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buf))
        memset(base, 0x60, CVPixelBufferGetBytesPerRow(buf) * h)
        CVPixelBufferUnlockBaseAddress(buf, [])
        let nals = try enc.encode(pixelBuffer: buf)
        XCTAssertEqual(nals.first.map { $0[0] & 0x1F }, 7)
        // Wire shape the far end already takes: baseline profile (66),
        // one slice per picture.
        XCTAssertEqual(nals[0][1], 66)
        XCTAssertEqual(nals.filter { [1, 5].contains($0[0] & 0x1F) }.count, 1)
        let img = try XCTUnwrap(H264StreamDecoder(path: "test-dec").decode(nals: nals))
        XCTAssertEqual(img.width, w)
        XCTAssertEqual(img.height, h)
        // Wrong size is refused, not silently scaled.
        XCTAssertThrowsError(try XCTUnwrap(H264StreamEncoder(width: 320, height: 240, path: "test-enc2"))
            .encode(pixelBuffer: buf))
        let lines = HWVideo.recentReports
        XCTAssertTrue(lines.contains { $0.hasPrefix("hw=true codec=h264 path=test-enc kind=encode 640x480 via=reported") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("hw=true codec=h264 path=test-dec kind=decode 640x480") }, "\(lines)")
    }

    /// Opt-in low-latency encoder (rtvc): hardware by the Require
    /// contract (it does not answer the query), constrained baseline.
    func testLowLatencyEncoderIsHardwareConstrainedBaseline() throws {
        let enc = try XCTUnwrap(H264StreamEncoder(width: 640, height: 480, path: "test-ll", lowLatency: true))
        XCTAssertTrue(enc.hardware)
        XCTAssertTrue(enc.lowLatency)
        let nals = try enc.encode(bgra: Data(repeating: 0x50, count: 640 * 480 * 4))
        XCTAssertEqual(nals[0][0] & 0x1F, 7)
        XCTAssertEqual(nals[0][1], 66)
        XCTAssertEqual(nals[0][2] & 0x40, 0x40)
        XCTAssertNotNil(try H264StreamDecoder(path: "test-ll-dec").decode(nals: nals))
        XCTAssertTrue(HWVideo.recentReports.contains {
            $0.hasPrefix("hw=true codec=h264 path=test-ll kind=encode 640x480 lowlatency via=required")
        })
    }

    func testHEVCEncodeRunsInHardware() throws {
        let made = try XCTUnwrap(HWVideo.makeCompressionSession(
            width: 1920, height: 1080, codec: kCMVideoCodecType_HEVC, path: "test-hevc"))
        defer { VTCompressionSessionInvalidate(made.session) }
        XCTAssertTrue(made.hardware)
    }

    /// Software only where no hardware exists, and then a logged
    /// warning naming the refused hardware attempt (MPEG-2 has no
    /// hardware decoder on Apple silicon: a real Require refusal).
    func testSoftwareFallbackIsLoggedAsWarning() throws {
        var fd: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_MPEG2Video,
            width: 640, height: 480, extensions: nil, formatDescriptionOut: &fd), noErr)
        let made = HWVideo.makeDecompressionSession(
            format: try XCTUnwrap(fd), outputAttributes: nil, path: "test-mpeg2",
            ladder: [HWVideo.Attempt(requireHardware: true, lowLatency: false),
                     HWVideo.Attempt(requireHardware: false, lowLatency: false)])
        if let made { VTDecompressionSessionInvalidate(made.session) }
        let entry = try XCTUnwrap(HWVideo.recentReportEntries.last { $0.line.contains("path=test-mpeg2") })
        XCTAssertTrue(entry.line.contains("fallback=[attempt0 status="), entry.line)
        XCTAssertTrue(["warning", "error"].contains(entry.level), entry.level)
        XCTAssertFalse(made?.hardware ?? false)
        // Hardware success is a notice (not a warning).
        let ok = HWVideo.recentReportEntries.filter { $0.line.hasPrefix("hw=true") && !$0.line.contains("fallback=") }
        XCTAssertTrue(ok.allSatisfy { $0.level == "notice" })
    }

    /// The decoded frame's CGImage reads the buffer's own pixels.
    func testZeroCopyImageShowsBufferPixels() throws {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
                                           HWVideo.surfaceAttributes() as CFDictionary, &pb), kCVReturnSuccess)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        let p = try XCTUnwrap(CVPixelBufferGetBaseAddress(buf)).assumingMemoryBound(to: UInt8.self)
        for i in 0 ..< CVPixelBufferGetBytesPerRow(buf) * 4 / 4 {
            p[i * 4] = 10; p[i * 4 + 1] = 20; p[i * 4 + 2] = 200; p[i * 4 + 3] = 255 // BGRA
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let img = try XCTUnwrap(HWVideo.cgImage(wrapping: buf))
        XCTAssertEqual(img.width, 8)
        XCTAssertEqual(img.height, 4)
        let data = try XCTUnwrap(img.dataProvider?.data) as Data
        XCTAssertEqual(Array(data.prefix(4)), [10, 20, 200, 255])
    }

    /// AVPlayer paths: the asset's format is probed through a
    /// hardware-required session (H.264 clip written hardware-first).
    func testPlaybackProbeAndWriterUseHardware() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hwaccel-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mp4")
        try DemoClip.renderHardwareFirst(to: url)
        let hw = await HWVideo.probePlayback(asset: AVURLAsset(url: url), path: "test")
        XCTAssertEqual(hw, true)
        let lines = HWVideo.recentReports
        XCTAssertTrue(lines.contains { $0.hasPrefix("hw=true codec=h264 path=demo-clip") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("hw=true codec=h264 path=avplayer-test kind=decode 480x270") }, "\(lines)")
    }
}
