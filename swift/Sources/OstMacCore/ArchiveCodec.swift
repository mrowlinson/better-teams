// ArchiveCodec.swift — d2-archive lane: codec abstraction for local archives.
//
// Baseline COMPRESSION_LZBITMAP (0x702, macOS 12.0+; app targets macOS 14 so
// always available). LZRAVEN (0xD05) is macOS 27+-gated with LZBITMAP fallback.
// LZMESH is a reserved slot only (cleanroom unfinished): the enum case exists
// but encode/decode always throw `.unimplemented`, never touching the SDK
// constant. All codecs here are buffer-API only; frame chunking is manual.
import Compression
import Foundation

/// On-disk codec id. Raw values match the `compression_algorithm` constants
/// so frame headers stay self-describing.
public enum ArchiveCodecID: UInt32, Codable, Sendable, CaseIterable {
    case lzbitmap = 0x702
    case lzraven = 0xD05
    case lzmesh = 0xE05
}

public enum ArchiveCodecError: Error, Equatable, Sendable {
    case unavailable(ArchiveCodecID)
    case encodeFailed(ArchiveCodecID)
    case decodeFailed(ArchiveCodecID)
    case corruptFrame(String)
    /// Reserved slots (LZMESH) that must not be used yet.
    case unimplemented(String)
}

/// Stateless codec operations. Pure functions; safe from any thread.
public enum ArchiveCodec {
    /// Manual frame size for the buffer API (no streaming sessions).
    /// 256KB chosen by bench (see ArchiveTests bench notes).
    public static let defaultFrameSize = 256 * 1024

    /// Ship default. Bench on real corpora (ArchiveTests.testBenchCodecs,
    /// macOS 27 host, 1.6MB chat JSON, 2026-09-25): LZBITMAP ratio 0.117 at
    /// ~400MB/s encode; LZRAVEN ratio 0.063 (better) but ~11MB/s encode
    /// (~35x slower). The rule ("LZBITMAP unless another available codec is
    /// measurably faster at equal-or-better ratio") keeps LZBITMAP: LZRAVEN
    /// wins ratio but fails the speed clause. Revisit if a faster LZRAVEN
    /// encoder ships.
    public static var defaultCodec: ArchiveCodecID { .lzbitmap }

    /// Throughput/ratio sample used by the ship-default rule.
    public struct CodecSample: Sendable {
        public let codec: ArchiveCodecID
        /// compressed bytes / uncompressed bytes (lower is better).
        public let ratio: Double
        /// Encode throughput in MB/s (higher is better).
        public let mbPerSec: Double

        public init(codec: ArchiveCodecID, ratio: Double, mbPerSec: Double) {
            self.codec = codec
            self.ratio = ratio
            self.mbPerSec = mbPerSec
        }
    }

    /// Ship-default rule: baseline unless a challenger has equal-or-better
    /// ratio AND is measurably (≥10%) faster. LZMESH is never eligible.
    public static func selectWinner(baseline: CodecSample, challengers: [CodecSample]) -> ArchiveCodecID {
        var win = baseline.codec
        var winSpeed = baseline.mbPerSec
        for c in challengers {
            guard c.codec != .lzmesh else { continue }
            guard c.ratio <= baseline.ratio else { continue }
            guard c.mbPerSec >= winSpeed * 1.10 else { continue }
            win = c.codec
            winSpeed = c.mbPerSec
        }
        return win
    }

    /// Lane-view availability. LZMESH reports false even where the SDK
    /// exposes it: the slot is reserved, not usable.
    public static func isAvailable(_ codec: ArchiveCodecID) -> Bool {
        switch codec {
        case .lzbitmap:
            return true // macOS 12.0+; target is macOS 14.
        case .lzraven:
            if #available(macOS 27, *) { return true }
            return false
        case .lzmesh:
            return false
        }
    }

    /// Map a preference to a usable codec. Pure/simulated variant for tests.
    public static func resolve(_ preferred: ArchiveCodecID, available: Set<ArchiveCodecID>) -> ArchiveCodecID {
        if preferred != .lzmesh, available.contains(preferred) { return preferred }
        return .lzbitmap
    }

    /// Map a preference to a usable codec on this host.
    public static func resolve(_ preferred: ArchiveCodecID) -> ArchiveCodecID {
        var avail = Set<ArchiveCodecID>()
        for c in ArchiveCodecID.allCases where isAvailable(c) { avail.insert(c) }
        return resolve(preferred, available: avail)
    }

    static func algorithm(for codec: ArchiveCodecID) throws -> compression_algorithm {
        switch codec {
        case .lzbitmap:
            return COMPRESSION_LZBITMAP
        case .lzraven:
            if #available(macOS 27, *) { return COMPRESSION_LZRAVEN }
            throw ArchiveCodecError.unavailable(.lzraven)
        case .lzmesh:
            throw ArchiveCodecError.unimplemented("LZMESH slot reserved; cleanroom vendoring pending")
        }
    }

    /// Compress one frame. Empty input encodes to empty output.
    public static func encode(_ data: Data, codec: ArchiveCodecID) throws -> Data {
        let algo = try algorithm(for: codec)
        if data.isEmpty { return Data() }
        return try data.withUnsafeBytes { srcRaw -> Data in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                throw ArchiveCodecError.encodeFailed(codec)
            }
            // No worst-case bound from the buffer API; oversize then grow
            // once on a zero return (too-small dst also reports 0).
            var dstSize = max(4096, data.count + data.count / 4 + 1024)
            for _ in 0 ..< 2 {
                var dst = Data(count: dstSize)
                let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
                    let d = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    return compression_encode_buffer(d, dstSize, src, data.count, nil, algo)
                }
                if written > 0 {
                    dst.count = written
                    return dst
                }
                dstSize *= 2
            }
            throw ArchiveCodecError.encodeFailed(codec)
        }
    }

    /// Decompress one frame; `expectedSize` comes from the frame header.
    /// Anything but an exact-size decode is corruption (no checksums in
    /// the raw codecs, so the size check is the integrity gate).
    public static func decode(_ data: Data, codec: ArchiveCodecID, expectedSize: Int) throws -> Data {
        let algo = try algorithm(for: codec)
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else {
            throw ArchiveCodecError.corruptFrame("empty payload, expected \(expectedSize) bytes")
        }
        return try data.withUnsafeBytes { srcRaw -> Data in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                throw ArchiveCodecError.decodeFailed(codec)
            }
            var dst = Data(count: expectedSize)
            let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
                let d = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                return compression_decode_buffer(d, expectedSize, src, data.count, nil, algo)
            }
            guard written == expectedSize else {
                throw ArchiveCodecError.corruptFrame(
                    "decoded \(written) bytes, expected \(expectedSize) (\(codec))")
            }
            return dst
        }
    }

    /// Split bytes into fixed-size frames (last may be short). Test/bench
    /// helper; ArchiveStore streams frames without materializing all of them.
    public static func splitFrames(_ data: Data, frameSize: Int = defaultFrameSize) -> [Data] {
        guard !data.isEmpty, frameSize > 0 else { return [] }
        var out: [Data] = []
        out.reserveCapacity(data.count / frameSize + 1)
        var off = data.startIndex
        while off < data.endIndex {
            let end = data.index(off, offsetBy: frameSize, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[off ..< end])
            off = end
        }
        return out
    }
}
