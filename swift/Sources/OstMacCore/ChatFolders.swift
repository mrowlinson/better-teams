// ChatFolders.swift — d1-folders: user chat folders + auto-rules.
//
// Client-side only, persisted to UserDefaults (UserPinStore precedent —
// sync API, no file-IO failure modes), zero server calls. One chat lives
// in at most one folder: an explicit manual assignment wins over every
// auto-rule for that chat; otherwise the first matching rule in list
// order wins (NotifyRule list-order precedent). Unassigned chats render
// under "All chats".
//
// Membership derives from chat content at render time (pure
// `FolderResolve`), so ingest/load never migrate anything — a bubbled
// row keeps its folder with no extra write.
import Combine
import Foundation

/// One user-defined chat folder.
public struct ChatFolder: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

/// Group/1:1 chat-kind matcher for auto-rules.
public enum FolderKind: String, Codable, Sendable, Equatable {
    case group
    case direct
}

/// One auto-assign rule: optional matchers OR together (any set matcher
/// hitting assigns the chat to `folderID`). A rule with no matchers
/// never matches; a disabled rule never matches.
public struct FolderRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var folderID: String
    /// Whole-word case-insensitive chat-name match (`re:` = regex,
    /// KeywordMatch precedent; invalid regex never matches). Nil/blank
    /// = matcher off.
    public var namePattern: String?
    /// Case-insensitive sender match (`erin@contoso.com` matches
    /// `contoso.com`). Nil/blank = matcher off.
    public var senderDomain: String?
    /// Group vs 1:1 matcher. Nil = matcher off.
    public var kind: FolderKind?
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString,
        folderID: String,
        namePattern: String? = nil,
        senderDomain: String? = nil,
        kind: FolderKind? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.folderID = folderID
        self.namePattern = namePattern
        self.senderDomain = senderDomain
        self.kind = kind
        self.enabled = enabled
    }

    /// True when at least one matcher can hit (blank patterns count as
    /// off, not as a matcher).
    public var hasMatchers: Bool {
        FolderResolve.isMatcher(namePattern)
            || FolderResolve.isMatcher(senderDomain)
            || kind != nil
    }
}

/// Pure folder resolution. Every branch covered by tests.
public enum FolderResolve {
    /// Folder id for one chat: the manual override first (explicit
    /// wins), else the first matching rule in list order, else nil
    /// (unassigned — renders under "All chats").
    public static func folderFor(
        chat: ChatItem, rules: [FolderRule], overrides: [String: String]
    ) -> String? {
        if let manual = overrides[chat.id] { return manual }
        for rule in rules {
            if matches(chat: chat, rule: rule) { return rule.folderID }
        }
        return nil
    }

    /// True when the rule assigns the chat: enabled, has at least one
    /// live matcher, and any set matcher hits (OR).
    public static func matches(chat: ChatItem, rule: FolderRule) -> Bool {
        guard rule.enabled else { return false }
        guard rule.hasMatchers else { return false }
        if let p = trimmed(rule.namePattern),
           KeywordMatch.contains(chat.name, [p])
        {
            return true
        }
        if let d = trimmed(rule.senderDomain),
           let sender = chat.last_message_sender,
           sender.lowercased().contains(d.lowercased())
        {
            return true
        }
        if let kind = rule.kind {
            switch kind {
            case .group: if chat.is_group { return true }
            case .direct: if !chat.is_group { return true }
            }
        }
        return false
    }

    /// Folder filter stage: nil folder = every chat untouched (same
    /// array, same order); else only chats resolving to `folderID`,
    /// order preserved exactly (filtering never re-sorts).
    public static func filter(
        _ chats: [ChatItem], folderID: String?,
        rules: [FolderRule], overrides: [String: String]
    ) -> [ChatItem] {
        guard let folderID else { return chats }
        return chats.filter {
            folderFor(chat: $0, rules: rules, overrides: overrides) == folderID
        }
    }

