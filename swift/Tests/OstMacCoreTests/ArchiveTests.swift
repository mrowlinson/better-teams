// ArchiveTests.swift — d2-archive lane: codec, export/import, bench.
import Darwin
import XCTest

@testable import OstMacCore

final class ArchiveTests: XCTestCase {
    // MARK: - Fixtures

    static let senders = [
        "Megan Harper", "Tom Becker", "Paige Sutton", "Sam Whitfield",
        "Elena Novak", "Marcus Reed", "Hannah Calloway", "David Bennett",
    ]

    static let bodies = [
        "Shipping the release candidate on Friday morning after standup",
        "Can someone approve the pull request for the notification service",
        "The quarterly planning document needs signatures before Thursday",
        "Load testing results show p99 latency well under the target budget",
        "Reminder that expense reports are due before end of sprint",
        "Meeting notes: agreed on milestones for next quarter deliverables",
    ]

    static func makeMsgs(_ n: Int) -> [ChatMessage] {
        (0 ..< n).map { i in
            ChatMessage(
                id: "\(1758600000000 + i * 61_000)",
                sender: senders[i % senders.count],
                timestamp: String(format: "2026-09-%02dT%02d:%02d:%02dZ", 1 + (i % 22), 8 + (i % 10), i % 60, (i * 7) % 60),
                content: "\(bodies[i % bodies.count]) — thread \(i / 9), seq \(i)")
        }
    }

