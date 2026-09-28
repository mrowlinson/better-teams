// NotifyRule.swift — om-rules lane: notify/skip rules store.
//
// Port of TeamsNotifier's TeamsCore/NotifyRule.swift (same kinds, ids,
// tolerant decode, legacy mapping, migration, parsing), adapted for OstMac:
// - `scope`: per-chat scope (comma/line-separated chat-name substrings;
//   blank = global). The filter resolves rules per chat in list order
//   (first in-scope match per kind wins; keyword kinds merge in order).
// - No TeamsCore.Config dependency: migrate() takes plain legacy values.
import Foundation

/// One notify/skip rule: the extensible store behind ChatFilter's gates.
///
/// - `kind`: rule type id. Known ids are plain-language phrases (see
///   `knownKinds`); anything else is a future/custom type: stored,
///   GUI-editable, round-tripped, but not enforced (first in-scope match
///   per kind wins; unknown kinds are ignored by the filter). The four
///   pre-rename ids (`skip-own`, `allow-types`, `skip-edits`, `loud-chat`)
///   still decode: they map to their replacements on load.
/// - `value`: payload. only-these-message-types = comma-separated type
///   heads ("Text, RichText"); noisy-chats-mention-only = chat-name text;
///   always/never-notify-keywords = comma- or line-separated words;
///   the rest ignore it.
/// - `scope`: per-chat scope, comma- or line-separated chat-name
///   substrings ("Watercooler, BTAC"). Blank = global (applies to every
///   chat). A scoped rule only applies to chats whose display name
///   contains one of its entries (case-insensitive). Missing on decode
///   (TeamsNotifier files) means global.
/// - `enabled`: per-rule on/off switch. A disabled (or absent) known
///   rule switches its gate off: own messages and edits notify, the
///   noisy rule stops matching, message-types allows every type (stored
///   in the legacy scalar as `allowAllMarker`). Exception: an ABSENT
///   noisy-chats-channel-mentions / my-name-as-backup rule leaves its
///   gate ON (the hardcoded pre-rules behavior); only a present
///   disabled rule turns those two off.
///
/// Fresh installs keep a BLANK list (= notify everything).
public struct NotifyRule: Codable, Sendable, Equatable {
    public var kind: String
    public var value: String
    public var enabled: Bool
    public var scope: String

    public init(kind: String, value: String = "", enabled: Bool = true, scope: String = "") {
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case kind, value, enabled, scope
    }

    /// Tolerant decode: every key falls back (missing `enabled` means on,
    /// missing `scope` means global). A rule with no kind decodes as kind
    /// "" and is dropped with a warning by normalizeRules(). Pre-rename
    /// kind ids map to their replacements here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        kind = NotifyRule.canonicalKind(rawKind)
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        scope = (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? ""
    }