    /// Selection after a folder switch: the selection survives when its
    /// chat is still visible, else it clears (never a blind jump —
    /// LeaveSelection precedent).
    public static func selectedAfterSwitch(
        selectedID: String?, visible: [ChatItem]
    ) -> String? {
        guard let selectedID else { return nil }
        return visible.contains(where: { $0.id == selectedID }) ? selectedID : nil
    }

    /// True when the optional pattern is a live matcher (non-blank).
    static func isMatcher(_ pattern: String?) -> Bool {
        trimmed(pattern) != nil
    }

    static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty
        else { return nil }
        return t
    }
}

/// User chat folders + manual assignments + auto-rules, persisted to
/// UserDefaults (UserPinStore precedent: suite-injectable for tests,
/// sanitized load).
///
/// Threading: @MainActor (ObservableObject for the sidebar).
@MainActor
public final class FolderStore: ObservableObject {
    /// UserDefaults keys (public for sanitize/corruption tests).
    public nonisolated static let foldersKey = "omChatFoldersV1"
    public nonisolated static let rulesKey = "omFolderRulesV1"
    public nonisolated static let assignmentsKey = "omFolderAssignV1"
    /// Per-account keys (d1-accounts): default keeps the legacy keys.
    nonisolated public static func foldersKey(for accountID: String) -> String {
        AccountProfile.key(foldersKey, for: accountID)
    }
    nonisolated public static func rulesKey(for accountID: String) -> String {
        AccountProfile.key(rulesKey, for: accountID)
    }
    nonisolated public static func assignmentsKey(for accountID: String) -> String {
        AccountProfile.key(assignmentsKey, for: accountID)
    }

    /// Folders in creation order. Sanitized on load (blank names and
    /// duplicate names case-insensitively dropped, first kept).
    @Published public private(set) var folders: [ChatFolder] = []
    /// Auto-rules in evaluation order (first match wins).
    @Published public private(set) var rules: [FolderRule] = []
    /// Manual chatID → folderID assignments (explicit wins over rules).
    @Published public private(set) var overrides: [String: String] = [:]

