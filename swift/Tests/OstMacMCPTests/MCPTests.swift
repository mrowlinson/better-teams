// MCPTests.swift — om-mcp lane: handshake, tools, errors, mock transport.
import XCTest

import OstMacCore
import OstMacMCP

final class MCPTests: XCTestCase {
    // MARK: - Helpers

    func json(_ line: String) -> [String: Any] {
        // swiftlint:disable:next force_try force_cast
        try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    }

    func result(_ line: String) -> [String: Any] {
        json(line)["result"] as! [String: Any]
    }

    func rpcError(_ line: String) -> [String: Any] {
        json(line)["error"] as! [String: Any]
    }

    func toolText(_ line: String) -> String {
        let content = result(line)["content"] as! [[String: Any]]
        return content[0]["text"] as! String
    }

    func isError(_ line: String) -> Bool {
        (result(line)["isError"] as? Bool) ?? false
    }

    func request(method: String, id: Any = 1, params: [String: Any]? = nil) -> String {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let p = params { o["params"] = p }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: o)
        return String(data: data, encoding: .utf8)!
    }

    func toolCall(_ name: String, args: [String: Any] = [:], id: Any = 1) -> String {
        request(method: "tools/call", id: id, params: ["name": name, "arguments": args])
    }

    // MARK: - Handshake

    func testInitializeEchoesClientVersion() {
        let line = request(
            method: "initialize", id: "init-1",
            params: ["protocolVersion": "2025-03-26",
                     "clientInfo": ["name": "probe", "version": "0"]])
        let resp = MCPServer.handle(line: line, client: MockTeamsClient())!
        let r = result(resp)
        XCTAssertEqual(r["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual(json(resp)["id"] as? String, "init-1")
        let info = r["serverInfo"] as! [String: Any]
        XCTAssertEqual(info["name"] as? String, "better-teams")
        XCTAssertEqual(info["version"] as? String, AppIdentity.version)
        XCTAssertNotNil((r["capabilities"] as! [String: Any])["tools"])
    }

    func testInitializeDefaultsVersion() {
        let resp = MCPServer.handle(
            line: request(method: "initialize", params: [:]),
            client: MockTeamsClient())!
        XCTAssertEqual(
            result(resp)["protocolVersion"] as? String,
            MCPServer.defaultProtocolVersion)
    }

    func testPing() {
        let resp = MCPServer.handle(
            line: request(method: "ping", id: 7), client: MockTeamsClient())!
        XCTAssertEqual((json(resp)["id"] as? NSNumber)?.intValue, 7)
        XCTAssertNotNil(json(resp)["result"])
    }

    func testNotificationsGetNoResponse() {
        XCTAssertNil(MCPServer.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            client: MockTeamsClient()))
        XCTAssertNil(MCPServer.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#,
            client: MockTeamsClient()))
        // Unknown bare notifications are still unanswered, never errors.
        XCTAssertNil(MCPServer.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/nope"}"#,
            client: MockTeamsClient()))
    }

    // MARK: - tools/list

    func testToolsList() {
        let resp = MCPServer.handle(
            line: request(method: "tools/list", id: 2), client: MockTeamsClient())!
        let tools = result(resp)["tools"] as! [[String: Any]]
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, [
            "list-channels", "list-chats", "list-messages", "list-teams", "react-message", "send-message",
        ])
        for t in tools {
            let schema = t["inputSchema"] as! [String: Any]
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(t["description"])
        }
        let msg = tools.first { $0["name"] as? String == "list-messages" }!
        let req = ((msg["inputSchema"] as! [String: Any])["required"] as! [String])
        XCTAssertEqual(req, ["chat_id"])
    }

    // MARK: - list-chats

    func testListChats() {
        let client = MockTeamsClient()
        let text = toolText(MCPServer.handle(
            line: toolCall("list-chats", args: ["limit": 2]),
            client: client)!)
        let payload = json(text)
        let chats = payload["chats"] as! [[String: Any]]
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats[0]["name"] as? String, "Demo — Design Sync")
        XCTAssertEqual(client.seenLimits, [2])
    }

    func testListChatsDefaultAndClamp() {
        let client = MockTeamsClient()
        _ = MCPServer.handle(line: toolCall("list-chats"), client: client)!
        _ = MCPServer.handle(
            line: toolCall("list-chats", args: ["limit": 500], id: 2),
            client: client)!
        XCTAssertEqual(client.seenLimits, [20, 100])
    }

    func testListChatsBadLimit() {
        let resp = MCPServer.handle(
            line: toolCall("list-chats", args: ["limit": "many"]),
            client: MockTeamsClient())!
        XCTAssertEqual((rpcError(resp)["code"] as? NSNumber)?.intValue, -32602)
    }

    // MARK: - list-messages

    func testListMessages() {
        let client = MockTeamsClient()
        let text = toolText(MCPServer.handle(
            line: toolCall("list-messages", args: ["chat_id": "demo-2", "limit": 1]),
            client: client)!)
        let payload = json(text)
        XCTAssertEqual(payload["chat_id"] as? String, "demo-2")
        let msgs = payload["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["sender"] as? String, "Ava Lindqvist")
    }

    func testListMessagesPageTokenPassthrough() {
        let client = MockTeamsClient()
        _ = MCPServer.handle(
            line: toolCall("list-messages", args: ["chat_id": "demo", "page_token": "tok-9"]),
            client: client)!
        XCTAssertEqual(client.seenPageTokens, ["tok-9"])
    }

    func testListMessagesUnknownChatIsEmpty() {
        let text = toolText(MCPServer.handle(
            line: toolCall("list-messages", args: ["chat_id": "nope"]),
            client: MockTeamsClient())!)
        XCTAssertTrue(((json(text)["messages"] as! [Any]).isEmpty))
    }

    func testListMessagesMissingChatID() {
        for args in ([
            [:], ["chat_id": ""], ["chat_id": "  "], ["chat_id": 42],
        ] as [[String: Any]]) {
            let resp = MCPServer.handle(
                line: toolCall("list-messages", args: args),
                client: MockTeamsClient())!
            XCTAssertEqual(
                (rpcError(resp)["code"] as? NSNumber)?.intValue, -32602,
                "args: \(args)")
        }
    }

    // MARK: - send-message

    func testSendMessage() {
        let client = MockTeamsClient()
        let resp = MCPServer.handle(
            line: toolCall("send-message", args: ["chat_id": "demo", "text": "hi"]),
            client: client)!
        XCTAssertFalse(isError(resp))
        XCTAssertEqual((json(toolText(resp))["ok"] as? Bool), true)
        XCTAssertEqual(client.sent.count, 1)
        XCTAssertEqual(client.sent[0].chatID, "demo")
        XCTAssertEqual(client.sent[0].text, "hi")
    }

    func testSendMessageRejectsBlank() {
        for args in ([
            ["chat_id": "demo"], ["text": "hi"],
            ["chat_id": "demo", "text": ""], ["chat_id": "demo", "text": "  "],
        ] as [[String: Any]]) {
            let resp = MCPServer.handle(
                line: toolCall("send-message", args: args),
                client: MockTeamsClient())!
            XCTAssertEqual(
                (rpcError(resp)["code"] as? NSNumber)?.intValue, -32602,
                "args: \(args)")
        }
        XCTAssertTrue(MockTeamsClient().sent.isEmpty)
    }

    // MARK: - react-message

    func testReactMessage() {
        let client = MockTeamsClient()
        let resp = MCPServer.handle(
            line: toolCall("react-message", args: [
                "chat_id": "demo", "message_id": "m1", "emoji": "👍",
            ]),
            client: client)!
        XCTAssertFalse(isError(resp))
        let payload = json(toolText(resp))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message_id"] as? String, "m1")
        XCTAssertEqual(payload["removed"] as? Bool, false)
        XCTAssertEqual(client.reacted.count, 1)
        XCTAssertEqual(client.reacted[0].messageID, "m1")
        XCTAssertEqual(client.reacted[0].emoji, "👍")
        XCTAssertFalse(client.reacted[0].remove)
    }

    func testReactMessageRemove() {
        let client = MockTeamsClient()
        let resp = MCPServer.handle(
            line: toolCall("react-message", args: [
                "chat_id": "demo", "message_id": "m1", "emoji": "❤️", "remove": true,
            ]),
            client: client)!
        XCTAssertFalse(isError(resp))
        XCTAssertEqual(json(toolText(resp))["removed"] as? Bool, true)
        XCTAssertTrue(client.reacted[0].remove)
    }

    func testReactMessageRejectsBadArgs() {
        for args in ([
            ["chat_id": "demo", "message_id": "m1"],
            ["chat_id": "demo", "message_id": "m1", "emoji": ""],
            ["chat_id": "demo", "message_id": "m1", "emoji": "  "],
            ["chat_id": "demo", "message_id": "m1", "emoji": "🎉"],
            ["chat_id": "demo", "emoji": "👍"],
        ] as [[String: Any]]) {
            let resp = MCPServer.handle(
                line: toolCall("react-message", args: args),
                client: MockTeamsClient())!
            XCTAssertEqual(
                (rpcError(resp)["code"] as? NSNumber)?.intValue, -32602,
                "args: \(args)")
        }
        XCTAssertTrue(MockTeamsClient().reacted.isEmpty)
    }

    func testReactMessageFailureIsErrorResult() {
        struct Boom: Error {}
        let client = MockTeamsClient()
        client.failure = Boom()
        let resp = MCPServer.handle(
            line: toolCall("react-message", args: [
                "chat_id": "demo", "message_id": "m1", "emoji": "👍",
            ]),
            client: client)!
        XCTAssertTrue(isError(resp))
    }

    func testListMessagesCarriesReactions() {
        let client = MockTeamsClient(messagesByChat: ["demo": MessagesResponse(
            ok: true, chat_id: "demo",
            messages: [ChatMessage(
                id: "m1", sender: "A", timestamp: "t", content: "hi",
                reactions: [ReactionCount(emoji: "👍", count: 2)])],
            page_token: nil)])
        let text = toolText(MCPServer.handle(
            line: toolCall("list-messages", args: ["chat_id": "demo"]),
            client: client)!)
        let msgs = json(text)["messages"] as! [[String: Any]]
        let r = msgs[0]["reactions"] as! [[String: Any]]
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0]["emoji"] as? String, "👍")
        XCTAssertEqual((r[0]["count"] as? NSNumber)?.intValue, 2)
    }

    // MARK: - list-teams / list-channels

    func testListTeams() {
        let text = toolText(MCPServer.handle(
            line: toolCall("list-teams"), client: MockTeamsClient())!)
        let teams = json(text)["teams"] as! [[String: Any]]
        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0]["name"] as? String, "Engineering")
        XCTAssertEqual((teams[0]["channels"] as! [Any]).count, 3) // +om-hu-fixture long channel
    }

    func testListChannelsAll() {
        let text = toolText(MCPServer.handle(
            line: toolCall("list-channels"), client: MockTeamsClient())!)
        let chans = json(text)["channels"] as! [[String: Any]]
        XCTAssertEqual(chans.count, 4) // +om-hu-fixture long channel
        XCTAssertEqual(chans[0]["team"] as? String, "Engineering")
        XCTAssertNotNil(chans[0]["team_id"])
    }

    func testListChannelsFiltered() {
        let text = toolText(MCPServer.handle(
            line: toolCall("list-channels", args: ["team_id": "demo-team-design"]),
            client: MockTeamsClient())!)
        let chans = json(text)["channels"] as! [[String: Any]]
        XCTAssertEqual(chans.count, 1)
        XCTAssertEqual(chans[0]["name"] as? String, "Crit")
    }

    func testListChannelsUnknownTeamIsErrorResult() {
        let resp = MCPServer.handle(
            line: toolCall("list-channels", args: ["team_id": "nope"]),
            client: MockTeamsClient())!
        XCTAssertTrue(isError(resp))
        XCTAssertTrue(toolText(resp).contains("nope"))
    }

    // MARK: - Protocol errors

    func testUnknownTool() {
        let resp = MCPServer.handle(
            line: toolCall("delete-everything"), client: MockTeamsClient())!
        let e = rpcError(resp)
        XCTAssertEqual((e["code"] as? NSNumber)?.intValue, -32602)
        XCTAssertTrue((e["message"] as? String)?.contains("delete-everything") ?? false)
    }

    func testToolsCallWithoutName() {
        let resp = MCPServer.handle(
            line: request(method: "tools/call", params: ["arguments": [:]]),
            client: MockTeamsClient())!
        XCTAssertEqual((rpcError(resp)["code"] as? NSNumber)?.intValue, -32602)
    }

    func testUnknownMethod() {
        let resp = MCPServer.handle(
            line: request(method: "resources/list"), client: MockTeamsClient())!
        XCTAssertEqual((rpcError(resp)["code"] as? NSNumber)?.intValue, -32601)
    }

    func testParseError() {
        let resp = MCPServer.handle(line: "this is not json", client: MockTeamsClient())!
        let e = rpcError(resp)
        XCTAssertEqual((e["code"] as? NSNumber)?.intValue, -32700)
        XCTAssertTrue(json(resp)["id"] is NSNull)
    }

    func testBatchRejected() {
        let resp = MCPServer.handle(line: "[]", client: MockTeamsClient())!
        XCTAssertEqual((rpcError(resp)["code"] as? NSNumber)?.intValue, -32700)
    }

    func testMissingMethod() {
        let resp = MCPServer.handle(
            line: #"{"jsonrpc":"2.0","id":3}"#, client: MockTeamsClient())!
        let j = json(resp)
        XCTAssertEqual((rpcError(resp)["code"] as? NSNumber)?.intValue, -32600)
        XCTAssertEqual((j["id"] as? NSNumber)?.intValue, 3)
    }

    // MARK: - Tool failures

    func testCoreFailureIsErrorResult() {
        let client = MockTeamsClient()
        client.failure = CoreCallError.failed("not signed in")
        let resp = MCPServer.handle(
            line: toolCall("list-chats", id: 9), client: client)!
        XCTAssertTrue(isError(resp))
        XCTAssertTrue(toolText(resp).contains("not signed in"))
        XCTAssertEqual((json(resp)["id"] as? NSNumber)?.intValue, 9)
    }

    // MARK: - Run loop

    func testRunLoopSkipsBlanksAndNotifications() {
        let t = MockTransport([
            request(method: "initialize", id: 1, params: ["protocolVersion": "x"]),
            "",
            "   ",
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            request(method: "ping", id: 2),
        ])
        MCPServer().run(transport: t, client: MockTeamsClient())
        XCTAssertEqual(t.output.count, 2)
        XCTAssertEqual((json(t.output[0])["id"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((json(t.output[1])["id"] as? NSNumber)?.intValue, 2)
    }

    func testRunLoopEndsOnEOF() {
        let t = MockTransport([])
        MCPServer().run(transport: t, client: MockTeamsClient())
        XCTAssertTrue(t.output.isEmpty)
    }

    func testRunLoopReactMessageRoundTrip() {
        let client = MockTeamsClient()
        let t = MockTransport([
            toolCall("react-message", args: [
                "chat_id": "demo", "message_id": "m1", "emoji": "😂",
            ], id: 11),
        ])
        MCPServer().run(transport: t, client: client)
        XCTAssertEqual(t.output.count, 1)
        XCTAssertFalse(isError(t.output[0]))
        XCTAssertEqual(client.reacted.count, 1)
        XCTAssertEqual(client.reacted[0].emoji, "😂")
    }
}
