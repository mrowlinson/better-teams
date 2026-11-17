// TeamsClient.swift — om-mcp lane: core seam behind the MCP tools.
//
// LiveTeamsClient wraps RustCore; MockTeamsClient serves canned data for
// tests and offline probes. The MCP server only sees this protocol.
import Foundation
import OstMacCore

public protocol TeamsClient: Sendable {
    func chats(limit: Int32) throws -> ChatsResponse
    func messages(chatID: String, limit: Int32, pageToken: String?) throws -> MessagesResponse
    func send(chatID: String, text: String) throws -> SendResponse
    func teams() throws -> TeamsResponse
    /// Add (`remove: false`) or remove one emoji reaction on a message.
    func react(chatID: String, messageID: String, emoji: String, remove: Bool) throws -> SendResponse
    // MARK: - Read-only extras (mcp-tools lane: 6 new READ tools)
    /// Message search, one window (Graph /search/query).
    func searchMessages(query: String, limit: Int32) throws -> SearchResponse
    /// Activity feed rows, newest first; mentions-only keeps `.mention` rows.
    func activity(limit: Int32, mentionsOnly: Bool) throws -> [ActivityItem]
    /// Upcoming meetings (calendar agenda).
    func agenda(limit: Int32) throws -> MeetingsResponse
    /// Files: `query` searches OneDrive, `chatID` lists one conversation's
    /// shared files, neither returns drive recents.
    func files(query: String?, chatID: String?, limit: Int32) throws -> [SharedFile]
    /// Own presence.
    func presence() throws -> PresenceResponse
    /// One other user's presence; unknown ids throw.
    func userPresence(id: String) throws -> UserPresenceResponse
    /// Per-chat recent-message digest (read-only Catch Up summary).
    func catchUp(limit: Int32) throws -> CatchUpSummary
}

/// One chat's row in a Catch Up summary: how many recent messages arrived
/// and what the newest one said. Pure read composition over chats+messages.
public struct CatchUpEntry: Sendable, Equatable {
    public let chatID: String
    public let name: String
    public let recentCount: Int
    public let latestSender: String?
    public let latestPreview: String?
    public let latestTime: String?

    public init(
        chatID: String, name: String, recentCount: Int,
        latestSender: String? = nil, latestPreview: String? = nil,
        latestTime: String? = nil
    ) {
        self.chatID = chatID
        self.name = name
        self.recentCount = recentCount
        self.latestSender = latestSender
        self.latestPreview = latestPreview
        self.latestTime = latestTime
    }
}

/// Read-only Catch Up summary: one entry per recent chat, newest first.
public struct CatchUpSummary: Sendable, Equatable {
    public let chats: [CatchUpEntry]
    public let totalRecent: Int

    public init(chats: [CatchUpEntry]) {
        self.chats = chats
        self.totalRecent = chats.reduce(0) { $0 + $1.recentCount }
    }
}

public struct LiveTeamsClient: TeamsClient {
    public init() {}

    public func chats(limit: Int32) throws -> ChatsResponse {
        try RustCore.chats(limit: limit)
    }

    public func messages(chatID: String, limit: Int32, pageToken: String?) throws -> MessagesResponse {
        if let tok = pageToken {
            return try RustCore.messagesPage(chatID: chatID, pageToken: tok, limit: limit)
        }
        return try RustCore.messages(chatID: chatID, limit: limit)
    }

    public func send(chatID: String, text: String) throws -> SendResponse {
        // §106: idempotent + verified (a lost answer is never a second copy).
        let id = try SendPipeline.postVerified(chatID: chatID, text: text)
        return SendResponse(ok: true, chat_id: chatID, id: id)
    }

    public func react(chatID: String, messageID: String, emoji: String, remove: Bool) throws -> SendResponse {
        if remove {
            return try RustCore.removeReaction(chatID: chatID, messageID: messageID, emoji: emoji)
        }
        return try RustCore.react(chatID: chatID, messageID: messageID, emoji: emoji)
    }

    public func teams() throws -> TeamsResponse {
        try RustCore.teams()
    }

    public func searchMessages(query: String, limit: Int32) throws -> SearchResponse {
        try RustCore.search(query: query, size: limit)
    }

