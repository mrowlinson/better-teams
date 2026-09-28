// RulesConfig.swift — om-rules lane: notify/skip configuration.
//
// Minimal TeamsNotifier-shaped config: the owner block, the filter
// scalars, and the notifyRules list that drives them. Deliberately
// WITHOUT the mute schedule, migration flags, and observability — the
// app sets `muted` directly and file problems fall back to defaults.
//
// Resolution is per chat: `effective(forChat:)` filters the list to the
// in-scope rules (blank scope = global) in list order, then resolves
// each gate from the first in-scope match — except keyword kinds, which
// merge across ALL in-scope rules in order (deduped, first occurrence
// wins). Absent gates keep TeamsNotifier's absent-defaults (notably:
// blank list = notify everything; noisy-channel/name-backup absent = ON).
import Foundation

/// Owner identity: display name (mention/own-message backup signal) and
/// Skype MRI `8:orgid:{oid}` (preferred signal, learned from Graph /me).
public struct RulesOwner: Codable, Sendable, Equatable {
    public var displayName: String
    public var mri: String

    public init(displayName: String = "", mri: String = "") {
        self.displayName = displayName
        self.mri = mri
    }
}

/// Resolved gates for one chat: what ChatFilter actually reads. Always
/// derived from a RulesConfig via `effective(forChat:)` (or `applyRules`
/// for the global view) — never stored.
public struct EffectiveRules: Sendable, Equatable {
    public var ownerDisplayName: String
    public var loudSubstring: String
    public var notifyOnEdit: Bool
    public var skipOwnMessages: Bool
    public var noisyChannelMentions: Bool
    public var matchByDisplayName: Bool
    public var notifyTypes: [String]
    public var allowKeywords: [String]
    public var blockKeywords: [String]
    public var muted: Bool
    /// OstMac per-chat mutes (chat ids). Pass-through from the stored
    /// config (not rule-owned): the filter skips these chats entirely.
    public var mutedChatIDs: Set<String>
    /// OstMac per-chat mentions-only (chat ids). Pass-through from the
    /// stored config (not rule-owned): these chats notify only on
    /// mention (noisy-rule semantics, scoped per chat).

    public var mentionOnlyChatIDs: Set<String>

    public init(
        ownerDisplayName: String = "",
        loudSubstring: String = "",
        notifyOnEdit: Bool = true,
        skipOwnMessages: Bool = false,
        noisyChannelMentions: Bool = true,
        matchByDisplayName: Bool = true,
        notifyTypes: [String] = [NotifyRule.allowAllMarker],
        allowKeywords: [String] = [],
        blockKeywords: [String] = [],
        muted: Bool = false,
        mutedChatIDs: Set<String> = [],
        mentionOnlyChatIDs: Set<String> = []
    ) {
        self.ownerDisplayName = ownerDisplayName
        self.loudSubstring = loudSubstring
        self.notifyOnEdit = notifyOnEdit
        self.skipOwnMessages = skipOwnMessages
        self.noisyChannelMentions = noisyChannelMentions
        self.matchByDisplayName = matchByDisplayName
        self.notifyTypes = notifyTypes
        self.allowKeywords = allowKeywords
        self.blockKeywords = blockKeywords
        self.muted = muted
        self.mutedChatIDs = mutedChatIDs
        self.mentionOnlyChatIDs = mentionOnlyChatIDs
    }
}

/// Per-chat notification level (d2-alerts): the Settings + sidebar
/// 3-state picker over the stored mute/mentions-only sets. Muted wins
/// when a chat sits in both (setLevel never leaves that state).
public enum ChatNotifyLevel: String, Codable, Sendable, Equatable, CaseIterable {
    /// Every notifiable message banners.
    case all
    /// Only mentions banner (noisy-rule semantics, scoped to the chat).
    case mentions
    /// Absolute: no banner, no breakthrough. Row unread still
    /// accrues (bold) but stays out of the dock total (fid-lists D19).
    case muted

    /// Picker/menu row title (shared by Settings + sidebar).
    public var displayName: String {
        switch self {
        case .all: "All"
        case .mentions: "Mentions only"
        case .muted: "Muted"
        }
    }
}