    /// True when this rule applies to the chat (blank scope = global,
    /// else any scope entry is a case-insensitive substring of the name).
    public func inScope(chatDisplayName: String) -> Bool {
        let scopes = NotifyRule.parseScopes(scope)
        guard !scopes.isEmpty else { return true }
        return scopes.contains {
            chatDisplayName.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    // MARK: kinds

    /// Skip messages sent by the owner. Value ignored.
    public static let skipMyMessages = "skip-my-own-messages"
    /// Message-type heads that notify (value = CSV). Absent/disabled =
    /// every type notifies.
    public static let messageTypes = "only-these-message-types"
    /// Skip MessageUpdate edits. Value ignored. (Enabled = skip, so the
    /// stock off state "notify on edit: no" migrates as enabled.)
    public static let skipEdited = "skip-edited-messages"
    /// Chats whose name contains the value notify only on owner or
    /// channel/Everyone mention.
    public static let noisyChats = "noisy-chats-mention-only"
    /// In noisy chats, channel/@team/@everyone mentions also notify.
    /// Absent = ON (hardcoded pre-rules behavior; deleting the rule
    /// reverts to ON). Disabled = only direct owner mentions notify
    /// there. Value ignored.
    public static let noisyChannel = "noisy-chats-channel-mentions"
    /// When Teams omits sender/mention IDs, fall back to comparing the
    /// owner's display name. Absent = ON (hardcoded pre-rules behavior;
    /// deleting the rule reverts to ON). Disabled = IDs only. Value
    /// ignored.
    public static let nameBackup = "my-name-as-backup"
    /// Messages whose plain text matches one of the value's words
    /// (word-boundary, case-insensitive; `re:` entries are regexes)
    /// always notify, through any filter skip except mute. Loses to
    /// keywordBlock on the same message.
    public static let keywordAllow = "always-notify-keywords"
    /// Messages whose plain text matches one of the value's words
    /// (word-boundary, case-insensitive; `re:` entries are regexes)
    /// never notify, through any filter notify except mute (which
    /// already skips). Beats keywordAllow.
    public static let keywordBlock = "never-notify-keywords"

    /// Known ids, in migration order. The set is open: the GUI kind field
    /// accepts anything, and unknown ids round-trip untouched.
    public static let knownKinds = [skipMyMessages, messageTypes, skipEdited, noisyChats, noisyChannel, nameBackup, keywordAllow, keywordBlock]

    /// Kinds migrate() writes: the six legacy-mapped gates, in
    /// knownKinds order. The keyword kinds are NEVER migrated (the
    /// owner term list is not yet known): existing installs get no
    /// keyword rules, fresh installs stay blank, and the owner adds
    /// terms via the GUI.
    public static let migratedKinds = [skipMyMessages, messageTypes, skipEdited, noisyChats, noisyChannel, nameBackup]

    /// Pre-rename ids -> replacements. Applied on decode (and to GUI
    /// input), so old stored configs keep working unchanged.
    public static let legacyKinds = [
        "skip-own": skipMyMessages,
        "allow-types": messageTypes,
        "skip-edits": skipEdited,
        "loud-chat": noisyChats,
    ]

    /// Map a pre-rename id to its replacement; anything else passes
    /// through untouched (unknown/custom kinds included).
    public static func canonicalKind(_ kind: String) -> String {
        legacyKinds[kind] ?? kind
    }

    /// Plain-English display name per known kind; the GUI picker shows
    /// these while storing the ids underneath. Legacy ids resolve to
    /// their replacement's name; custom kinds show as-is.
    public static func displayName(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Skip my own messages"
        case messageTypes: "Only these message types"
        case skipEdited: "Skip edited messages"
        case noisyChats: "Noisy chats mention only"
        case noisyChannel: "Noisy chats channel mentions"
        case nameBackup: "My name as backup"
        case keywordAllow: "Always notify keywords"
        case keywordBlock: "Never notify keywords"
        default: kind
        }
    }

    /// Display names in knownKinds order (the picker's item list).
    public static var knownDisplayNames: [String] {
        knownKinds.map(displayName(for:))
    }

    /// Map picker text back to a stored id: a display name (exact, else
    /// case-insensitive) becomes its kind id; anything else passes
    /// through canonicalKind, so pasted ids (legacy included) and
    /// custom kinds keep working.
    public static func kind(fromDisplayName text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = knownKinds.first(where: { displayName(for: $0) == trimmed }) {
            return hit
        }
        if let hit = knownKinds.first(where: {
            displayName(for: $0).caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return hit
        }
        return canonicalKind(trimmed)
    }

    /// notifyTypes value meaning "every type notifies". Written by the
    /// rules sync when the message-types rule is absent/disabled; honored
    /// by ChatFilter's type gate. Never appears in legacy files.
    public static let allowAllMarker = "*"

    /// Editor hint per kind; unknown kinds get the generic line. Legacy
    /// ids resolve to their replacement's hint.
    public static func hint(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "On: skip messages you sent. Value ignored."
        case messageTypes: "Value: message types that notify, e.g. Text, RichText. Off: every type notifies (typing, member notices, calls too)."
        case skipEdited: "On: skip edited messages. Off: edits notify. Value ignored."
        case noisyChats: "Value: chat-name text, e.g. Watercooler. Matching chats notify only when you are mentioned."
        case noisyChannel: "On: @channel/@team/@everyone also notify in noisy chats. Off: only your direct mentions do. Deleting this rule turns it back on. Value ignored."
        case nameBackup: "On: when Teams omits sender/mention IDs, match by your display name. Off: IDs only. Deleting this rule turns it back on. Value ignored."
        case keywordAllow: "Value: words that always notify, e.g. outage, urgent. Case-insensitive whole words (outage skips outages); re: prefix is a regex. Loses to never-notify words."
        case keywordBlock: "Value: words that never notify, e.g. lunch, kudos. Case-insensitive whole words (outage skips outages); re: prefix is a regex. Beats always-notify words."
        default: "Custom type: stored and round-tripped, not enforced yet."
        }
    }

    /// Editor hint for the scope field (same for every kind).
    public static let scopeHint = "Scope: chat-name text limiting this rule, e.g. Watercooler. Blank = every chat."

    /// Plain-language label for the value field per kind.
    public static func valueLabel(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Types:"
        case noisyChats: "Chat text:"
        case keywordAllow, keywordBlock: "Words:"
        default: "Value:"
        }
    }

