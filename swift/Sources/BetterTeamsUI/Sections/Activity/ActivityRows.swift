// ActivityRows.swift — Activity row model (pure, unit-tested) and row
// view (UI-SPEC §6.1, R13).
//
// Row: reserved unread dot · kind symbol over the avatar · headline
// ("Alex Kim mentioned you in Design Sync", up to 2 lines) · time ·
// snippet (up to 2 lines; absent when it would only repeat the
// headline). Lines that have no text take no height.
import Foundation
import OstMacCore
import SwiftUI

/// Filter pop-up (§6.1).
enum ActivityFilter: String, CaseIterable, Sendable {
    case all, unread, mentions, replies, reactions, missedCalls, saved

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .mentions: "Mentions"
        case .replies: "Replies"
        case .reactions: "Reactions"
        case .missedCalls: "Missed Calls"
        case .saved: "Saved"
        }
    }

    /// Feed items this filter keeps (Saved rows come from the saved
    /// store instead).
    func keeps(_ item: ActivityItem) -> Bool {
        switch self {
        case .all: true
        case .unread: !item.reviewed
        case .mentions: item.kind == .mention || item.kind == .channelBlast
        case .replies: item.kind == .reply
        case .reactions: item.kind == .reaction
        case .missedCalls: item.kind == .missedCall
        case .saved: false
        }
    }

    /// Empty-state copy per filter (§6 pane states).
    var emptyTitle: String {
        switch self {
        case .all: "No Activity"
        case .unread: "No Unread Activity"
        case .mentions: "No Mentions"
        case .replies: "No Replies"
        case .reactions: "No Reactions"
        case .missedCalls: "No Missed Calls"
        case .saved: "No Saved Messages"
        }
    }
}

/// One Activity list row, from a feed item or a saved message.
struct ActivityRowModel: Identifiable, Equatable {
    static let savedPrefix = "saved:"

    let id: String
    let symbol: String
    let kindLabel: String
    let person: String
    let headline: String
    let snippet: String
    let date: Date
    let unread: Bool
    let chatID: String
    let messageID: String?
    let isMissedCall: Bool
    let isSaved: Bool
    /// Avatar is the group glyph (reactions in group chats name the
    /// chat, not a person).
    let groupAvatar: Bool

    init(_ item: ActivityItem, isGroup: Bool = false) {
        groupAvatar = item.kind == .reaction && isGroup
        id = item.id
        symbol = item.kind.systemImage
        kindLabel = item.kind.label
        person = item.kind == .reaction ? item.chatName : item.actor
        headline = Self.headline(item)
        snippet = Self.snippet(item)
        date = Date(timeIntervalSince1970: TimeInterval(item.at))
        unread = !item.reviewed
        chatID = item.chatID
        messageID = item.messageID
        isMissedCall = item.kind == .missedCall
        isSaved = false
    }

    init(saved s: SavedMessage, place: String) {
        groupAvatar = false
        id = Self.savedPrefix + s.id
        symbol = "bookmark"
        kindLabel = "Saved"
        person = s.sender
        headline = s.sender.isEmpty ? "Saved in \(place)" : "\(s.sender) in \(place)"
        snippet = s.preview
        date = Date(timeIntervalSince1970: s.savedAt)
        unread = false
        chatID = s.chatID
        messageID = s.messageID
        isMissedCall = false
        isSaved = true
    }

    /// Headline per kind; 1:1 chats (chat named after the actor) drop
    /// the redundant "in ‹chat›". Reactions name who reacted when the
    /// feed knows (live reaction events carry counts only today).
    static func headline(_ i: ActivityItem) -> String {
        let actor = i.actor.isEmpty ? "Someone" : i.actor
        let place = i.chatName.isEmpty || i.chatName == i.actor ? "" : " in \(i.chatName)"
        switch i.kind {
        case .mention: return "\(actor) mentioned you\(place)"
        case .channelBlast: return "\(actor) mentioned everyone\(place)"
        case .reply: return "\(actor) replied to you\(place)"
        case .reaction:
            let inChat = i.chatName.isEmpty ? "" : " in \(i.chatName)"
            return i.actor.isEmpty ? "Reactions to your message\(inChat)" : "\(i.actor) reacted to your message\(inChat)"
        case .missedCall: return "Missed call from \(actor)"
        }
    }