public struct RulesConfig: Codable, Sendable, Equatable {
    public var owner: RulesOwner
    /// Case-insensitive substring; matching chats only notify on owner or
    /// channel/Everyone mention. Derived from the rules (see applyRules).
    public var loudSubstring: String
    /// Notify on MessageUpdate edits. Derived from the rules.
    public var notifyOnEdit: Bool
    /// Skip messages sent by the owner. Derived from the rules.
    public var skipOwnMessages: Bool
    /// In noisy (mention-only) chats, @channel/@team/@everyone mentions
    /// also notify. Derived from the rules.
    public var noisyChannelMentions: Bool
    /// When Teams omits sender/mention IDs, fall back to comparing the
    /// owner's display name. Derived from the rules.
    public var matchByDisplayName: Bool
    /// Message types that notify (first messagetype segment, e.g. "Text").
    /// Derived from the rules (`["*"]` = every type).
    public var notifyTypes: [String]
    /// Words that force NOTIFY (word-boundary, case-insensitive; `re:`
    /// entries are regexes). Derived from the rules.
    public var allowKeywords: [String]
    /// Words that force SKIP. Beats allowKeywords. Derived from the rules.
    public var blockKeywords: [String]
    /// Global mute flag. NOT rule-owned: the app sets the effective
    /// value per message; the stored value is the default. Persisted
    /// as-is.
    public var muted: Bool
    /// OstMac per-chat mutes (chat ids), edited in Settings. NOT
    /// rule-owned (like `muted`): persisted as-is, resolved into every
    /// EffectiveRules, skipped by the filter with reason "chat-muted".
    public var mutedChatIDs: Set<String>
    /// OstMac per-chat mentions-only (chat ids), edited in Settings +
    /// the sidebar level picker. NOT rule-owned (like `muted`):
    /// persisted as-is, resolved into every EffectiveRules, gated by
    /// the filter with noisy-rule semantics scoped to the chat.
    public var mentionOnlyChatIDs: Set<String>
    /// OstMac hidden chats (chat ids), edited in the sidebar context
    /// menu. List-visibility ONLY: persisted as-is, never resolved into
    /// EffectiveRules, never read by ChatFilter — hidden threads keep
    /// their banners and unread until restored via Show hidden.
    public var hiddenChatIDs: Set<String>
    /// Notify/skip rules (the extensible store behind the gates above).
    /// Blank = notify everything. Edited in the GUI and persisted here.
    public var notifyRules: [NotifyRule]

    public init(
        owner: RulesOwner = RulesOwner(),
        loudSubstring: String = "",
        notifyOnEdit: Bool = false,
        skipOwnMessages: Bool = true,
        noisyChannelMentions: Bool = true,
        matchByDisplayName: Bool = true,
        notifyTypes: [String] = ["Text", "RichText"],
        allowKeywords: [String] = [],
        blockKeywords: [String] = [],
        muted: Bool = false,
        mutedChatIDs: Set<String> = [],
        mentionOnlyChatIDs: Set<String> = [],
        hiddenChatIDs: Set<String> = [],
        notifyRules: [NotifyRule] = []
    ) {
        self.owner = owner
        self.loudSubstring = loudSubstring
        self.notifyOnEdit = notifyOnEdit
        self.skipOwnMessages = skipOwnMessages
        self.noisyChannelMentions = noisyChannelMentions
        self.matchByDisplayName = matchByDisplayName
        self.notifyTypes = notifyTypes
        self.allowKeywords = allowKeywords
        self.blockKeywords = blockKeywords
        self.muted = muted
        self.mutedChatIDs = mutedChatIDs
        self.mentionOnlyChatIDs = mentionOnlyChatIDs
        self.hiddenChatIDs = hiddenChatIDs
        self.notifyRules = notifyRules
    }

    /// Effective level for one chat: muted wins, then mentions-only.
    public func level(chatID: String) -> ChatNotifyLevel {
        if mutedChatIDs.contains(chatID) { return .muted }
        if mentionOnlyChatIDs.contains(chatID) { return .mentions }
        return .all
    }

    enum CodingKeys: String, CodingKey {
        case owner, loudSubstring, notifyOnEdit, skipOwnMessages, notifyTypes, muted
        case noisyChannelMentions, matchByDisplayName
        case allowKeywords, blockKeywords
        case mutedChatIDs
        case mentionOnlyChatIDs
        case hiddenChatIDs
        case notifyRules
    }

