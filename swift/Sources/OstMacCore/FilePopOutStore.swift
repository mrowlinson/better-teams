// FilePopOutStore.swift — gap-g8: file-preview pop-out registry.
//
// E1-POPOUT contract mirrored for Shared-tab files: one file = max
// one preview window; re-pop focuses (pop returns nil); the preview
// live-updates from the Shared list (rename/move/delete land via
// `refresh`); close loses no state (the snapshot stays cached —
// re-pop restores instantly with no refetch).
//
// Keys are composite `chatID + separator + fileID` (drive item ids
// are chat-scoped in the list responses, so the chat disambiguates).
// Snapshots resolve from the live SharedFilesStore at pop time; the
// host pushes list changes through `refresh(chatID:files:)` (a
// `$files` subscription), so a rename in the main window updates the
// popped preview in place.
//
//   let pops = FilePopOutStore()
//   if let v = pops.pop(chatID: id, file: f) { openWindow(value: v) }
//   pops.refresh(chatID: id, files: store.files) // live updates
//   pops.close(key: v.key) // red dot: snapshot stays
import Combine
import Foundation

/// Value-driven window value for one popped file preview. A distinct
/// type (not String) so `openWindow(value:)` routes to the file scene
/// even though the chat + account scenes share `String.self`.
public struct FilePopoutValue: Codable, Hashable, Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Cached preview snapshot: the chat it belongs to plus the file row
/// as last seen (live list pushes refresh it in place).
public struct FilePopoutEntry: Equatable, Sendable {
    public let key: String
    public let chatID: String
    public var file: SharedFile

    public init(key: String, chatID: String, file: SharedFile) {
        self.key = key
        self.chatID = chatID
        self.file = file
    }
}

/// Popped-file registry + snapshot cache.
@MainActor
public final class FilePopOutStore: ObservableObject {
    /// Currently visible pop-outs (one composite key per window).
    @Published public private(set) var poppedKeys: Set<String> = []
    /// Session snapshot cache (key → entry). Plain (never
    /// @Published): resolved during window-body eval, must not
    /// republish mid-render. Published separately via `revision`
    /// (the preview observes the store, reads the entry by key).
    public private(set) var entries: [String: FilePopoutEntry] = [:]
    /// Bumps on every snapshot refresh so open previews re-render.
    @Published public private(set) var revision = 0

    /// Composite-key separator (ids never contain newlines).
    public nonisolated static let separator = "\n"

    public init() {}

    /// Composite key for a chat + file pair. Blank chat or file ids
    /// still key (callers fall back to the key as the title).
    nonisolated public static func key(chatID: String, fileID: String) -> String {
        "\(chatID)\(separator)\(fileID)"
    }

    /// Split a composite key back into (chatID, fileID). Keys without
    /// the separator read as ("", key).
    nonisolated public static func split(_ key: String) -> (chatID: String, fileID: String) {
        guard let i = key.firstIndex(of: "\n") else { return ("", key) }
        return (
            String(key[..<i]),
            String(key[key.index(after: i)...])
        )
    }

    /// Pop a file: the window value when newly popped, nil when already
    /// popped (caller focuses the existing window) or the file id is
    /// blank. Re-pop of a closed key restores the cached snapshot
    /// when the caller passes the same file (no refetch); a changed
    /// row updates the cache.
    public func pop(chatID: String, file: SharedFile) -> FilePopoutValue? {
        let fileID = file.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return nil }
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = Self.key(chatID: chat, fileID: fileID)
        guard !poppedKeys.contains(k) else { return nil }
        if entries[k] == nil || entries[k]?.file != file {
            entries[k] = FilePopoutEntry(key: k, chatID: chat, file: file)
            revision += 1
        }
        poppedKeys.insert(k)
        return FilePopoutValue(key: k)
    }

    /// True while the file has a visible pop-out window.
    public func isPopped(key: String) -> Bool {
        poppedKeys.contains(key)
    }

    /// Window closed (red dot): the key leaves the visible set while
    /// its snapshot stays cached for the session — re-pop restores
    /// instantly with no refetch.
    public func close(key: String) {
        poppedKeys.remove(key)
    }

    /// Cached snapshot for a key (nil when never popped — restored
    /// windows for forgotten keys render "no longer available").
    public func entry(for key: String) -> FilePopoutEntry? {
        entries[key]
    }

    /// Live-update fan-in: upsert every cached snapshot whose chat
    /// matches from the latest list. Renames/moves land in place;
    /// files missing from the list keep their last snapshot (close
    /// loses no state — the preview never blanks under a refresh).
    /// True when at least one snapshot changed.
    @discardableResult
    public func refresh(chatID: String, files: [SharedFile]) -> Bool {
        var changed = false
        for (k, e) in entries where e.chatID == chatID {
            guard let fresh = files.first(where: { $0.id == e.file.id }) else { continue }
            if fresh != e.file {
                entries[k] = FilePopoutEntry(key: k, chatID: chatID, file: fresh)
                changed = true
            }
        }
        if changed { revision += 1 }
        return changed
    }
}
