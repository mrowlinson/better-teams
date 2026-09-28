// ArchiveStore.swift — d2-archive lane: chat history export/import.
//
// File format (all ints little-endian):
//   magic "OMAR" (4B) | version UInt16 (1) | frameCount UInt32
//   per frame: codecID UInt32 | compLen UInt32 | uncompLen UInt32 | compBytes
// Payload is canonical JSONL: one sorted-keys ChatMessage object + "\n" per
// line. JSON string escaping guarantees raw 0x0A never appears inside a line,
// so frames may split mid-line safely.
//
// Both directions stream frame-by-frame through FileHandle: peak extra memory
// is ~2 frames + one line, independent of chat size.
import Foundation

public struct ArchiveStats: Sendable, Equatable {
    public let messageCount: Int
    public let bytesIn: Int
    public let bytesOut: Int
    public let frameCount: Int
    public let codec: ArchiveCodecID

    public init(messageCount: Int, bytesIn: Int, bytesOut: Int, frameCount: Int, codec: ArchiveCodecID) {
        self.messageCount = messageCount
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.frameCount = frameCount
        self.codec = codec
    }

    public var ratio: Double {
        bytesIn == 0 ? 1.0 : Double(bytesOut) / Double(bytesIn)
    }
}

public enum ArchiveStoreError: Error, Equatable, Sendable {
    case io(String)
    case badMagic
    case badVersion(UInt16)
    case truncated(String)
    case corrupt(String)
    case codec(ArchiveCodecError)
}

// MARK: - Little-endian helpers (shared in-module with LocalSearchStore)

enum ArchiveIO {
    static func putU16(_ v: UInt16, into d: inout Data) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    }

    static func putU32(_ v: UInt32, into d: inout Data) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }

    static func getU16(_ d: Data, at off: Int) -> UInt16 {
        UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
    }

    static func getU32(_ d: Data, at off: Int) -> UInt32 {
        UInt32(d[d.startIndex + off]) | (UInt32(d[d.startIndex + off + 1]) << 8)
            | (UInt32(d[d.startIndex + off + 2]) << 16) | (UInt32(d[d.startIndex + off + 3]) << 24)
    }

    static func readExactly(_ h: FileHandle, _ count: Int, what: String) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try h.read(upToCount: count - out.count), !chunk.isEmpty else { break }
            out.append(chunk)
        }
        if out.count != count {
            throw ArchiveStoreError.truncated("\(what): got \(out.count) of \(count) bytes")
        }
        return out
    }
}

public enum ArchiveStore {
    public static let magic = Data([0x4F, 0x4D, 0x41, 0x52]) // "OMAR"
    public static let version: UInt16 = 1
    public static let headerSize = 10
    public static let frameHeaderSize = 12

    static func canonicalEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// Canonical bytes for one message (sorted keys, no whitespace).
    public static func canonicalJSON(_ message: ChatMessage) throws -> Data {
        do {
            return try canonicalEncoder().encode(message)
        } catch {
            throw ArchiveStoreError.io("encode message \(message.id): \(error)")
        }
    }

    /// Canonical bytes for a thread (whole-array form). Round-trip identity
    /// is defined as byte-equality of this form before/after export.
    public static func canonicalData(_ messages: [ChatMessage]) throws -> Data {
        do {
            return try canonicalEncoder().encode(messages)
        } catch {
            throw ArchiveStoreError.io("encode thread: \(error)")
        }
    }

    // MARK: - Export (streaming)

    /// Export messages to `url` (overwritten). Frames are compressed and
    /// written as they fill, so peak extra RAM is ~2 frames + one line.
    @discardableResult
    public static func export(
        _ messages: [ChatMessage],
        to url: URL,
        codec preferredCodec: ArchiveCodecID = ArchiveCodec.defaultCodec,
        frameSize: Int = ArchiveCodec.defaultFrameSize
    ) throws -> ArchiveStats {
        let codec = ArchiveCodec.resolve(preferredCodec)
        guard frameSize > 0 else { throw ArchiveStoreError.io("frameSize must be > 0") }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: url.path) else {
            throw ArchiveStoreError.io("open for write: \(url.path)")
        }
        defer { try? out.close() }

        // Placeholder header; patched with the true frame count at the end.
        var header = Data()
        header.append(magic)
        ArchiveIO.putU16(version, into: &header)
        ArchiveIO.putU32(0, into: &header)
        try out.write(contentsOf: header)

