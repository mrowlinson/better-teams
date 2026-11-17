// MCPServer.swift — om-mcp lane: stdio JSON-RPC (MCP) server for Better Teams.
//
// Minimal Model Context Protocol server: initialize handshake, tools/list,
// tools/call, ping. One JSON-RPC message per line on stdin, responses on
// stdout, diagnostics on stderr only. Batch (array) requests are rejected.
//
// Tool failures (unsigned, network, unknown team) come back as results
// with isError=true; malformed requests get JSON-RPC errors (-32700,
// -32600, -32601, -32602). Notifications (no id) get no response.
import Foundation
import OstMacCore

// MARK: - Transport

public protocol MCPTransport {
    func readLine() -> String?
    func write(_ line: String)
}

public final class StdioTransport: MCPTransport {
    public init() {}

    public func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    public func write(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

/// In-memory transport: canned input lines, captured output lines.
public final class MockTransport: MCPTransport {
    private var input: [String]
    public private(set) var output: [String] = []

    public init(_ input: [String]) {
        self.input = input
    }

    public func readLine() -> String? {
        guard !input.isEmpty else { return nil }
        return input.removeFirst()
    }

    public func write(_ line: String) {
        output.append(line)
    }
}

// MARK: - Server

public struct MCPServer {
    public static let serverName = "better-teams"
    public static let defaultProtocolVersion = "2025-06-18"
    public static let toolNames = [
        "list-chats", "list-messages", "send-message", "react-message", "list-teams", "list-channels",
        "search-messages", "list-activity", "list-agenda", "list-files", "get-presence", "catch-up",
    ]

    public init() {}

    /// Serve until EOF. Blank lines are skipped, never answered.
    public func run(transport: MCPTransport, client: TeamsClient) {
        while let line = transport.readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let response = Self.handle(line: trimmed, client: client) {
                transport.write(response)
            }
        }
    }

    /// Handle one raw line. Returns the response line, or nil for
    /// notifications (which JSON-RPC forbids answering).
    public static func handle(line: String, client: TeamsClient) -> String? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let req = raw as? [String: Any]
        else {
            return encode(error(code: -32700, message: "Parse error", id: nil))
        }
        guard let method = req["method"] as? String else {
            return encode(error(code: -32600, message: "Invalid Request", id: req["id"]))
        }
        // Notification: no id key at all (null id is still a request id).
        let isNotification = req["id"] == nil
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]

        if method.hasPrefix("notifications/") {
            // Only initialized/cancelled exist; both are fire-and-forget.
            // A notification gets no answer even when we know the name.
            guard !isNotification else { return nil }
            return encode(["jsonrpc": "2.0", "id": id as Any, "result": [String: Any]()])
        }
        guard !isNotification else { return nil }

