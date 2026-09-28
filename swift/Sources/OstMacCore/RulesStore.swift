// RulesStore.swift — om-notif-settings lane: observable rules config.
//
// Single source of truth for RulesConfig in the app: loads rules.json
// once, publishes the config, and persists every mute/unmute and
// hide/unhide immediately (best-effort save — a failed write keeps the
// in-memory value for the session). AppState reads `config` for its
// per-event rules decisions; Settings binds the per-chat override list
// here and the sidebar the mute/hide context menu.
import Combine
import Foundation

/// Observable RulesConfig: load once, mutate + persist per change.
@MainActor
public final class RulesStore: ObservableObject {
    /// Current config (per-chat mutes included). Published: Settings
    /// rows and AppState decisions read this same value.
    @Published public private(set) var config: RulesConfig

    /// rules.json path (default store location; tests inject a temp path).
    public let path: String

    /// Load best-effort: a missing or unreadable file yields `.default`
    /// (same fallback as RulesConfig.loadBestEffort).
    ///
    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(path: String = RulesConfig.defaultPath) {
        let expanded = NSString(string: path).expandingTildeInPath
        self.path = expanded
        _config = Published(initialValue: RulesConfig.loadBestEffort(from: expanded))
    }

    /// True when the chat is muted in Settings (skipped as "chat-muted").
    public func isMuted(chatID: String) -> Bool {
        config.mutedChatIDs.contains(chatID)
    }

    /// Mute or unmute one chat, persisting immediately. No-ops (same
    /// value) skip the write.
    public func setMuted(chatID: String, muted: Bool) {
        guard !chatID.isEmpty, config.mutedChatIDs.contains(chatID) != muted else { return }
        if muted {
            config.mutedChatIDs.insert(chatID)
        } else {
            config.mutedChatIDs.remove(chatID)
        }
        try? config.save(to: path)
    }

    /// True when the chat is hidden from the sidebar list.
    public func isHidden(chatID: String) -> Bool {
        config.hiddenChatIDs.contains(chatID)
    }

    /// Hide or unhide one chat, persisting immediately. No-ops (same
    /// value) skip the write. Visibility only — banners and unread are
    /// untouched (see RulesConfig.hiddenChatIDs).
    public func setHidden(chatID: String, hidden: Bool) {
        guard !chatID.isEmpty, config.hiddenChatIDs.contains(chatID) != hidden else { return }
        if hidden {
            config.hiddenChatIDs.insert(chatID)
        } else {
            config.hiddenChatIDs.remove(chatID)
        }
        try? config.save(to: path)
    }

    // MARK: per-chat notification level (d2-alerts)

    /// Effective level for one chat (muted wins over mentions-only).
    public func level(chatID: String) -> ChatNotifyLevel {
        config.level(chatID: chatID)
    }

    /// Set one chat's level, persisting immediately. No-ops (same
    /// level) skip the write. Levels are mutually exclusive: setting
    /// one clears the other set.
    public func setLevel(chatID: String, level: ChatNotifyLevel) {
        guard !chatID.isEmpty, config.level(chatID: chatID) != level else { return }
        config.mutedChatIDs.remove(chatID)
        config.mentionOnlyChatIDs.remove(chatID)
        switch level {
        case .all:
            break
        case .mentions:
            config.mentionOnlyChatIDs.insert(chatID)
        case .muted:
            config.mutedChatIDs.insert(chatID)
        }
        try? config.save(to: path)
    }

    // MARK: keyword alerts (d2-alerts)

    /// Add always-notify words (comma/newline-separated input allowed).
    /// Blank input is refused with the existing plainIssue() text (nil
    /// return = accepted). Dupes (any case, across all rules of the
    /// kind) are silent no-ops. Persists on change.
    @discardableResult
    public func addAllowKeyword(_ text: String) -> String? {
        addKeyword(text, kind: NotifyRule.keywordAllow)
    }

    /// Add never-notify words. Same contract as addAllowKeyword.
    @discardableResult
    public func addBlockKeyword(_ text: String) -> String? {
        addKeyword(text, kind: NotifyRule.keywordBlock)
    }

    /// Remove one always-notify word (case-insensitive, from every rule
    /// of the kind). Rules left blank are dropped. Persists on change.
    public func removeAllowKeyword(_ word: String) {
        removeKeyword(word, kind: NotifyRule.keywordAllow)
    }

    /// Remove one never-notify word. Same contract as removeAllowKeyword.
    public func removeBlockKeyword(_ word: String) {
        removeKeyword(word, kind: NotifyRule.keywordBlock)
    }

    /// Turn an on/off rule on or off (Settings ▸ Notifications ▸
    /// Mentions: `noisyChannel`, `nameBackup`). Edits the first rule of
    /// the kind — the one the resolver reads — else appends one.
    /// Persists on change.
    public func setSwitch(_ kind: String, on: Bool) {
        if let idx = config.notifyRules.firstIndex(where: { NotifyRule.canonicalKind($0.kind) == kind }) {
            guard config.notifyRules[idx].enabled != on else { return }
            config.notifyRules[idx].enabled = on
        } else {
            config.notifyRules.append(NotifyRule(kind: kind, enabled: on))
        }
        config.applyRules()
        try? config.save(to: path)
    }

    private func addKeyword(_ text: String, kind: String) -> String? {
        let words = NotifyRule.parseKeywords(text)
        guard !words.isEmpty else {
            return NotifyRule(kind: kind).plainIssue()
        }
        let merged = RulesConfig.mergeKeywords(config.notifyRules, kind: kind)
        let seen = Set(merged.map { $0.lowercased() })
        let fresh = words.filter { !seen.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return nil }
        // Managed rule: first enabled global rule of the kind, else a
        // new appended one (scoped/hand rules keep their own words).
        if let idx = config.notifyRules.firstIndex(where: {
            NotifyRule.canonicalKind($0.kind) == kind && $0.enabled
                && $0.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            let keep = NotifyRule.parseKeywords(config.notifyRules[idx].value)
            config.notifyRules[idx].value = (keep + fresh).joined(separator: ", ")
        } else {
            config.notifyRules.append(NotifyRule(kind: kind, value: fresh.joined(separator: ", ")))
        }
        config.applyRules()
        try? config.save(to: path)
        return nil
    }

    private func removeKeyword(_ word: String, kind: String) {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        var changed = false
        var kept: [NotifyRule] = []
        kept.reserveCapacity(config.notifyRules.count)
        for var rule in config.notifyRules {
            guard NotifyRule.canonicalKind(rule.kind) == kind, rule.enabled else {
                kept.append(rule)
                continue
            }
            let before = NotifyRule.parseKeywords(rule.value)
            let after = before.filter { $0.lowercased() != key }
            if after.count != before.count {
                changed = true
                if after.isEmpty {
                    continue // drop the emptied rule
                }
                rule.value = after.joined(separator: ", ")
            }
            kept.append(rule)
        }
        guard changed else { return }
        config.notifyRules = kept
        config.applyRules()
        try? config.save(to: path)
    }
}
