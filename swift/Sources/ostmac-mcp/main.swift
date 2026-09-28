// main.swift — om-mcp lane: ostmac-mcp stdio entry.
import Foundation
import OstMacCore
import OstMacMCP

private func usage() -> String {
    """
    ostmac-mcp \(AppIdentity.version) — Better Teams over MCP (stdio JSON-RPC).

    usage: ostmac-mcp [--version] [--help]

    Runs a Model Context Protocol server on stdin/stdout:
      initialize, tools/list, tools/call, ping.
    Tools: list-chats, list-messages, send-message, list-teams, list-channels.
    Sign in once in the Better Teams app; this server reuses that session.
    See docs/mcp.md for the Claude Desktop config.
    """
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    print(usage())
    exit(0)
}
if args.contains("--version") || args.contains("-V") {
    print("ostmac-mcp \(AppIdentity.version)")
    exit(0)
}
guard RustCore.initialize() == 0 else {
    fputs("ostmac-mcp: core init failed\n", stderr)
    exit(1)
}
MCPServer().run(transport: StdioTransport(), client: LiveTeamsClient())
