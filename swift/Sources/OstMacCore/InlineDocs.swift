// InlineDocs.swift — om-inline-docs lane: doc rows inside bubbles.
//
// File-share messages arrive as bare `<attachment id="GUID">` refs: the
// name/size/URL live in Graph, not in the message (the task's assumption
// that messages carry docs is wrong for the wire format — see below).
// Core exposes the same GUID on each shared file (`attachment_id`, mined
// from the driveItem eTag), so the bubble resolves refs against the
// already-loaded Shared tab list and renders one native row per match:
// Finder icon (async) + name + size + Open. No bytes are ever prefetched:
// resolution is a pure in-memory match, the icon comes from the local
// system icon cache, and Open hands the SharePoint URL to the browser.
//
//   let docs = InlineDocs.docs(for: message, files: sharedFiles)
//   InlineDocRows(docs: docs, onOpen: { shared.open($0.file) })
import AppKit
import Foundation
import UniformTypeIdentifiers

/// One resolved doc row: a shared file matched to a message's attachment
/// ref. `id` is the file id (stable across re-resolves); `refID` is the
/// `<attachment id>` that matched it.
public struct InlineDoc: Sendable, Equatable, Identifiable {
    public var id: String { file.id }
    public let file: SharedFile
    public let refID: String

    public init(file: SharedFile, refID: String) {
        self.file = file
        self.refID = refID
    }

    public var name: String { file.name }
    public var sizeLabel: String { file.sizeLabel }
    public var iconName: String { file.iconName }
    public var sender: String? { file.sender }
}

public enum InlineDocs {
    /// Max rows per bubble (caps a hostile blob; bot-post parity).
    public static let maxRows = 10

    /// Attachment ids referenced by one message's raw HTML, in order,
    /// deduped. Only blocks WITH an `id` attribute qualify: id-less
    /// blocks stay bot-post-only (no row duplication). Unterminated and
    /// self-closing forms are handled; id-less/empty ids are dropped.
    /// Tag/attr names are case-insensitive; values tolerate any quoting
    /// (same `attributes(of:)` parser the image miner uses).
    public static func refs(fromRaw raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        refsLock.lock()
        if let hit = refsCache[raw] {
            refsLock.unlock()
            return hit
        }
        refsLock.unlock()
        let out = refsUncached(fromRaw: raw)
        refsLock.lock()
        refsComputes += 1
        if refsCache.count >= maxRefsCacheEntries { refsCache.removeAll() }
        refsCache[raw] = out
        refsLock.unlock()
        return out
    }

    static let maxRefsCacheEntries = 1000
    private static let refsLock = NSLock()
    private static var refsCache: [String: [String]] = [:]

    /// Actual scans, excluding cache hits (perf-guard tests only).
    static var refsComputes = 0

    /// Drop the cached scans + zero the counter (tests only).
    static func resetRefsCache() {
        refsLock.lock()
        defer { refsLock.unlock() }
        refsCache.removeAll()
        refsComputes = 0
    }

    static func refsUncached(fromRaw raw: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var rest = raw[...]
        while let s = rest.range(of: "<attachment", options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">")
        {
            let open = String(rest[s.lowerBound ... gt])
            if open.hasSuffix("/>") {
                rest = rest[rest.index(after: gt)...]
            } else {
                guard let e = rest[gt...].range(of: "</attachment>", options: .caseInsensitive) else {
                    break // unterminated: kept as text, never a ref
                }
                rest = rest[e.upperBound...]
            }
            let id = (MessageRender.attributes(of: open)["id"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// Pure in-memory match: each ref against the already-loaded shared
    /// list by `attachment_id`. Unmatched refs are dropped (the bubble
    /// falls back to existing text/placeholder behavior). Performs no
    /// I/O: safe to call on every render.
    public static func resolve(refs: [String], files: [SharedFile]) -> [InlineDoc] {
        resolve(refs: refs, filesByAttachmentID: index(files: files))
    }

    /// `attachment_id` -> file, first wins (matches `first(where:)`).
    /// Files without an id never match (resolve drops them, as before).
    public static func index(files: [SharedFile]) -> [String: SharedFile] {
        var out: [String: SharedFile] = [:]
        out.reserveCapacity(files.count)
        for f in files {
            guard let id = f.attachment_id else { continue }
            if out[id] == nil { out[id] = f }
        }
        return out
    }

    /// Resolve over a prebuilt index (om-perf-swift-render): one O(files)
    /// index per `docs` call instead of a linear scan per ref. Same
    /// values as `resolve(refs:files:)` — first file wins per id.
    public static func resolve(refs: [String], filesByAttachmentID index: [String: SharedFile]) -> [InlineDoc] {
        var out: [InlineDoc] = []
        for id in refs {
            guard out.count < maxRows else { break }
            guard let f = index[id] else { continue }
            out.append(InlineDoc(file: f, refID: id))
        }
        return out
    }

    /// Rows for one bubble: mine the refs, resolve against loaded files.
    public static func docs(for message: ChatMessage, files: [SharedFile]) -> [InlineDoc] {
        let refs = refs(fromRaw: message.raw)
        guard !refs.isEmpty else { return [] }
        return resolve(refs: refs, filesByAttachmentID: index(files: files))
    }

    /// True when any message carries doc refs: the host preloads the
    /// shared list (metadata only, never bytes) so rows can resolve.
    /// Chats without refs never trigger a load (no prefetch).
    public static func shouldPreload(messages: [ChatMessage]) -> Bool {
        messages.contains { !refs(fromRaw: $0.raw).isEmpty }
    }

    /// Parsed http(s) Open target (SharePoint page), or nil for rows
    /// without one. Only http(s) schemes open (bot-row parity).
    public static func openTarget(for doc: InlineDoc) -> URL? {
        guard let s = doc.file.web_url, let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    /// Default Open: browser-preview the SharePoint page. Never downloads
    /// (bytes move only via the Shared tab's explicit Save).
    public static func open(_ doc: InlineDoc) {
        if let url = openTarget(for: doc) {
            TeamsLinkRouter.open(url)
        }
    }
}

/// Cached Finder file icons by extension (om-inline-docs): the row's
/// thumbnail. Local system-icon lookup only — never network. The actor
/// memoizes per extension so scrolling never re-queries.
public actor InlineDocIconCache {
    public static let shared = InlineDocIconCache()

    private var cache: [String: NSImage] = [:]

    /// Icon for one filename. Runs on the main actor (AppKit affinity);
    /// callers show their SF Symbol fallback until it lands.
    public func icon(fileName: String) async -> NSImage {
        let key = (fileName as NSString).pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let img = await MainActor.run {
            // Unknown/empty extensions fall back to the generic document
            // icon (what the old "___" file-type lookup returned).
            let type = key.isEmpty ? UTType.data : (UTType(filenameExtension: key) ?? .data)
            return NSWorkspace.shared.icon(for: type)
        }
        cache[key] = img
        return img
    }
}

