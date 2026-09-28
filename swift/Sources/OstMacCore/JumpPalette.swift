// JumpPalette.swift — om-cmdk lane: fuzzy jump-to targets + matcher.
// Pure model (no SwiftUI): JumpTarget rows built from chats + teams,
// FuzzyMatch subsequence scoring + ranked filter. The view lives in
// JumpPaletteView.swift; App.swift sheets it on Cmd+K.
import Foundation

/// One jump destination: a chat, a 1:1 chat, a channel, or a team.
public struct JumpTarget: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case chat
        case oneToOne
        case channel
        case team
    }

    /// Stable row id (chat id, channel id, or team id).
    public let id: String
    /// Conversation id to open, nil when not openable (channel-less team).
    public let openID: String?
    /// Display name passed to open().
    public let openName: String
    public let title: String
    public let subtitle: String
    public let kind: Kind

    public init(
        id: String, openID: String?, openName: String,
        title: String, subtitle: String, kind: Kind
    ) {
        self.id = id
        self.openID = openID
        self.openName = openName
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

/// Palette search scope (gap-g6g7: sticky via `SearchRecentsStore`).
public enum JumpPaletteScope: String, Sendable {
    case chats
    case messages
}

/// Forward destinations (om-copyforward): the jump rows narrowed to
/// chats and channels that can receive a forward. Channel-less team
/// rows are dropped (nothing to post to), so the forward sheet never
/// shows a disabled row.
public enum ForwardPicker {
    public static func targets(chats: [ChatItem], teams: [TeamItem]) -> [JumpTarget] {
        JumpTargets.build(chats: chats, teams: teams).filter { $0.openID != nil }
    }
}

/// Builds palette rows: chats, then channels (team-qualified), then teams
/// (open their first channel; nil when the team has no channels).
public enum JumpTargets {
    public static func build(chats: [ChatItem], teams: [TeamItem]) -> [JumpTarget] {
        var out: [JumpTarget] = []
        for c in chats {
            out.append(JumpTarget(
                id: c.id, openID: c.id, openName: c.name,
                title: c.name, subtitle: c.is_group ? "Group chat" : "Chat",
                kind: c.is_group ? .chat : .oneToOne))
        }
        for t in teams {
            for ch in t.channels {
                out.append(JumpTarget(
                    id: ch.id, openID: ch.id,
                    openName: "\(t.name) > #\(ch.name)",
                    title: "#\(ch.name)", subtitle: t.name,
                    kind: .channel))
            }
        }
        for t in teams {
            let first = t.channels.first
            out.append(JumpTarget(
                id: t.id, openID: first?.id,
                openName: first.map { "\(t.name) > #\($0.name)" } ?? t.name,
                title: t.name,
                subtitle: t.channels.isEmpty ? "Team · no channels"
                    : "Team · \(t.channels.count) channel\(t.channels.count == 1 ? "" : "s")",
                kind: .team))
        }
        return out
    }
}

/// Subsequence fuzzy match. Score is higher for better matches; nil when
/// the query is not a subsequence of the target (no match).
///
/// +10 per matched char, +8 when the match starts a word, +4 for an
/// exact-case match, +2 per adjacency with the previous match, −1 per
/// skipped char. Case-insensitive.
public enum FuzzyMatch {
    public static func score(query: String, target: String) -> Int? {
        let q = Array(query)
        guard !q.isEmpty else { return 0 }
        let t = Array(target)
        var qi = 0
        var total = 0
        var prevMatch = -2
        var ti = 0
        while ti < t.count, qi < q.count {
            let qc = q[qi]
            // Scan forward for the next query char (case-insensitive).
            var found: Int?
            var j = ti
            while j < t.count {
                if t[j].lowercased() == qc.lowercased() { found = j; break }
                j += 1
            }
            guard let m = found else { return nil }
            total -= (m - ti) // skipped chars
            total += 10
            if m == 0 || t[m - 1] == " " || t[m - 1] == "-" || t[m - 1] == "_" || t[m - 1] == ">" || t[m - 1] == "#" {
                total += 8 // word-boundary start
            }
            if String(t[m]) == String(qc) { total += 4 } // exact case
            if m == prevMatch + 1 { total += 2 } // adjacency
            prevMatch = m
            ti = m + 1
            qi += 1
        }
        return qi == q.count ? total : nil
    }

    /// Targets matching `query`, best first (ties keep input order).
    /// Empty query returns all targets in order. Matches against the
    /// title, then both team-qualified orders, so "eng ship" finds
    /// Engineering > #Shipping either way round. Qualified hits rank
    /// below direct title hits.
    public static func ranked(_ targets: [JumpTarget], query: String) -> [JumpTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return targets }
        var scored: [(Int, Int, JumpTarget)] = []
        for (i, t) in targets.enumerated() {
            let candidates = [
                (t.title, 0),
                ("\(t.subtitle) \(t.title)", -5),
                ("\(t.title) \(t.subtitle)", -5),
            ]
            for (cand, penalty) in candidates {
                if let s = score(query: q, target: cand) {
                    scored.append((s + penalty, i, t))
                    break
                }
            }
        }
        return scored.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }
}

