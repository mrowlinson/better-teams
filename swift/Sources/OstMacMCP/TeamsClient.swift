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
        try RustCore.send(chatID: chatID, text: text)
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
}

/// Canned client for tests. Set `failure` to throw from every call.
/// Unknown chat ids return an empty (ok) page, like a quiet core.
public final class MockTeamsClient: TeamsClient, @unchecked Sendable {
    public var chatsResponse: ChatsResponse
    public var messagesByChat: [String: MessagesResponse]
    public var teamsResponse: TeamsResponse
    public var failure: Error?
    public private(set) var sent: [(chatID: String, text: String)] = []
    public private(set) var seenPageTokens: [String?] = []
    public private(set) var seenLimits: [Int32] = []

    public init(
        chats: ChatsResponse = DemoData.chatsResponse(),
        messagesByChat: [String: MessagesResponse]? = nil,
        teams: TeamsResponse = DemoData.teamsResponse()
    ) {
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
}
