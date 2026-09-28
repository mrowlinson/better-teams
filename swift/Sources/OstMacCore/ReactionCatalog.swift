// ReactionCatalog.swift — om-react-polish: the more-picker's curated
// emoji catalog (search + categories) and the recents ring.
//
// Why curated, not the system palette: spiked first per the lane brief —
// NSApp.orderFrontCharacterPalette opens fine but is a separate-process
// window (com.apple.CharacterPaletteIM) with no pick-callback API and
// activation-coupled visibility, so a reaction tap cannot reliably get
// its pick back (see tmp/spike-charpalette/). The grid below is plain
// native controls (search field, segmented categories, buttons).
//
// The canonical six (ConversationStore.reactionEmojis) stay the quick
// row. Extended catalog emoji attempt the live send like any other
// (fid-lists D20): a core/server rejection reverts the optimistic add
// and surfaces verbatim, never a client-invented refusal.
import Foundation

/// One searchable emoji: the character + space-separated match keywords.
public struct ReactionEntry: Sendable, Equatable {
    public let emoji: String
    public let keywords: String
    public init(_ emoji: String, _ keywords: String) {
        self.emoji = emoji
        self.keywords = keywords
    }
}

/// Curated more-picker catalog. Every entry is exactly one grapheme
/// cluster (pinned by test).
public enum ReactionCatalog {
    public struct Category: Sendable {
        public let id: String
        public let title: String
        public let entries: [ReactionEntry]
    }

    public static let categories: [Category] = [
        Category(id: "faces", title: "Faces", entries: [
            ReactionEntry("😀", "grin happy smile"),
            ReactionEntry("😁", "beam grin teeth happy"),
            ReactionEntry("😂", "joy laugh tears funny"),
            ReactionEntry("🙂", "smile slight ok"),
            ReactionEntry("😉", "wink joke"),
            ReactionEntry("😍", "hearts eyes love crush"),
            ReactionEntry("🥳", "party celebrate birthday"),
            ReactionEntry("😎", "cool sunglasses confident"),
            ReactionEntry("🥺", "pleading puppy please"),
            ReactionEntry("😢", "cry sad tear"),
            ReactionEntry("😭", "sob bawl cry"),
            ReactionEntry("😮", "surprised wow shock"),
            ReactionEntry("😠", "angry mad rage"),
            ReactionEntry("😴", "sleep tired snore"),
            ReactionEntry("🤯", "explode mind blown shock"),
            ReactionEntry("🥶", "cold freeze ice"),
            ReactionEntry("🤔", "think hmm consider"),
            ReactionEntry("😐", "neutral meh blank"),
            ReactionEntry("🙄", "eyeroll whatever annoyed"),
            ReactionEntry("😇", "angel halo innocent"),
            ReactionEntry("🤠", "cowboy yeehaw"),
            ReactionEntry("😷", "mask sick ill"),
            ReactionEntry("🤢", "sick nauseous gross"),
        ]),
        Category(id: "hands", title: "Hands", entries: [
            ReactionEntry("👍", "like yes approve thumbsup +1"),
            ReactionEntry("👎", "dislike no thumbsdown -1"),
            ReactionEntry("👏", "clap applause bravo"),
            ReactionEntry("🙏", "pray thanks please folded"),
            ReactionEntry("💪", "muscle strong flex power"),
            ReactionEntry("👌", "ok perfect chef kiss"),
            ReactionEntry("✌️", "victory peace two"),
            ReactionEntry("🤝", "handshake deal agree"),
            ReactionEntry("👊", "fist bump punch"),
            ReactionEntry("✊", "fist power solidarity"),
            ReactionEntry("👋", "wave hi bye hello"),
            ReactionEntry("🙌", "hooray celebrate hands up"),
            ReactionEntry("🫶", "heart hands love"),
            ReactionEntry("☝️", "point up one finger"),
            ReactionEntry("👆", "up point finger"),
            ReactionEntry("👇", "down point finger"),
        ]),
        Category(id: "hearts", title: "Hearts", entries: [
            ReactionEntry("❤️", "red heart love like"),
            ReactionEntry("🧡", "orange heart love"),
            ReactionEntry("💛", "yellow heart love gold"),
            ReactionEntry("💚", "green heart love"),
            ReactionEntry("💙", "blue heart love"),
            ReactionEntry("💜", "purple heart love"),
            ReactionEntry("🖤", "black heart dark"),
            ReactionEntry("🤍", "white heart pure"),
            ReactionEntry("💔", "broken heartbreak sad"),
            ReactionEntry("💯", "hundred score perfect"),
            ReactionEntry("💥", "boom collision blast"),
            ReactionEntry("✨", "sparkles new shine magic"),
        ]),
        Category(id: "fun", title: "Fun", entries: [
            ReactionEntry("🎉", "party tada celebrate congrats"),
            ReactionEntry("🎊", "confetti celebrate party"),
            ReactionEntry("⭐", "star favorite rate"),
            ReactionEntry("🌟", "glow star shine"),
            ReactionEntry("🔥", "fire lit hot streak"),
            ReactionEntry("🎂", "birthday cake celebrate"),
            ReactionEntry("🍕", "pizza food lunch"),
            ReactionEntry("☕", "coffee tea break morning"),
            ReactionEntry("🍺", "beer cheers drink friday"),
            ReactionEntry("⚽", "soccer football sport"),
            ReactionEntry("🎮", "game controller play"),
            ReactionEntry("🚀", "rocket ship launch fast"),
            ReactionEntry("💡", "idea bulb lightbulb think"),
            ReactionEntry("📌", "pin pushpin important"),
            ReactionEntry("✅", "check done yes approved"),
            ReactionEntry("❌", "cross no wrong delete"),
            ReactionEntry("❓", "question help what"),
            ReactionEntry("❗", "alert exclaim important"),
        ]),
    ]