    /// Second line: the message text, never a restatement of the
    /// headline. Reactions keep only the tally ("❤️ · 3 reactions");
    /// missed calls have none (headline + time say it all).
    static func snippet(_ i: ActivityItem) -> String {
        switch i.kind {
        case .missedCall:
            return ""
        case .reaction:
            return reactionTally(i.snippet) ?? ""
        default:
            let s = i.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            return s == i.kind.label || s == headline(i) ? "" : s
        }
    }

    /// "New reaction ❤️×3 on your message…" (ActivityStore.reactionSnippet)
    /// → "❤️ · 3 reactions".
    static func reactionTally(_ snippet: String) -> String? {
        guard let r = snippet.range(of: #"New reaction (.+?)×(\d+)"#, options: .regularExpression) else { return nil }
        let core = snippet[r].dropFirst("New reaction ".count)
        guard let x = core.lastIndex(of: "×"), let n = Int(core[core.index(after: x)...]) else { return nil }
        let emoji = core[..<x]
        return "\(emoji) · \(n) \(n == 1 ? "reaction" : "reactions")"
    }

    /// Rows for a filter, newest first (feed order is already newest
    /// first; saved rows sort by save time).
    static func rows(_ items: [ActivityItem], saved: [SavedMessage], filter: ActivityFilter,
                     place: (String) -> String, isGroup: (String) -> Bool = { _ in false }) -> [ActivityRowModel] {
        if filter == .saved {
            return saved.sorted { $0.savedAt > $1.savedAt }.map { ActivityRowModel(saved: $0, place: place($0.chatID)) }
        }
        return items.filter(filter.keeps).map { ActivityRowModel($0, isGroup: isGroup($0.chatID)) }
    }
}

struct ActivityRow: View {
    let row: ActivityRowModel
    let now: Date
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .opacity(row.unread ? 1 : 0)
                .padding(.top, 11)
                .accessibilityHidden(true)
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Up to two lines, grown vertically so a List row
                    // never clips it to one ("…in Sho…"); the time keeps
                    // its width (fixedSize) and the headline takes the rest.
                    // Three lines: the place name ends the headline, so
                    // two lines at the default list width cut it off
                    // ("…in Demo — S…").
                    Text(row.headline)
                        .font(row.unread ? AppFont.headline(scale) : AppFont.body(scale))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.time(row.date, now: now))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                // No snippet = no line (no reserved blank height).
                if !row.snippet.isEmpty {
                    Text(row.snippet)
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    /// Kind symbol over the avatar's trailing-bottom corner: a white
    /// filled glyph on a system blue (missed call: red) disc, ringed in
    /// the background color so it separates from the monogram in light
    /// and dark (§10 contrast). Fixed system hues, not the accent: the
    /// accent drew a pale gray disc in Dark Mode with the glyph lost in
    /// it. Offset 7 pt so the ring stays clear of the monogram's
    /// trailing letter (at 5 pt it clipped "AL").
    private var avatar: some View {
        Avatar(name: row.person.isEmpty ? row.headline : row.person, isGroup: row.groupAvatar)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: row.symbol)
                    .symbolVariant(.fill)
                    .font(AppFont.avatarBadgeGlyph)
                    .foregroundStyle(Palette.badgeText)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(row.isMissedCall ? Palette.failed : Palette.activityBadge))
                    .background(Circle().fill(.background).padding(-1.5))
                    .offset(x: 7, y: 7)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, 7)
            .padding(.bottom, 7)
    }

    static func time(_ date: Date, now: Date) -> String {
        ChatListFormat.previewTime(ISO8601DateFormatter().string(from: date), now: now)
    }

    private var accessibility: String {
        var parts = [row.kindLabel, row.headline]
        if row.unread { parts.append("unread") }
        if !row.snippet.isEmpty { parts.append(row.snippet) }
        parts.append(Self.time(row.date, now: now))
        return parts.joined(separator: ", ")
    }
}