/// Flat ↑↓ navigation across the palette's stacked sections
/// (om-lt4-palettenav): the main rows (chats, or message hits) followed
/// by the visible Files rows then the visible People rows. The view keeps
/// one `highlight` over the concatenated rows; `resolve` maps it back.
/// Counts passed in are VISIBLE rows (files/people already capped and
/// zeroed when their section is hidden or unwired).
public enum PaletteNav {
    public enum Row: Equatable, Sendable {
        case main(Int)
        case file(Int)
        case person(Int)
    }

    /// Rows shown per Files/People section before the "+N more" note.
    public static let sectionRowCap = 5

    /// Visible rows for a section holding `count` hits.
    public static func visibleCount(_ count: Int) -> Int {
        min(max(count, 0), sectionRowCap)
    }

    /// Results height: one row per match + breathing room, clamped so
    /// the palette never collapses or overflows. Moved verbatim from
    /// JumpPaletteView.swift in the scratch-ui rebuild.
    public static func listHeight(for matchCount: Int) -> CGFloat {
        min(320, max(120, CGFloat(matchCount) * 56 + 8))
    }

    /// Total navigable rows across all three sections.
    public static func total(mainCount: Int, fileCount: Int, personCount: Int) -> Int {
        max(mainCount, 0) + max(fileCount, 0) + max(personCount, 0)
    }

    /// Clamped step; stays put at the ends (0 when nothing to move on).
    public static func move(current: Int, delta: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(max(current + delta, 0), total - 1)
    }

    /// Stepped index skipping disabled rows (om-a3-keyboard): walks
    /// from `current` in `delta`'s direction to the next enabled row.
    /// Stays on `current` when nothing past it is enabled (settling to
    /// the first enabled row when `current` itself is disabled, or 0
    /// when nothing is enabled). `delta == 0` just settles.
    public static func moveSkipping(
        current: Int, delta: Int, total: Int, isEnabled: (Int) -> Bool
    ) -> Int {
        guard total > 0 else { return 0 }
        let start = min(max(current, 0), total - 1)
        if delta == 0 {
            if isEnabled(start) { return start }
            return firstEnabled(total: total, isEnabled: isEnabled) ?? 0
        }
        let dir = delta > 0 ? 1 : -1
        var i = start + dir
        while i >= 0, i < total {
            if isEnabled(i) { return i }
            i += dir
        }
        if isEnabled(start) { return start }
        return firstEnabled(total: total, isEnabled: isEnabled) ?? 0
    }

    /// First enabled row, or nil when none is (om-a3-keyboard).
    public static func firstEnabled(
        total: Int, isEnabled: (Int) -> Bool
    ) -> Int? {
        guard total > 0 else { return nil }
        for i in 0 ..< total {
            if isEnabled(i) { return i }
        }
        return nil
    }

    /// Section + row for a flat index (nil when out of range).
    public static func resolve(
        _ index: Int, mainCount: Int, fileCount: Int, personCount: Int
    ) -> Row? {
        guard index >= 0 else { return nil }
        let main = max(mainCount, 0)
        let files = max(fileCount, 0)
        let people = max(personCount, 0)
        if index < main { return .main(index) }
        if index < main + files { return .file(index - main) }
        if index < main + files + people { return .person(index - main - files) }
        return nil
    }
}