    private let defaults: UserDefaults
    private let foldersK: String
    private let rulesK: String
    private let assignmentsK: String

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard,
        accountID: String = AccountProfile.defaultID
    ) {
        self.defaults = defaults
        self.foldersK = Self.foldersKey(for: accountID)
        self.rulesK = Self.rulesKey(for: accountID)
        self.assignmentsK = Self.assignmentsKey(for: accountID)
        let folders = Self.loadFolders(defaults, key: foldersK)
        let ids = Set(folders.map(\.id))
        let rules = Self.loadRules(defaults, folderIDs: ids, key: rulesK)
        let overrides = Self.loadOverrides(defaults, folderIDs: ids, key: assignmentsK)
        _folders = Published(initialValue: folders)
        _rules = Published(initialValue: rules)
        _overrides = Published(initialValue: overrides)
    }

    /// Folder id for one chat (override first, then first matching
    /// rule). Nil = unassigned.
    public func folderID(for chat: ChatItem) -> String? {
        FolderResolve.folderFor(chat: chat, rules: rules, overrides: overrides)
    }

    /// Folder name for one id (nil when unknown).
    public func name(for folderID: String) -> String? {
        folders.first(where: { $0.id == folderID })?.name
    }

    /// Create a folder. Empty/blank and duplicate (case-insensitive,
    /// trimmed) names are refused (nil, no write).
    @discardableResult
    public func createFolder(name: String) -> ChatFolder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard !folders.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(clean) == .orderedSame
        }) else { return nil }
        let folder = ChatFolder(name: clean)
        folders.append(folder)
        saveFolders()
        return folder
    }

    /// Rename a folder. Unknown ids, empty/blank names, and duplicates
    /// (case-insensitive) are refused (false, no write).
    @discardableResult
    public func renameFolder(id: String, name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        guard !folders.contains(where: {
            $0.id != id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(clean) == .orderedSame
        }) else { return false }
        folders[i].name = clean
        saveFolders()
        return true
    }

    /// Delete a folder with its rules and manual assignments.
    /// Unknown ids are a no-op (no write).
    public func deleteFolder(id: String) {
        guard folders.contains(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        rules.removeAll { $0.folderID == id }
        overrides = overrides.filter { $0.value != id }
        saveFolders()
        saveRules()
        saveOverrides()
    }

    /// Manually assign a chat to a folder (nil folder clears the
    /// override, re-exposing any auto-rule match). Unknown folders and
    /// blank chat ids are a no-op (no write).
    public func assign(chatID: String, folderID: String?) {
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let folderID {
            guard folders.contains(where: { $0.id == folderID }) else { return }
            guard overrides[chatID] != folderID else { return }
            overrides[chatID] = folderID
        } else {
            guard overrides[chatID] != nil else { return }
            overrides.removeValue(forKey: chatID)
        }
        saveOverrides()
    }

    /// Append an auto-rule (evaluation order = array order). Rules for
    /// unknown folders are refused (nil, no write).
    @discardableResult
    public func addRule(_ rule: FolderRule) -> FolderRule? {
        guard folders.contains(where: { $0.id == rule.folderID }) else { return nil }
        var clean = rule
        clean.namePattern = FolderResolve.trimmed(rule.namePattern)
        clean.senderDomain = FolderResolve.trimmed(rule.senderDomain)
        rules.append(clean)
        saveRules()
        return clean
    }

    /// Replace an auto-rule by id (order preserved). Unknown ids and
    /// retargets to unknown folders are refused (false, no write).
    @discardableResult
    public func updateRule(_ rule: FolderRule) -> Bool {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return false }
        guard folders.contains(where: { $0.id == rule.folderID }) else { return false }
        var clean = rule
        clean.namePattern = FolderResolve.trimmed(rule.namePattern)
        clean.senderDomain = FolderResolve.trimmed(rule.senderDomain)
        rules[i] = clean
        saveRules()
        return true
    }

    /// Remove an auto-rule. Unknown ids are a no-op (no write).
    public func removeRule(id: String) {
        guard rules.contains(where: { $0.id == id }) else { return }
        rules.removeAll { $0.id == id }
        saveRules()
    }

    /// Enable/disable an auto-rule. Unknown ids are a no-op (no write).
    public func setRuleEnabled(id: String, enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        guard rules[i].enabled != enabled else { return }
        rules[i].enabled = enabled
        saveRules()
    }

    // MARK: - Load (sanitized)

    nonisolated static func loadFolders(
        _ defaults: UserDefaults, key: String = foldersKey
    ) -> [ChatFolder] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ChatFolder].self, from: data)
        else { return [] }
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        var clean: [ChatFolder] = []
        for folder in decoded {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seenIDs.insert(folder.id).inserted else { continue }
            guard seenNames.insert(name.lowercased()).inserted else { continue }
            clean.append(ChatFolder(id: folder.id, name: name))
        }
        return clean
    }

    nonisolated static func loadRules(
        _ defaults: UserDefaults, folderIDs: Set<String>, key: String = rulesKey
    ) -> [FolderRule] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FolderRule].self, from: data)
        else { return [] }
        var seen = Set<String>()
        var clean: [FolderRule] = []
        for rule in decoded {
            guard folderIDs.contains(rule.folderID) else { continue }
            guard seen.insert(rule.id).inserted else { continue }
            var r = rule
            r.namePattern = FolderResolve.trimmed(rule.namePattern)
            r.senderDomain = FolderResolve.trimmed(rule.senderDomain)
            clean.append(r)
        }
        return clean
    }

    nonisolated static func loadOverrides(
        _ defaults: UserDefaults, folderIDs: Set<String>, key: String = assignmentsKey
    ) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var clean: [String: String] = [:]
        for (chatID, value) in raw {
            guard let folderID = value as? String else { continue }
            guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard folderIDs.contains(folderID) else { continue }
            clean[chatID] = folderID
        }
        return clean
    }

    private func saveFolders() {
        defaults.set(try? JSONEncoder().encode(folders), forKey: foldersK)
    }

    private func saveRules() {
        defaults.set(try? JSONEncoder().encode(rules), forKey: rulesK)
    }

    private func saveOverrides() {
        defaults.set(overrides, forKey: assignmentsK)
    }
}
