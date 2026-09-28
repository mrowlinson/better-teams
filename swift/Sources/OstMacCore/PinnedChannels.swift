// PinnedChannels.swift — core-b: user-pinned Teams channels, per account,
// in the user's order.
//
// LOCAL ONLY (by design). Microsoft Graph has no pinned-channel API, and
// the Teams web client keeps channel pins in an undocumented per-user
// settings blob, so pins live on this Mac: one UserDefaults string array
// per account, in the user's order (append on pin; `move` reorders).
// Pins made in Microsoft Teams do not show here, and pins made here do
// not show in Teams.
//
// The key is `bt.teams.pinned.<accountKey>`: the same key the Teams
// section's former UI-side `ChannelPrefs` wrote, so adopting this store
// keeps every existing pin. Ids outside the current teams fetch are kept
// (a later fetch brings the row back); `ordered(_:)` projects onto the
// live channel list.
//
// Demo: `defaults: nil` = memory only (never reads or writes a real key).
//
//   let pins = PinnedChannelStore(accountKey: key, defaults: demo ? nil : .standard)
//   pins.pin(channelID); pins.unpin(channelID); pins.move(from: 2, to: 0)
import Foundation

/// User-pinned channel ids for one account, in the user's order.
@MainActor
public final class PinnedChannelStore: ObservableObject {
    /// UserDefaults key prefix (the account key is appended).
    public nonisolated static let keyPrefix = "bt.teams.pinned."

    /// UserDefaults key for one account's ordered pin array.
    public nonisolated static func key(for accountKey: String) -> String {
        keyPrefix + accountKey
    }

    /// Pinned channel ids, first = top of the Pinned section. Sanitized
    /// on load (blanks and duplicates dropped, first occurrence kept).
    @Published public private(set) var orderedIDs: [String]

    /// Backing store; nil = memory only (demo, tests).
    private let defaults: UserDefaults?
    /// Resolved key (nil when memory only).
    public let storageKey: String?

    public init(accountKey: String, defaults: UserDefaults?) {
        self.defaults = defaults
        storageKey = defaults == nil ? nil : Self.key(for: accountKey)
        let raw = storageKey.flatMap { defaults?.stringArray(forKey: $0) } ?? []
        _orderedIDs = Published(initialValue: Self.sanitized(raw))
    }

    /// True when the channel is pinned.
    public func isPinned(_ id: String) -> Bool {
        orderedIDs.contains(id)
    }

    /// Pin (appends to the end). Blank ids and re-pins are no-ops.
    public func pin(_ id: String) {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !orderedIDs.contains(clean) else { return }
        orderedIDs.append(clean)
        save()
    }

    /// Unpin. Unknown ids are a no-op (no write).
    public func unpin(_ id: String) {
        guard let i = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.remove(at: i)
        save()
    }

    /// Pin or unpin.
    public func setPinned(_ id: String, _ on: Bool) {
        if on { pin(id) } else { unpin(id) }
    }

    /// Move one pin to `destination` (index in the list after removal,
    /// clamped). Out-of-range sources are a no-op.
    public func move(from source: Int, to destination: Int) {
        guard orderedIDs.indices.contains(source) else { return }
        var next = orderedIDs
        let id = next.remove(at: source)
        next.insert(id, at: min(max(0, destination), next.count))
        guard next != orderedIDs else { return }
        orderedIDs = next
        save()
    }

    /// Move one pin by id (drag and drop by identity). Unknown ids are a no-op.
    public func move(_ id: String, to destination: Int) {
        guard let i = orderedIDs.firstIndex(of: id) else { return }
        move(from: i, to: destination)
    }

    /// Replace the whole order (drag reorder of the visible section).
    /// Ids not in `ids` keep their relative order after the given ones.
    public func reorder(_ ids: [String]) {
        let head = Self.sanitized(ids).filter { orderedIDs.contains($0) }
        let next = head + orderedIDs.filter { !head.contains($0) }
        guard next != orderedIDs else { return }
        orderedIDs = next
        save()
    }

    /// Demo seed (memory stores only; a persisted store ignores it).
    public func seedDemo(_ ids: [String]) {
        guard defaults == nil else { return }
        orderedIDs = Self.sanitized(ids)
    }

    /// Pinned channels present in `channels`, in pin order (rows the
    /// current fetch lacks are skipped, not dropped from the store).
    public func ordered<C>(_ channels: [C], id: (C) -> String) -> [C] {
        var byID: [String: C] = [:]
        for c in channels where byID[id(c)] == nil { byID[id(c)] = c }
        return orderedIDs.compactMap { byID[$0] }
    }

    nonisolated static func sanitized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private func save() {
        guard let defaults, let storageKey else { return }
        defaults.set(orderedIDs, forKey: storageKey)
    }
}
