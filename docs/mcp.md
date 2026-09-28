# ostmac-mcp — Better Teams over MCP

`ostmac-mcp` is a stdio JSON-RPC (Model Context Protocol) server exposing
Better Teams chats to MCP clients such as Claude Desktop. It reuses
`OstMacCore` (same core, same session as the app) and has no GUI.

## Build

```sh
./scripts/build-rust.sh
cd swift && swift build -c release --product ostmac-mcp
# binary: swift/.build/release/ostmac-mcp
```

`ostmac-mcp --version` prints the version; `--help` prints usage.

## Claude Desktop config

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(create it if missing), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "better-teams": {
      "command": "/path/to/OstMac/swift/.build/release/ostmac-mcp"
    }
  }
}
```

Use the absolute path to your checkout's release binary. No arguments or
environment are needed.

## Tools

| Tool | Args | Effect |
|---|---|---|
| `list-chats` | `limit?` (1–100, default 20) | Recent chats (1:1 + group) |
| `list-messages` | `chat_id`, `limit?` (default 50), `page_token?` | History for a chat or channel; `page_token` pages back |
| `send-message` | `chat_id`, `text` | Post one text message |
| `react-message` | `chat_id`, `message_id`, `emoji` (👍❤️😂😮😢😠), `remove?` | Add/remove one emoji reaction |
| `list-teams` | — | Joined teams with channels |
| `list-channels` | `team_id?` | Channels (all, or one team); ids work in `list-messages` / `send-message` |

Tool results carry the payload as a JSON text block. Core failures
(unsigned, network) return `isError: true` with the message; malformed
requests get JSON-RPC errors (`-32700`/`-32600`/`-32601`/`-32602`).

## Sign-in boundary

Same rule as the app: device-code sign-in needs the owner in a browser.
Sign in once in the Better Teams app — the server reuses that on-disk
session (same user, same config dir). Until then every tool reports
unsigned and the assistant should say so instead of retrying.

## Protocol notes

- One JSON-RPC 2.0 message per line; responses on stdout, logs on stderr.
- Methods: `initialize` (echoes the client's `protocolVersion`),
  `tools/list`, `tools/call`, `ping`. `notifications/*` are accepted and
  never answered. Batch (array) requests are rejected.
- Manual probe:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | swift/.build/release/ostmac-mcp
```

## Tests

`swift/Tests/OstMacMCPTests` drives the server through `MockTransport`
(lines in/out) and `MockTeamsClient` (canned chats/messages/teams, scripted
failures) — no network, no sign-in. Run via `./scripts/test.sh`.