    /// Tolerant decode: missing keys fall back to defaults, then the
    /// scalars sync FROM the rules (the list is the source of truth;
    /// stored scalars are informational only).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RulesConfig()
        owner = (try? c.decodeIfPresent(RulesOwner.self, forKey: .owner)) ?? d.owner
        loudSubstring = (try? c.decodeIfPresent(String.self, forKey: .loudSubstring)) ?? d.loudSubstring
        notifyOnEdit = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnEdit)) ?? d.notifyOnEdit
        skipOwnMessages = (try? c.decodeIfPresent(Bool.self, forKey: .skipOwnMessages)) ?? d.skipOwnMessages
        noisyChannelMentions = (try? c.decodeIfPresent(Bool.self, forKey: .noisyChannelMentions)) ?? d.noisyChannelMentions
        matchByDisplayName = (try? c.decodeIfPresent(Bool.self, forKey: .matchByDisplayName)) ?? d.matchByDisplayName
        notifyTypes = (try? c.decodeIfPresent([String].self, forKey: .notifyTypes)) ?? d.notifyTypes
        allowKeywords = (try? c.decodeIfPresent([String].self, forKey: .allowKeywords)) ?? d.allowKeywords
        blockKeywords = (try? c.decodeIfPresent([String].self, forKey: .blockKeywords)) ?? d.blockKeywords
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
        mutedChatIDs = (try? c.decodeIfPresent(Set<String>.self, forKey: .mutedChatIDs)) ?? d.mutedChatIDs
        mentionOnlyChatIDs = (try? c.decodeIfPresent(Set<String>.self, forKey: .mentionOnlyChatIDs)) ?? d.mentionOnlyChatIDs
        hiddenChatIDs = (try? c.decodeIfPresent(Set<String>.self, forKey: .hiddenChatIDs)) ?? d.hiddenChatIDs
        notifyRules = (try? c.decodeIfPresent([NotifyRule].self, forKey: .notifyRules)) ?? []
        applyRules()
    }

    /// Sync the filter scalars FROM the stored rules (global view: every
    /// rule counts regardless of scope). First match per kind wins;
    /// keyword kinds merge across all rules in order. Unknown kinds are
    /// preserved untouched. Absent/disabled rules switch their gate off
    /// (message-types then allows every type via the "*" marker) —
    /// EXCEPT noisy-chats-channel-mentions and my-name-as-backup, whose
    /// ABSENT default is ON: only a present disabled rule turns them off.
    /// `muted`, `mutedChatIDs`, `mentionOnlyChatIDs`, `hiddenChatIDs`
    /// and `owner` are NOT touched (not rule-owned).
    public mutating func applyRules() {
        let eff = Self.resolve(
            notifyRules, ownerDisplayName: owner.displayName, muted: muted,
            mutedChatIDs: mutedChatIDs,
            mentionOnlyChatIDs: mentionOnlyChatIDs)
        loudSubstring = eff.loudSubstring
        notifyOnEdit = eff.notifyOnEdit
        skipOwnMessages = eff.skipOwnMessages
        noisyChannelMentions = eff.noisyChannelMentions
        matchByDisplayName = eff.matchByDisplayName
        notifyTypes = eff.notifyTypes
        allowKeywords = eff.allowKeywords
        blockKeywords = eff.blockKeywords
    }

    /// Resolve the gates for one chat: only in-scope rules (blank scope
    /// = global) participate, in list order. First in-scope match per
    /// kind wins; keyword kinds merge across all in-scope rules in
    /// order (deduped). Absent gates keep the applyRules() defaults.
    public func effective(forChat chatDisplayName: String) -> EffectiveRules {
        let scoped = notifyRules.filter { $0.inScope(chatDisplayName: chatDisplayName) }
        return Self.resolve(
            scoped, ownerDisplayName: owner.displayName, muted: muted,
            mutedChatIDs: mutedChatIDs,
            mentionOnlyChatIDs: mentionOnlyChatIDs)
    }

    /// Shared resolver over an ordered rule slice (global = whole list,
    /// per-chat = in-scope subset). Pure.
    static func resolve(
        _ rules: [NotifyRule], ownerDisplayName: String, muted: Bool,
        mutedChatIDs: Set<String>, mentionOnlyChatIDs: Set<String> = []
    ) -> EffectiveRules {
        func first(_ kind: String) -> NotifyRule? {
            rules.first(where: { NotifyRule.canonicalKind($0.kind) == kind })
        }
        var eff = EffectiveRules(
            ownerDisplayName: ownerDisplayName, muted: muted,
            mutedChatIDs: mutedChatIDs,
            mentionOnlyChatIDs: mentionOnlyChatIDs)
        if let r = first(NotifyRule.skipMyMessages) {
            eff.skipOwnMessages = r.enabled
        } else {
            eff.skipOwnMessages = false
        }
        if let r = first(NotifyRule.skipEdited) {
            eff.notifyOnEdit = !r.enabled
        } else {
            eff.notifyOnEdit = true
        }
        if let r = first(NotifyRule.noisyChats),
           r.enabled, !r.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            eff.loudSubstring = r.value
        } else {
            eff.loudSubstring = ""
        }
        if let r = first(NotifyRule.messageTypes), r.enabled {
            let types = NotifyRule.parseTypes(r.value)
            eff.notifyTypes = types.isEmpty ? [NotifyRule.allowAllMarker] : types
        } else {
            eff.notifyTypes = [NotifyRule.allowAllMarker]
        }
        // Absent = ON (hardcoded pre-rules behavior): only a present
        // disabled rule switches these gates off (explicit wins).
        if let r = first(NotifyRule.noisyChannel) {
            eff.noisyChannelMentions = r.enabled
        } else {
            eff.noisyChannelMentions = true
        }
        if let r = first(NotifyRule.nameBackup) {
            eff.matchByDisplayName = r.enabled
        } else {
            eff.matchByDisplayName = true
        }
        // Keyword gates merge across ALL in-scope rules in list order
        // (deduped, first occurrence wins); absent/disabled/blank = off.
        eff.allowKeywords = mergeKeywords(rules, kind: NotifyRule.keywordAllow)
        eff.blockKeywords = mergeKeywords(rules, kind: NotifyRule.keywordBlock)
        return eff
    }

    /// Ordered merge of one keyword kind over the rule slice: every
    /// enabled rule contributes its parsed words in list order, deduped
    /// case-insensitively (first spelling wins).
    static func mergeKeywords(_ rules: [NotifyRule], kind: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for r in rules where NotifyRule.canonicalKind(r.kind) == kind && r.enabled {
            for w in NotifyRule.parseKeywords(r.value) {
                let key = w.lowercased()
                if seen.insert(key).inserted { out.append(w) }
            }
        }
        return out
    }

    /// Drop unusable rules (no kind; known kind with a blank value where
    /// one is required). Returns human-readable lines per drop (the app
    /// surfaces them; RulesConfig itself never logs). Unknown kinds are
    /// kept (extensible payload). No re-sync needed: resolve() already
    /// treats blank values as gate-off, so dropping changes nothing.
    @discardableResult
    public mutating func normalizeRules() -> [String] {
        var warnings: [String] = []
        var kept: [NotifyRule] = []
        kept.reserveCapacity(notifyRules.count)
        for r in notifyRules {
            if let problem = r.issue() {
                warnings.append("bad notifyRules (\(problem), rule \(r.kind.isEmpty ? "(no type)" : r.kind), dropped)")
            } else {
                kept.append(r)
            }
        }
        notifyRules = kept
        return warnings
    }

    /// Fresh-install config: empty owner, blank rules = notify everything
    /// (same sync the decode path runs, so the scalars agree with the
    /// blank list).
    public static var `default`: RulesConfig {
        var c = RulesConfig()
        c.applyRules()
        return c
    }

    public static var defaultPath: String {
        UnixConfig.defaultPath(for: "rules.json")
    }

    /// Load from path; missing or unreadable file yields `.default`.
    /// Never throws (file problems silently fall back — minimal config,
    /// no observability).
    public static func loadBestEffort(from path: String = RulesConfig.defaultPath) -> RulesConfig {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              var cfg = try? JSONDecoder().decode(RulesConfig.self, from: data)
        else { return RulesConfig.default }
        _ = cfg.normalizeRules()
        cfg.applyRules()
        return cfg
    }

    public func save(to path: String = RulesConfig.defaultPath) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