    /// Example text for the value field per kind.
    public static func valuePlaceholder(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Text, RichText"
        case noisyChats: "Watercooler"
        case keywordAllow: "outage, urgent"
        case keywordBlock: "lunch, kudos"
        default: "(ignored)"
        }
    }

    /// Whether the kind reads its value (the value field disables
    /// otherwise).
    public static func usesValue(_ kind: String) -> Bool {
        switch canonicalKind(kind) {
        case messageTypes, noisyChats, keywordAllow, keywordBlock: true
        default: false
        }
    }

    // MARK: editor UX (display only; zero behavior/decode effect)

    /// One Add-picker row: pick by GOAL in plain words. `does` is the
    /// full-sentence WHAT IT DOES, `example` a concrete case ("" when
    /// the kind ignores its value).
    public struct GoalOption: Sendable, Equatable {
        public var kind: String
        public var goal: String
        public var does: String
        public var example: String
    }

    /// Goal rows in knownKinds order; the GUI appends a Custom row.
    /// Each option's kind is its stored id (goal-pick maps 1:1).
    public static var goalOptions: [GoalOption] {
        knownKinds.map {
            GoalOption(kind: $0, goal: goalTitle(for: $0), does: explanation(for: $0), example: exampleText(for: $0))
        }
    }

    /// Plain-words goal title per kind (the Add picker's row title).
    public static func goalTitle(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Skip messages I sent myself"
        case messageTypes: "Only some message types notify"
        case skipEdited: "Skip edited-message notices"
        case noisyChats: "Quiet down noisy chats"
        case noisyChannel: "Let channel mentions through in noisy chats"
        case nameBackup: "Match my name when Teams omits IDs"
        case keywordAllow: "Always notify on certain words"
        case keywordBlock: "Never notify on certain words"
        default: "Custom rule of my own"
        }
    }

    /// Full-sentence WHAT IT DOES per kind (2-3 lines max in the
    /// editor). Unknown kinds get the custom fallback.
    public static func explanation(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Messages you sent never notify. Use this to silence your own echoes in busy chats."
        case messageTypes: "Only the listed message types notify; everything else stays silent."
        case skipEdited: "Edited messages stay silent. Turn it off if you want edits to notify."
        case noisyChats: "Chats whose name matches your text notify only when you are mentioned."
        case noisyChannel: "Channel, team and everyone mentions also notify in noisy chats. Turn it off for direct mentions only. Deleting this rule turns it back on."
        case nameBackup: "When Teams omits sender and mention IDs, match by your display name instead. Turn it off for IDs only. Deleting this rule turns it back on."
        case keywordAllow: "Messages containing your words always notify, even in noisy chats or skipped types. Matching is case-insensitive whole words; a re: entry is a regex."
        case keywordBlock: "Messages containing your words stay silent, even when they would otherwise notify. Matching is case-insensitive whole words; a re: entry is a regex. Wins over always-notify words."
        default: "Custom type: stored and round-tripped, not enforced yet. A future update may implement it."
        }
    }

    /// Concrete example per kind; "" when the kind ignores its value
    /// (the GUI hides the example line then).
    public static func exampleText(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Types “Text, RichText” notify for plain and formatted messages only."
        case noisyChats: "Chat text “Watercooler” quiets “Watercooler Chat” except for your mentions."
        case keywordAllow: "Words “outage, urgent” notify even in noisy chats."
        case keywordBlock: "Words “lunch, kudos” silence the birthday threads."
        default: ""
        }
    }

    /// Starter value for a rule added from the goal picker. A generic
    /// example, so picked rules are valid immediately.
    public static func defaultValue(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Text, RichText"
        case noisyChats: "Watercooler"
        case keywordAllow: "outage, urgent"
        case keywordBlock: "lunch, kudos"
        default: ""
        }
    }

    /// What this rule does, in words (the table row text). Includes
    /// the value where the kind reads one; never shows raw ids. A
    /// non-blank scope appends a limiter note.
    public static func sentence(for rule: NotifyRule) -> String {
        let v = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = switch canonicalKind(rule.kind.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case skipMyMessages: "Skip messages you sent."
        case messageTypes:
            v.isEmpty ? "Only these message types notify (needs a value)." : "Only these message types notify: \(v)."
        case skipEdited: "Skip edited messages."
        case noisyChats:
            v.isEmpty ? "Noisy chats notify only on mention (needs chat text)." : "Chats matching “\(v)” notify only on mention."
        case noisyChannel: "Channel mentions also notify in noisy chats."
        case nameBackup: "Match by your display name when IDs are missing."
        case keywordAllow:
            v.isEmpty ? "Always notify on certain words (needs words)." : "Messages containing “\(v)” always notify."
        case keywordBlock:
            v.isEmpty ? "Never notify on certain words (needs words)." : "Messages containing “\(v)” never notify."
        default:
            v.isEmpty ? "Custom rule “\(rule.kind)” (stored, not enforced yet)." : "Custom rule “\(rule.kind)” = “\(v)” (stored, not enforced yet)."
        }
        let s = rule.scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? base : "\(base) Only in chats matching “\(s)”."
    }

    /// Blank-state teaching text (shown when the list is empty): what
    /// rules are, that blank = notify everything, how to add one.
    public static let blankStateText = """
        Rules decide what notifies. Each rule either quiets something (skip) or narrows what gets through.
        A blank list means every message notifies.
        Click Add, pick a goal in plain words, fill in the value, then Save.
        """

    // MARK: validation + parsing

    /// Nil when valid, else a human-readable reason. Unknown kinds are
    /// always valid (extensible payload); known kinds needing a value
    /// must have a non-blank one. Scope is free text (never invalid).
    /// Legacy ids validate as their replacement (tolerant: decode
    /// already canonicalizes).
    public func issue() -> String? {
        let k = NotifyRule.canonicalKind(kind.trimmingCharacters(in: .whitespacesAndNewlines))
        if k.isEmpty { return "rule has no type" }
        switch k {
        case NotifyRule.messageTypes where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "only-these-message-types rule needs a value (e.g. Text, RichText)"
        case NotifyRule.noisyChats where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "noisy-chats-mention-only rule needs chat-name text (e.g. Watercooler)"
        case NotifyRule.keywordAllow where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "always-notify-keywords rule needs words (e.g. outage, urgent)"
        case NotifyRule.keywordBlock where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "never-notify-keywords rule needs words (e.g. lunch, kudos)"
        default:
            return nil
        }
    }

    public var isValid: Bool { issue() == nil }

    /// Same validity as issue(), but worded for the editor: display
    /// names instead of raw ids, plus a fix hint. GUI-only; normalize
    /// warnings keep issue().
    public func plainIssue() -> String? {
        let k = NotifyRule.canonicalKind(kind.trimmingCharacters(in: .whitespacesAndNewlines))
        if k.isEmpty { return "This rule has no type yet. Pick a Kind above, or type a custom name." }
        switch k {
        case NotifyRule.messageTypes where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.messageTypes))” needs a value, e.g. Text, RichText."
        case NotifyRule.noisyChats where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.noisyChats))” needs chat-name text, e.g. Watercooler."
        case NotifyRule.keywordAllow where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.keywordAllow))” needs words, e.g. outage, urgent."
        case NotifyRule.keywordBlock where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.keywordBlock))” needs words, e.g. lunch, kudos."
        default:
            return nil
        }
    }

    /// "Text, RichText" -> ["Text", "RichText"]. Trims pieces, drops
    /// empties ("a,,b" -> ["a","b"]).
    public static func parseTypes(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// "outage, urgent\nsev1" -> ["outage", "urgent", "sev1"].
    /// Splits on commas or line breaks, trims pieces, drops empties.
    public static func parseKeywords(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "Watercooler, BTAC" -> ["Watercooler", "BTAC"]. Same splitting
    /// as keywords; blank scope parses to [] (global).
    public static func parseScopes(_ scope: String) -> [String] {
        parseKeywords(scope)
    }

    // MARK: migration

    /// Legacy scalars -> the stock rules. Always returns migratedKinds
    /// (the six legacy-mapped kinds); `notifyOnEdit` maps to inverted
    /// skip-edited-messages. The two boolean-only gates (noisy channel
    /// mentions, name backup) migrate enabled, matching the hardcoded
    /// behavior. Keyword kinds are NEVER migrated. Scopes are blank
    /// (global).
    public static func migrate(skipOwn: Bool, notifyOnEdit: Bool, types: [String], loud: String) -> [NotifyRule] {
        [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: skipOwn),
            NotifyRule(kind: NotifyRule.messageTypes, value: types.joined(separator: ", "), enabled: true),
            NotifyRule(kind: NotifyRule.skipEdited, enabled: !notifyOnEdit),
            NotifyRule(kind: NotifyRule.noisyChats, value: loud, enabled: true),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: true),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: true),
        ]
    }
}