        var frameBuf = Data()
        frameBuf.reserveCapacity(frameSize + 4096)
        var bytesIn = 0
        var bytesOut = headerSize
        var frameCount = 0

        func flush() throws {
            let comp: Data
            do {
                comp = try ArchiveCodec.encode(frameBuf, codec: codec)
            } catch let e as ArchiveCodecError {
                throw ArchiveStoreError.codec(e)
            }
            var fh = Data()
            ArchiveIO.putU32(codec.rawValue, into: &fh)
            ArchiveIO.putU32(UInt32(comp.count), into: &fh)
            ArchiveIO.putU32(UInt32(frameBuf.count), into: &fh)
            try out.write(contentsOf: fh)
            try out.write(contentsOf: comp)
            bytesOut += frameHeaderSize + comp.count
            frameCount += 1
            frameBuf.removeAll(keepingCapacity: true)
        }

        for m in messages {
            var line = try canonicalJSON(m)
            line.append(0x0A)
            if !frameBuf.isEmpty, frameBuf.count + line.count > frameSize {
                try flush()
            }
            frameBuf.append(line)
            bytesIn += line.count
        }
        if !frameBuf.isEmpty { try flush() }

        try out.seek(toOffset: 0)
        var patched = Data()
        patched.append(magic)
        ArchiveIO.putU16(version, into: &patched)
        ArchiveIO.putU32(UInt32(frameCount), into: &patched)
        try out.write(contentsOf: patched)

        return ArchiveStats(
            messageCount: messages.count, bytesIn: bytesIn,
            bytesOut: bytesOut, frameCount: frameCount, codec: codec)
    }

    // MARK: - Import (streaming)

    /// Decode an archive. Frames are read and decompressed one at a time;
    /// only the resulting messages accumulate.
    public static func load(from url: URL) throws -> (messages: [ChatMessage], stats: ArchiveStats) {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw ArchiveStoreError.io("open for read: \(url.path)")
        }
        defer { try? fh.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        let header = try ArchiveIO.readExactly(fh, headerSize, what: "header")
        guard header.prefix(4) == magic else { throw ArchiveStoreError.badMagic }
        let ver = ArchiveIO.getU16(header, at: 4)
        guard ver == version else { throw ArchiveStoreError.badVersion(ver) }
        let frameCount = Int(ArchiveIO.getU32(header, at: 6))

        let decoder = JSONDecoder()
        var messages: [ChatMessage] = []
        var carry = Data() // partial line spanning a frame boundary
        var bytesIn = 0
        var firstCodec: ArchiveCodecID = .lzbitmap

        for i in 0 ..< frameCount {
            let fhdr = try ArchiveIO.readExactly(fh, frameHeaderSize, what: "frame \(i) header")
            let codecRaw = ArchiveIO.getU32(fhdr, at: 0)
            let compLen = Int(ArchiveIO.getU32(fhdr, at: 4))
            let uncompLen = Int(ArchiveIO.getU32(fhdr, at: 8))
            guard let codec = ArchiveCodecID(rawValue: codecRaw) else {
                throw ArchiveStoreError.corrupt("frame \(i): unknown codec 0x\(String(codecRaw, radix: 16))")
            }
            if i == 0 { firstCodec = codec }
            let comp = try ArchiveIO.readExactly(fh, compLen, what: "frame \(i) payload")
            let plain: Data
            do {
                plain = try ArchiveCodec.decode(comp, codec: codec, expectedSize: uncompLen)
            } catch let e as ArchiveCodecError {
                throw ArchiveStoreError.codec(e)
            }
            bytesIn += plain.count
            // Split lines, carrying a partial tail into the next frame.
            var start = plain.startIndex
            for idx in plain.indices where plain[idx] == 0x0A {
                carry.append(contentsOf: plain[start ..< idx])
                do {
                    messages.append(try decoder.decode(ChatMessage.self, from: carry))
                } catch {
                    throw ArchiveStoreError.corrupt("frame \(i): bad message JSON: \(error)")
                }
                carry.removeAll(keepingCapacity: true)
                start = plain.index(after: idx)
            }
            carry.append(contentsOf: plain[start...])
        }
        if !carry.isEmpty {
            throw ArchiveStoreError.truncated("dangling partial line (\(carry.count) bytes)")
        }
        let stats = ArchiveStats(
            messageCount: messages.count, bytesIn: bytesIn,
            bytesOut: fileSize, frameCount: frameCount, codec: firstCodec)
        return (messages, stats)
    }
}