    public func activity(limit: Int32, mentionsOnly: Bool) throws -> [ActivityItem] {
        let feed = try CoreReads.activityFeed()
        let rows = mentionsOnly ? feed.filter { $0.kind == .mention } : feed
        return Array(rows.prefix(Int(limit)))
    }

    public func agenda(limit: Int32) throws -> MeetingsResponse {
        try RustCore.meetings(limit: limit)
    }

    public func files(query: String?, chatID: String?, limit: Int32) throws -> [SharedFile] {
        if let q = query, !q.isEmpty {
            return try RustCore.fileSearch(query: q, limit: limit).files
        }
        if let c = chatID, !c.isEmpty {
            return try RustCore.sharedFiles(chatID: c, limit: limit).files
        }
        return try RustCore.driveRecents(limit: limit).files
    }

    public func presence() throws -> PresenceResponse {
        try RustCore.presence()
    }

    public func userPresence(id: String) throws -> UserPresenceResponse {
        try RustCore.userPresence(id: id)
    }

    public func catchUp(limit: Int32) throws -> CatchUpSummary {
        let chats = try RustCore.chats(limit: limit)
        var out: [CatchUpEntry] = []
        // Bounded fan-out: newest 10 chats, 5 messages each (read-only).
        for c in chats.chats.prefix(10) {
            let page = try RustCore.messages(chatID: c.chatId, limit: 5)
            let last = page.messages.last
            out.append(CatchUpEntry(
                chatID: c.chatId, name: c.name, recentCount: page.messages.count,
                latestSender: last?.sender, latestPreview: last?.content,
                latestTime: last?.timestamp))
        }
        return CatchUpSummary(chats: out)
    }
}

/// Canned client for tests. Set `failure` to throw from every call.
/// Unknown chat ids return an empty (ok) page, like a quiet core.
public final class MockTeamsClient: TeamsClient, @unchecked Sendable {
    public var chatsResponse: ChatsResponse
    public var messagesByChat: [String: MessagesResponse]
    public var teamsResponse: TeamsResponse
    public var activityItems: [ActivityItem]
    public var failure: Error?
    public private(set) var sent: [(chatID: String, text: String)] = []
    public private(set) var seenPageTokens: [String?] = []
    public private(set) var seenLimits: [Int32] = []
    public private(set) var seenSearchQueries: [String] = []
    public private(set) var seenMentionsOnly: [Bool] = []
    public private(set) var seenFileQueries: [(query: String?, chatID: String?)] = []
    public private(set) var seenPresenceIDs: [String?] = []

    public init(
        chats: ChatsResponse = DemoData.chatsResponse(),
        messagesByChat: [String: MessagesResponse]? = nil,
        teams: TeamsResponse = DemoData.teamsResponse(),
        activity: [ActivityItem]? = nil
    ) {
        self.activityItems = activity ?? MockTeamsClient.demoActivity()
        self.chatsResponse = chats
        if let m = messagesByChat {
            self.messagesByChat = m
        } else {
            var d: [String: MessagesResponse] = [:]
            for c in chats.chats {
                d[c.chatId] = MessagesResponse(
                    ok: true, chat_id: c.chatId,
                    messages: DemoData.messages(for: c.chatId), page_token: nil)
            }
            self.messagesByChat = d
        }
        self.teamsResponse = teams
    }

    public func chats(limit: Int32) throws -> ChatsResponse {
        if let f = failure { throw f }
        seenLimits.append(limit)
        return ChatsResponse(ok: true, chats: Array(chatsResponse.chats.prefix(Int(limit))))
    }

    public func messages(chatID: String, limit: Int32, pageToken: String?) throws -> MessagesResponse {
        if let f = failure { throw f }
        seenLimits.append(limit)
        seenPageTokens.append(pageToken)
        if let m = messagesByChat[chatID] {
            return MessagesResponse(
                ok: true, chat_id: m.chat_id,
                messages: Array(m.messages.prefix(Int(limit))), page_token: m.page_token)
        }
        return MessagesResponse(ok: true, chat_id: chatID, messages: [], page_token: nil)
    }

    public func send(chatID: String, text: String) throws -> SendResponse {
        if let f = failure { throw f }
        sent.append((chatID: chatID, text: text))
        return SendResponse(ok: true, chat_id: chatID)
    }