    /// Every entry across categories, in category order.
    public static var all: [ReactionEntry] {
        categories.flatMap(\.entries)
    }

    /// Entries for a category id (nil when unknown).
    public static func entries(forCategory id: String) -> [ReactionEntry]? {
        categories.first(where: { $0.id == id })?.entries
    }

    /// True when the catalog carries this exact emoji.
    public static func contains(_ emoji: String) -> Bool {
        all.contains(where: { $0.emoji == emoji })
    }

    /// Case-insensitive AND match over emoji + keywords. Blank query
    /// matches nothing (the grid shows categories instead).
    public static func search(_ query: String) -> [ReactionEntry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return all.filter { e in
            let hay = "\(e.emoji) \(e.keywords)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }
}

/// Most-recently-reacted ring. Pure core (testable) + a thin
/// UserDefaults shell (standard defaults, capped at 12).
/// w4-emoji-recent: ships fully seeded with the global default
/// ranking — fresh users see a full grid, zero empty slots. Own
/// picks move to front and push the lowest-ranked seeds out.
public enum ReactionRecents {
    public static let maxCount = 12
    public nonisolated static let defaultsKey = "om.reactionRecents"

    /// Global default ranking: most-frequently-used emoji first.
    /// Exactly maxCount single graphemes, all in the catalog.
    public static let seed: [String] = [
        "😂", "❤️", "👍", "😍", "🙏", "👏",
        "🎉", "🔥", "😭", "🙌", "💯", "😀",
    ]

    /// Move-to-front add: dedups, newest first, capped.
    public static func withRecorded(_ list: [String], emoji: String) -> [String] {
        var out = [emoji]
        out.append(contentsOf: list.filter { $0 != emoji })
        if out.count > maxCount {
            out = Array(out.prefix(maxCount))
        }
        return out
    }

    /// Per-account key (d1-accounts): default keeps the legacy key.
    public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }

    /// Load recents, dropping stale non-emoji values defensively.
    /// Empty (fresh user) loads the full seed grid.
    public static func load(
        defaults: UserDefaults = .standard,
        accountID: String = AccountProfile.defaultID
    ) -> [String] {
        let raw = defaults.stringArray(forKey: key(for: accountID)) ?? []
        let valid = Array(raw.filter { $0.count == 1 }.prefix(maxCount))
        return valid.isEmpty ? seed : valid
    }

    /// Record one reacted emoji (single graphemes only).
    public static func record(
        _ emoji: String, defaults: UserDefaults = .standard,
        accountID: String = AccountProfile.defaultID
    ) {
        guard emoji.count == 1 else { return }
        defaults.set(
            withRecorded(load(defaults: defaults, accountID: accountID), emoji: emoji),
            forKey: key(for: accountID))
    }
}