    static func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/chat-corpus.json")
    }

    static func corpusMessages() throws -> [ChatMessage] {
        let data = try Data(contentsOf: corpusURL())
        return try decodeOrThrow([ChatMessage].self, from: data)
    }

    func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-\(name)-\(UInt32.random(in: 0 ... .max)).omar")
    }

    // MARK: - Round-trip

    func testRoundTripIdentity() throws {
        let msgs = Self.makeMsgs(1500)
        let url = tmpURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try ArchiveStore.export(msgs, to: url)
        XCTAssertEqual(stats.messageCount, 1500)
        XCTAssertGreaterThan(stats.frameCount, 0)
        // Acceptance 1: archive smaller than uncompressed JSON bytes.
        let canonical = try ArchiveStore.canonicalData(msgs)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertLessThan(attrs[.size] as! Int, canonical.count)
        // Acceptance 3: byte-compare of canonical JSON.
        let (back, _) = try ArchiveStore.load(from: url)
        XCTAssertEqual(try ArchiveStore.canonicalData(back), canonical)
        XCTAssertEqual(back.map(\.id), msgs.map(\.id))
        XCTAssertEqual(back.map(\.content), msgs.map(\.content))
    }

    func testEmptyChatExport() throws {
        let url = tmpURL("empty")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try ArchiveStore.export([], to: url)
        XCTAssertEqual(stats.frameCount, 0)
        XCTAssertEqual(stats.messageCount, 0)
        let (back, _) = try ArchiveStore.load(from: url)
        XCTAssertTrue(back.isEmpty)
    }

    func testFrameBoundarySplit() throws {
        // 64-byte frames force mid-message splits on every line.
        let msgs = Self.makeMsgs(200)
        let url = tmpURL("tiny")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try ArchiveStore.export(msgs, to: url, frameSize: 64)
        XCTAssertGreaterThanOrEqual(stats.frameCount, 200)
        let (back, _) = try ArchiveStore.load(from: url)
        XCTAssertEqual(try ArchiveStore.canonicalData(back), try ArchiveStore.canonicalData(msgs))
    }

    // MARK: - Corruption

    func testCorruptFrameThrows() throws {
        let url = tmpURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArchiveStore.export(Self.makeMsgs(500), to: url)
        var data = try Data(contentsOf: url)
        // Truncate the last frame payload by half.
        data.count -= max(64, (data.count - ArchiveStore.headerSize) / 4)
        try data.write(to: url)
        XCTAssertThrowsError(try ArchiveStore.load(from: url))
    }

    func testBadMagicThrows() throws {
        let url = tmpURL("magic")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("NOPE0123456789".utf8).write(to: url)
        XCTAssertThrowsError(try ArchiveStore.load(from: url)) { e in
            XCTAssertEqual(e as? ArchiveStoreError, .badMagic)
        }
    }

    // MARK: - Codec selection + gating

    func testCodecFallbackSelection() {
        // Simulated availability (deterministic on any host).
        XCTAssertEqual(
            ArchiveCodec.resolve(.lzraven, available: [.lzbitmap]), .lzbitmap)
        XCTAssertEqual(
            ArchiveCodec.resolve(.lzraven, available: [.lzbitmap, .lzraven]), .lzraven)
        XCTAssertEqual(
            ArchiveCodec.resolve(.lzbitmap, available: [.lzbitmap, .lzraven]), .lzbitmap)
        // LZMESH always falls back: reserved slot, never selected.
        XCTAssertEqual(
            ArchiveCodec.resolve(.lzmesh, available: [.lzbitmap, .lzraven, .lzmesh]), .lzbitmap)
    }

    func testLzbitmapRoundTrip() throws {
        let data = Data("the quick brown fox jumps over the lazy dog, repeatedly. ".utf8)
        let big = Data((0 ..< 5000).flatMap { _ in data })
        let comp = try ArchiveCodec.encode(big, codec: .lzbitmap)
        XCTAssertLessThan(comp.count, big.count)
        XCTAssertEqual(try ArchiveCodec.decode(comp, codec: .lzbitmap, expectedSize: big.count), big)
        // Empty frame edge.
        XCTAssertTrue(try ArchiveCodec.encode(Data(), codec: .lzbitmap).isEmpty)
        XCTAssertTrue(try ArchiveCodec.decode(Data(), codec: .lzbitmap, expectedSize: 0).isEmpty)
    }

    func testLzravenGatedPath() throws {
        let data = Data("raven test payload for the macOS 27 gated path. ".utf8)
        let big = Data((0 ..< 2000).flatMap { _ in data })
        if #available(macOS 27, *) {
            XCTAssertTrue(ArchiveCodec.isAvailable(.lzraven))
            XCTAssertEqual(ArchiveCodec.resolve(.lzraven), .lzraven)
            let comp = try ArchiveCodec.encode(big, codec: .lzraven)
            XCTAssertEqual(try ArchiveCodec.decode(comp, codec: .lzraven, expectedSize: big.count), big)
        } else {
            XCTAssertFalse(ArchiveCodec.isAvailable(.lzraven))
            XCTAssertEqual(ArchiveCodec.resolve(.lzraven), .lzbitmap)
            XCTAssertThrowsError(try ArchiveCodec.encode(big, codec: .lzraven)) { e in
                XCTAssertEqual(e as? ArchiveCodecError, .unavailable(.lzraven))
            }
        }
    }

    func testLzmeshReservedSlot() {
        XCTAssertFalse(ArchiveCodec.isAvailable(.lzmesh))
        XCTAssertThrowsError(try ArchiveCodec.encode(Data([1, 2, 3]), codec: .lzmesh)) { e in
            guard case .unimplemented = e as! ArchiveCodecError else {
                return XCTFail("expected .unimplemented, got \(e)")
            }
        }
        XCTAssertThrowsError(try ArchiveCodec.decode(Data([1]), codec: .lzmesh, expectedSize: 1)) { e in
            guard case .unimplemented = e as! ArchiveCodecError else {
                return XCTFail("expected .unimplemented, got \(e)")
            }
        }
    }

    func testExportUsesFallbackCodec() throws {
        // Export with an unavailable preference still produces a decodable file.
        let url = tmpURL("fallback")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try ArchiveStore.export(Self.makeMsgs(100), to: url, codec: .lzmesh)
        XCTAssertEqual(stats.codec, .lzbitmap)
        let (back, _) = try ArchiveStore.load(from: url)
        XCTAssertEqual(back.count, 100)
    }

    // MARK: - Memory bound (acceptance 2)

    static func currentRSS() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    func testExportMemoryBound() throws {
        let msgs = Self.makeMsgs(10_000)
        let url = tmpURL("rss")
        defer { try? FileManager.default.removeItem(at: url) }
        // Analytic bound (R3): streaming export holds ~2 frames + one line;
        // messages array itself is caller-owned input, not export overhead.
        let frameSize = ArchiveCodec.defaultFrameSize
        let analyticPeak = 2 * frameSize + 1_048_576 // frames + 1MB line slack
        XCTAssertLessThan(analyticPeak, 100 * 1024 * 1024)
        // Measured peak: sample RSS on a side thread during export.
        let baseline = Self.currentRSS()
        let peakBox = LockedBox(baseline)
        let stop = LockedBox(false)
        let sampler = Thread {
            while !stop.value {
                let rss = Self.currentRSS()
                peakBox.mutate { if rss > $0 { $0 = rss } }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        sampler.start()
        let stats = try ArchiveStore.export(msgs, to: url)
        stop.value = true
        let peak = peakBox.value
        // Round-trip still exact at 10k scale.
        let (back, _) = try ArchiveStore.load(from: url)
        XCTAssertEqual(back.count, 10_000)
        XCTAssertEqual(try ArchiveStore.canonicalData(back), try ArchiveStore.canonicalData(msgs))
        let extra = peak >= baseline ? peak - baseline : 0
        print("EXPORT-RSS frames=\(stats.frameCount) bytesIn=\(stats.bytesIn) peakExtraRSS=\(extra / 1024)KB")
        XCTAssertLessThan(extra, 100 * 1024 * 1024, "peak extra RSS \(extra) exceeds 100MB")
    }

    // MARK: - Bench (acceptance 7)

    struct BenchResult {
        let sample: ArchiveCodec.CodecSample
        let decodeMBps: Double
    }

    func benchCodec(_ codec: ArchiveCodecID, frames: [Data]) throws -> BenchResult {
        let total = frames.reduce(0) { $0 + $1.count }
        // Warmup.
        _ = try frames.map { try ArchiveCodec.encode($0, codec: codec) }
        let iters = 3
        var compBytes = 0
        var comps: [Data] = []
        // CPU seconds, not wall: throughput under machine load must not decide the winner.
        let t0 = TestWait.cpuSeconds()
        for _ in 0 ..< iters {
            comps = try frames.map { try ArchiveCodec.encode($0, codec: codec) }
            compBytes = comps.reduce(0) { $0 + $1.count }
        }
        let encSecs = max(TestWait.cpuSeconds() - t0, 1e-9)
        let t1 = TestWait.cpuSeconds()
        for _ in 0 ..< iters {
            for (i, c) in comps.enumerated() {
                _ = try ArchiveCodec.decode(c, codec: codec, expectedSize: frames[i].count)
            }
        }
        let decSecs = max(TestWait.cpuSeconds() - t1, 1e-9)
        let mb = Double(total * iters) / 1_000_000.0
        return BenchResult(
            sample: .init(codec: codec, ratio: Double(compBytes) / Double(total), mbPerSec: mb / encSecs),
            decodeMBps: mb / decSecs)
    }

    func testBenchCodecs() throws {
        let corpusData = try Data(contentsOf: Self.corpusURL())
        XCTAssertGreaterThanOrEqual(corpusData.count, 1_000_000, "fixture must be ≥1MB real corpora")
        let frames = ArchiveCodec.splitFrames(corpusData)
        XCTAssertGreaterThan(frames.count, 1)
        let base = try benchCodec(.lzbitmap, frames: frames)
        print(String(
            format: "BENCH lzbitmap ratio=%.3f enc=%.1fMB/s dec=%.1fMB/s frames=%d bytes=%d",
            base.sample.ratio, base.sample.mbPerSec, base.decodeMBps, frames.count, corpusData.count))
        var challengers: [ArchiveCodec.CodecSample] = []
        if ArchiveCodec.isAvailable(.lzraven) {
            let raven = try benchCodec(.lzraven, frames: frames)
            print(String(
                format: "BENCH lzraven ratio=%.3f enc=%.1fMB/s dec=%.1fMB/s",
                raven.sample.ratio, raven.sample.mbPerSec, raven.decodeMBps))
            challengers.append(raven.sample)
        } else {
            print("BENCH lzraven unavailable on this host (fallback path)")
        }
        // Ship-default rule: baseline unless a challenger is measurably
        // faster at equal-or-better ratio.
        let winner = ArchiveCodec.selectWinner(baseline: base.sample, challengers: challengers)
        print("BENCH winner=\(winner) default=\(ArchiveCodec.defaultCodec)")
        XCTAssertEqual(ArchiveCodec.defaultCodec, winner)
    }
}