    public private(set) var reacted: [(chatID: String, messageID: String, emoji: String, remove: Bool)] = []

    public func react(chatID: String, messageID: String, emoji: String, remove: Bool) throws -> SendResponse {
        if let f = failure { throw f }
        reacted.append((chatID: chatID, messageID: messageID, emoji: emoji, remove: remove))
        return SendResponse(ok: true, chat_id: chatID)
    }

    public func teams() throws -> TeamsResponse {
        if let f = failure { throw f }
        return teamsResponse
    }

    /// Canned feed: one mention, one reply, one reaction (mirrors the demo
    /// threads; `at` stamps are fixed so tests never depend on wall time).
    static func demoActivity() -> [ActivityItem] {
        [
            ActivityItem(
                kind: .mention, chatID: DemoData.richID, messageID: "rich-2",
                actor: "Tom Becker", chatName: "Design Sync",
                snippet: "Jordan Fox, thoughts on the empty states?",
                at: 1_758_732_000, reviewed: false),
            ActivityItem(
                kind: .reply, chatID: DemoData.avaID, messageID: "ava-3",
                actor: "Ava Lindqvist", chatName: "Ava Lindqvist",
                snippet: "Standup moved to 10 — see you there.",
                at: 1_758_731_000, reviewed: false),
            ActivityItem(
                kind: .reaction, chatID: DemoData.demoID, messageID: "m1",
                actor: "", chatName: "Design Sync",
                snippet: "Tom Becker reacted 👍",
                at: 1_758_730_000, reviewed: true),
        ]
    }

    public func searchMessages(query: String, limit: Int32) throws -> SearchResponse {
        if let f = failure { throw f }
        seenSearchQueries.append(query)
        seenLimits.append(limit)
        let full = DemoData.messageSearchResponse(for: query)
        return SearchResponse(
            ok: true, query: query, from: 0, size: full.hits.count,
            total: full.hits.count, more: false, next_from: nil,
            hits: Array(full.hits.prefix(Int(limit))))
    }

    public func activity(limit: Int32, mentionsOnly: Bool) throws -> [ActivityItem] {
        if let f = failure { throw f }
        seenLimits.append(limit)
        seenMentionsOnly.append(mentionsOnly)
        let rows = mentionsOnly ? activityItems.filter { $0.kind == .mention } : activityItems
        return Array(rows.prefix(Int(limit)))
    }

    public func agenda(limit: Int32) throws -> MeetingsResponse {
        if let f = failure { throw f }
        seenLimits.append(limit)
        return MeetingsResponse(
            ok: true, meetings: Array(DemoData.meetings.prefix(Int(limit))))
    }

    public func files(query: String?, chatID: String?, limit: Int32) throws -> [SharedFile] {
        if let f = failure { throw f }
        seenLimits.append(limit)
        seenFileQueries.append((query: query, chatID: chatID))
        let rows: [SharedFile]
        if let q = query, !q.isEmpty {
            rows = DemoData.fileSearchResponse(for: q).files
        } else if let c = chatID, !c.isEmpty {
            rows = DemoData.sharedFiles(for: c)
        } else {
            rows = DemoData.fileSearchResponse(for: "").files
        }
        return Array(rows.prefix(Int(limit)))
    }

    public func presence() throws -> PresenceResponse {
        if let f = failure { throw f }
        seenPresenceIDs.append(nil)
        return DemoData.ownPresence()
    }

    public func userPresence(id: String) throws -> UserPresenceResponse {
        if let f = failure { throw f }
        seenPresenceIDs.append(id)
        if let p = DemoData.peerPresence()[id] { return p }
        throw CoreCallError.failed("unknown user_id: \(id)")
    }

    public func catchUp(limit: Int32) throws -> CatchUpSummary {
        if let f = failure { throw f }
        seenLimits.append(limit)
        let chats = Array(chatsResponse.chats.prefix(Int(limit)))
        return CatchUpSummary(chats: chats.map { c in
            let msgs = messagesByChat[c.chatId]?.messages ?? []
            let last = msgs.last
            return CatchUpEntry(
                chatID: c.chatId, name: c.name, recentCount: msgs.count,
                latestSender: last?.sender, latestPreview: last?.content,
                latestTime: last?.timestamp)
        })
    }
}