        switch method {
        case "initialize":
            return encode([
                "jsonrpc": "2.0", "id": id as Any,
                "result": [
                    "protocolVersion": params["protocolVersion"] as? String
                        ?? defaultProtocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": serverName, "version": AppIdentity.version],
                    "instructions": "Better Teams (Teams) chats over MCP. "
                        + "Sign-in lives in the Better Teams app; when tools report "
                        + "unsigned, tell the user to sign in there first.",
                ],
            ])
        case "ping":
            return encode(["jsonrpc": "2.0", "id": id as Any, "result": [String: Any]()])
        case "tools/list":
            return encode([
                "jsonrpc": "2.0", "id": id as Any, "result": ["tools": toolDescriptors],
            ])
        case "tools/call":
            return encode(call(params: params, id: id, client: client))
        default:
            return encode(error(code: -32601, message: "Method not found: \(method)", id: id))
        }
    }

    // MARK: - tools/call

    private static func call(params: [String: Any], id: Any?, client: TeamsClient) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return error(code: -32602, message: "tools/call needs a tool name", id: id)
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text: String
            switch name {
            case "list-chats":
                text = try listChats(args: args, client: client)
            case "list-messages":
                text = try listMessages(args: args, client: client)
            case "send-message":
                text = try sendMessage(args: args, client: client)
            case "react-message":
                text = try reactMessage(args: args, client: client)
            case "list-teams":
                text = try listTeams(client: client)
            case "list-channels":
                text = try listChannels(args: args, client: client)
            case "search-messages":
                text = try searchMessages(args: args, client: client)
            case "list-activity":
                text = try listActivity(args: args, client: client)
            case "list-agenda":
                text = try listAgenda(args: args, client: client)
            case "list-files":
                text = try listFiles(args: args, client: client)
            case "get-presence":
                text = try getPresence(args: args, client: client)
            case "catch-up":
                text = try catchUp(args: args, client: client)
            default:
                return error(code: -32602, message: "unknown tool: \(name)", id: id)
            }
            return [
                "jsonrpc": "2.0", "id": id as Any,
                "result": ["content": [["type": "text", "text": text]]],
            ]
        } catch let e as ToolError {
            switch e {
            case let .invalidParams(message):
                return error(code: -32602, message: message, id: id)
            case let .failed(message):
                return [
                    "jsonrpc": "2.0", "id": id as Any,
                    "result": [
                        "content": [["type": "text", "text": message]],
                        "isError": true,
                    ],
                ]
            }
        } catch {
            return [
                "jsonrpc": "2.0", "id": id as Any,
                "result": [
                    "content": [["type": "text", "text": coreMessage(error)]],
                    "isError": true,
                ],
            ]
        }
    }

    private static func listChats(args: [String: Any], client: TeamsClient) throws -> String {
        let limit = try intArg(args, "limit", default: 20)
        let resp = try client.chats(limit: limit)
        return encode(["chats": resp.chats.map { c -> [String: Any] in
            var o: [String: Any] = ["id": c.chatId, "name": c.name, "is_group": c.is_group]
            if let t = c.last_message_time { o["last_message_time"] = t }
            if let s = c.last_message_sender { o["last_message_sender"] = s }
            if let p = c.last_message_preview { o["last_message_preview"] = p }
            return o
        }])
    }

    private static func listMessages(args: [String: Any], client: TeamsClient) throws -> String {
        let chatID = try stringArg(args, "chat_id")
        let limit = try intArg(args, "limit", default: 50)
        let token = args["page_token"] as? String
        let resp = try client.messages(chatID: chatID, limit: limit, pageToken: token)
        var o: [String: Any] = [
            "chat_id": resp.chat_id ?? chatID,
            "messages": resp.messages.map { m in
                ["id": m.id, "sender": m.sender, "timestamp": m.timestamp, "content": m.content,
                 "reactions": m.reactions.map { ["emoji": $0.emoji, "count": $0.count] }] as [String: Any]
            },
        ]
        if let t = resp.page_token { o["page_token"] = t }
        return encode(o)
    }

    private static func sendMessage(args: [String: Any], client: TeamsClient) throws -> String {
        let chatID = try stringArg(args, "chat_id")
        let text = try stringArg(args, "text")
        let resp = try client.send(chatID: chatID, text: text)
        return encode(["ok": resp.ok, "chat_id": resp.chat_id ?? chatID] as [String: Any])
    }

    private static func reactMessage(args: [String: Any], client: TeamsClient) throws -> String {
        let chatID = try stringArg(args, "chat_id")
        let messageID = try stringArg(args, "message_id")
        let emoji = try stringArg(args, "emoji")
        guard ConversationStore.reactionEmojis.contains(emoji) else {
            throw ToolError.invalidParams("emoji must be one of \(ConversationStore.reactionEmojis.joined())")
        }
        let remove = (args["remove"] as? NSNumber)?.boolValue ?? false
        let resp = try client.react(chatID: chatID, messageID: messageID, emoji: emoji, remove: remove)
        return encode([
            "ok": resp.ok, "chat_id": resp.chat_id ?? chatID,
            "message_id": messageID, "emoji": emoji, "removed": remove,
        ] as [String: Any])
    }

    private static func listTeams(client: TeamsClient) throws -> String {
        let resp = try client.teams()
        return encode(["teams": resp.teams.map { t -> [String: Any] in
            ["id": t.teamId, "name": t.name,
             "channels": t.channels.map { ["id": $0.channelId, "name": $0.name] }]
        }])
    }

    private static func listChannels(args: [String: Any], client: TeamsClient) throws -> String {
        let resp = try client.teams()
        let wanted = args["team_id"] as? String
        if let w = wanted, !resp.teams.contains(where: { $0.teamId == w }) {
            throw ToolError.failed("unknown team_id: \(w)")
        }
        var out: [[String: Any]] = []
        for t in resp.teams where wanted == nil || t.teamId == wanted {
            for c in t.channels {
                out.append([
                    "id": c.channelId, "name": c.name,
                    "team_id": t.teamId, "team": t.name,
                ])
            }
        }
        return encode(["channels": out])
    }

    private static func searchMessages(args: [String: Any], client: TeamsClient) throws -> String {
        let query = try stringArg(args, "query")
        let limit = try intArg(args, "limit", default: 25)
        let resp = try client.searchMessages(query: query, limit: limit)
        var o: [String: Any] = [
            "query": resp.query ?? query,
            "hits": resp.hits.map { h -> [String: Any] in
                var o: [String: Any] = [
                    "message_id": h.messageID, "chat_id": h.chatID,
                    "sender": h.sender, "timestamp": h.timestamp, "preview": h.preview,
                ]
                if let t = h.teamID { o["team_id"] = t }
                if let c = h.channelID { o["channel_id"] = c }
                if let s = h.subject { o["subject"] = s }
                return o
            },
        ]
        if let t = resp.total { o["total"] = t }
        o["more"] = resp.more
        if let n = resp.next_from { o["next_from"] = n }
        return encode(o)
    }

    private static func listActivity(args: [String: Any], client: TeamsClient) throws -> String {
        let limit = try intArg(args, "limit", default: 20)
        let mentionsOnly = (args["mentions_only"] as? NSNumber)?.boolValue ?? false
        let rows = try client.activity(limit: limit, mentionsOnly: mentionsOnly)
        return encode(["activity": rows.map { a -> [String: Any] in
            var o: [String: Any] = [
                "id": a.id, "kind": a.kind.rawValue, "chat_id": a.chatID,
                "actor": a.actor, "chat_name": a.chatName, "snippet": a.snippet,
                "at": a.at, "reviewed": a.reviewed,
            ]
            if let m = a.messageID { o["message_id"] = m }
            return o
        }])
    }

    private static func listAgenda(args: [String: Any], client: TeamsClient) throws -> String {
        let limit = try intArg(args, "limit", default: 20)
        let resp = try client.agenda(limit: limit)
        return encode(["meetings": resp.meetings.map { m -> [String: Any] in
            var o: [String: Any] = [
                "id": m.meetingId, "subject": m.subject, "is_online": m.isOnline,
            ]
            if let s = m.start { o["start"] = s }
            if let e = m.end { o["end"] = e }
            if let j = m.joinURL { o["join_url"] = j }
            if let g = m.organizer { o["organizer"] = g }
            return o
        }])
    }

    private static func listFiles(args: [String: Any], client: TeamsClient) throws -> String {
        let limit = try intArg(args, "limit", default: 25)
        let query = blankToNil(args["query"] as? String)
        let chatID = blankToNil(args["chat_id"] as? String)
        let rows = try client.files(query: query, chatID: chatID, limit: limit)
        return encode(["files": rows.map { f -> [String: Any] in
            var o: [String: Any] = ["id": f.id, "name": f.name, "size": f.size]
            if let m = f.mime { o["mime"] = m }
            if let w = f.web_url { o["web_url"] = w }
            if let d = f.download_url { o["download_url"] = d }
            if let v = f.drive_id { o["drive_id"] = v }
            if let s = f.sender { o["sender"] = s }
            if let c = f.created { o["created"] = c }
            if let t = f.modified { o["modified"] = t }
            if let n = f.source_name { o["source_name"] = n }
            if let i = f.source_id { o["source_id"] = i }
            return o
        }])
    }

    private static func getPresence(args: [String: Any], client: TeamsClient) throws -> String {
        guard let raw = args["user_id"] else {
            let p = try client.presence()
            return encode(presenceDict(
                availability: p.availability, activity: p.activity,
                statusMessage: p.statusMessage, outOfOffice: p.outOfOffice))
        }
        guard let id = raw as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidParams("user_id must be a non-empty string")
        }
        let p = try client.userPresence(id: id)
        var o = presenceDict(
            availability: p.availability, activity: p.activity,
            statusMessage: p.statusMessage, outOfOffice: p.outOfOffice)
        o["id"] = p.id
        return encode(o)
    }

    private static func presenceDict(
        availability: String, activity: String, statusMessage: String?, outOfOffice: Bool?
    ) -> [String: Any] {
        var o: [String: Any] = ["availability": availability, "activity": activity]
        if let s = statusMessage { o["status_message"] = s }
        if let b = outOfOffice { o["out_of_office"] = b }
        return o
    }

    private static func catchUp(args: [String: Any], client: TeamsClient) throws -> String {
        let limit = try intArg(args, "limit", default: 10)
        let summary = try client.catchUp(limit: limit)
        return encode([
            "total_recent": summary.totalRecent,
            "chats": summary.chats.map { e -> [String: Any] in
                var o: [String: Any] = [
                    "chat_id": e.chatID, "name": e.name, "recent_count": e.recentCount,
                ]
                if let s = e.latestSender { o["latest_sender"] = s }
                if let p = e.latestPreview { o["latest_preview"] = p }
                if let t = e.latestTime { o["latest_time"] = t }
                return o
            },
        ])
    }

    /// Blank or missing optional string filter: absent (recents/unfiltered).
    private static func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // MARK: - Args

    private enum ToolError: Error {
        case invalidParams(String)
        case failed(String)
    }

    private static func stringArg(_ args: [String: Any], _ key: String) throws -> String {
        guard let s = args[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidParams("\(key) must be a non-empty string")
        }
        return s
    }

    private static func intArg(_ args: [String: Any], _ key: String, default def: Int32) throws -> Int32 {
        guard let v = args[key] else { return def }
        guard let n = v as? NSNumber else {
            throw ToolError.invalidParams("\(key) must be a number")
        }
        return min(max(n.int32Value, 1), 100)
    }

    private static func coreMessage(_ error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    // MARK: - Tool descriptors

    private static let toolDescriptors: [[String: Any]] = [
        [
            "name": "list-chats",
            "description": "List recent Teams chats (1:1 and group). Needs sign-in via the Better Teams app.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20]],
            ],
        ],
        [
            "name": "list-messages",
            "description": "Read message history for one chat or channel. Pass page_token from a previous reply to page back.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chat_id": ["type": "string", "description": "Chat or channel id"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 50],
                    "page_token": ["type": "string", "description": "Older-page cursor"],
                ],
                "required": ["chat_id"],
            ],
        ],
        [
            "name": "send-message",
            "description": "Post one text message to a chat or channel.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chat_id": ["type": "string"],
                    "text": ["type": "string"],
                ],
                "required": ["chat_id", "text"],
            ],
        ],
        [
            "name": "react-message",
            "description": "Add (or with remove:true, remove) one emoji reaction on a message. Emoji is one of 👍 ❤️ 😂 😮 😢 😠.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chat_id": ["type": "string"],
                    "message_id": ["type": "string", "description": "Server message id from list-messages"],
                    "emoji": ["type": "string", "description": "One of 👍 ❤️ 😂 😮 😢 😠"],
                    "remove": ["type": "boolean", "description": "Remove instead of add", "default": false],
                ],
                "required": ["chat_id", "message_id", "emoji"],
            ],
        ],
        [
            "name": "list-teams",
            "description": "List joined teams with their channels.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "list-channels",
            "description": "List channels, optionally for one team_id. Channel ids open via list-messages and send-message.",
            "inputSchema": [
                "type": "object",
                "properties": ["team_id": ["type": "string"]],
            ],
        ],
        [
            "name": "search-messages",
            "description": "Search message text across chats and channels. Returns sender, timestamp, and preview per hit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Substring over sender and preview"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 25],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "list-activity",
            "description": "Recent activity feed (mentions, replies, reactions). Pass mentions_only:true for @-mentions of you.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20],
                    "mentions_only": ["type": "boolean", "description": "Only @-mention rows", "default": false],
                ],
            ],
        ],
        [
            "name": "list-agenda",
            "description": "Upcoming meetings (calendar agenda) with start, organizer, and join link when present.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20]],
            ],
        ],
        [
            "name": "list-files",
            "description": "Files: pass query to search OneDrive, chat_id for one conversation's shared files, neither for recent files.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Substring over file names"],
                    "chat_id": ["type": "string", "description": "Chat or channel id"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 25],
                ],
            ],
        ],
        [
            "name": "get-presence",
            "description": "Presence: yours by default, or pass user_id for one other user.",
            "inputSchema": [
                "type": "object",
                "properties": ["user_id": ["type": "string"]],
            ],
        ],
        [
            "name": "catch-up",
            "description": "Catch Up summary: per-chat recent-message counts with the newest sender, preview, and time.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 10]],
            ],
        ],
    ]

    // MARK: - JSON

    private static func error(code: Int, message: String, id: Any?) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id as Any,
         "error": ["code": code, "message": message] as [String: Any]]
    }

    private static func encode(_ obj: Any) -> String {
        // All inputs are JSON-built dicts; force-try keeps call sites clean.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{\"jsonrpc\":\"2.0\",\"id\":null}"
    }
}
