// GraphAllowlistLintTests.swift — GRAPHSWEEP guard. Every function that
// sends a Microsoft Graph request (Rust ost api + ostmac-core, Swift core)
// must be listed in docs/graph-allowlist.txt with a status and a proof
// note; stale entries fail too. Graph base URLs may only be built in the
// known request helpers. Source scan only (no network).
import Foundation
import XCTest

final class GraphAllowlistLintTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // OstMacCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // swift
        .deletingLastPathComponent() // repo

    /// Request helpers that own the Graph base URL (not call sites).
    private static let helperFiles: Set<String> = [
        "rust/ost/src/api/client.rs",
        "swift/Sources/OstMacCore/TeamsAuthClient.swift",
    ]

    /// Files allowed to spell the Graph host outside comments, and why.
    private static let hostFiles: [String: String] = [
        "rust/ost/src/api/client.rs": "GRAPH_BASE for the graph_* helpers",
        "rust/ost/src/api/planner.rs": "GRAPH_BASE for the If-Match PATCH (patch_task, allowlisted)",
        "rust/ost/src/auth/oauth.rs": "token scope strings",
        "rust/ost/src/calling/call_test.rs": "call test harness GET /me (User.ReadBasic.All, probeA 200)",
        "swift/Sources/OstMacCore/ReadCore.swift": "graphBase for CoreReads.graphGET",
        "swift/Sources/OstMacCore/CalendarGraph.swift": "calendar base + host check",
        "swift/Sources/OstMacCore/TeamsAuthClient.swift": "generic Graph helpers",
        "swift/Sources/OstMacCore/TokenRefresh.swift": "token scope string",
    ]

    private static let statuses: Set<String> = ["works", "blocked", "unproven", "tui-only"]

    private static func sources() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for (dir, ext) in [("rust/ost/src", "rs"), ("rust/ostmac-core/src", "rs"), ("swift/Sources", "swift")] {
            let base = root.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == ext {
                out.append(String(u.path.dropFirst(root.path.count + 1)))
            }
        }
        return out.sorted()
    }

    /// Non-test, non-comment lines with their 1-based numbers. Rust
    /// top-level `#[cfg(test)]` items are skipped to their closing `}`.
    private static func codeLines(_ rel: String) throws -> [(Int, String)] {
        let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        var out: [(Int, String)] = []
        var skipping = false
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if rel.hasSuffix(".rs") {
                if line.hasPrefix("#[cfg(test)]") { skipping = true; continue }
                if skipping { if line == "}" { skipping = false }; continue }
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            out.append((i + 1, line))
        }
        return out
    }

    private static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }

    /// `path::function` for every Graph call site, with one example line.
    static func callSites() throws -> [String: String] {
        let rustCall = #"\.graph_(get|get_consistent|get_url|get_download|post|delete|put_bytes|patch|patch_raw)\s*\("#
        var sites: [String: String] = [:]
        for rel in sources() where !helperFiles.contains(rel) {
            let isRust = rel.hasSuffix(".rs")
            var fn = "<top>"
            for (n, line) in try codeLines(rel) {
                if isRust {
                    if let f = firstMatch(#"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)"#, line) { fn = f }
                } else if let f = firstMatch(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, line)
                    ?? firstMatch(#"\bstatic let\s+([A-Za-z_][A-Za-z0-9_]*)"#, line) {
                    fn = f
                }
                let hit: Bool
                if isRust {
                    hit = firstMatch("(" + rustCall + ")", line) != nil
                        || (line.contains("GRAPH_BASE") && !line.contains("const GRAPH_BASE"))
                } else {
                    hit = (line.contains("graphGET(") && !line.contains("func graphGET"))
                        || (line.contains("graphBase +") && fn != "graphGET")
                        || firstMatch(#"(request\("(GET|POST|PATCH|DELETE)")"#, line) != nil
                }
                if hit { sites["\(rel)::\(fn)"] = sites["\(rel)::\(fn)"] ?? "\(rel):\(n)" }
            }
        }
        return sites
    }

    struct Entry { let key, endpoints, status, proof: String }

    static func allowlist() throws -> [Entry] {
        let text = try String(contentsOf: root.appendingPathComponent("docs/graph-allowlist.txt"), encoding: .utf8)
        return text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 4 else { return Entry(key: line, endpoints: "", status: "<malformed>", proof: "") }
            return Entry(key: parts[0], endpoints: parts[1], status: parts[2], proof: parts[3])
        }
    }

    func testEveryGraphCallSiteIsAllowlistedWithProof() throws {
        let sites = try Self.callSites()
        let entries = try Self.allowlist()
        XCTAssertGreaterThan(sites.count, 50, "scanner found too few call sites — the scan itself is broken")
        let keys = Set(entries.map(\.key))
        XCTAssertEqual(keys.count, entries.count, "duplicate allowlist keys")
        let missing = sites.keys.filter { !keys.contains($0) }.sorted()
        XCTAssertTrue(missing.isEmpty, "Graph call sites not in docs/graph-allowlist.txt (add with live proof, or move the call to a Teams service):\n"
            + missing.map { "  \($0) (\(sites[$0]!))" }.joined(separator: "\n"))
        let stale = keys.subtracting(sites.keys).sorted()
        XCTAssertTrue(stale.isEmpty, "allowlist entries with no Graph call site (remove them):\n  " + stale.joined(separator: "\n  "))
        for e in entries {
            XCTAssertTrue(Self.statuses.contains(e.status), "\(e.key): bad status \(e.status)")
            XCTAssertFalse(e.endpoints.isEmpty, "\(e.key): no endpoint")
            switch e.status {
            case "works":
                XCTAssertTrue(e.proof.contains("live") || e.proof.contains("scope"), "\(e.key): works needs a live or scope proof")
                XCTAssertFalse(e.proof.contains("see probeB"), "\(e.key): proof still pending")
            case "blocked":
                XCTAssertTrue(e.proof.contains("not granted"), "\(e.key): blocked needs the missing permission")
            case "unproven":
                XCTAssertTrue(e.proof.contains("owner OK"), "\(e.key): unproven must say what owner OK is needed")
            default:
                XCTAssertTrue(e.proof.contains("not linked by ostmac-core"), "\(e.key): tui-only needs the reachability note")
            }
        }
    }

    /// tui-only entries really are unreachable from the app: the function
    /// name never appears in ostmac-core's non-test code.
    func testTuiOnlyEntriesAreNotLinkedByTheApp() throws {
        var core = ""
        for rel in Self.sources() where rel.hasPrefix("rust/ostmac-core/") {
            core += try Self.codeLines(rel).map(\.1).joined(separator: "\n")
        }
        for e in try Self.allowlist() where e.status == "tui-only" {
            let fn = String(e.key.split(separator: ":").last ?? "")
            XCTAssertNil(Self.firstMatch("(\\b\(fn)\\b)", core), "\(e.key) is marked tui-only but ostmac-core calls \(fn)")
        }
    }

    /// Functions that spell the host for a request body or a poll target,
    /// never as a request of their own: the team template bind value and
    /// the create-team operation poll URL (pure helper; since GRAPHSWEEP3 team create goes to the Teams middle tier).
    private static let hostFunctions: Set<String> = ["standard_team_template", "operation_url"]

    func testGraphHostOnlyInRequestHelpers() throws {
        var bad: [String] = []
        for rel in Self.sources() where Self.hostFiles[rel] == nil {
            var fn = "", previous = ""
            for (n, line) in try Self.codeLines(rel) {
                if let f = Self.firstMatch(#"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)"#, line)
                    ?? Self.firstMatch(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, line) { fn = f }
                defer { previous = line }
                guard line.contains("graph.microsoft.com") else { continue }
                // `…@odata.bind` member/template references are body values.
                if line.contains("odata.bind") || previous.contains("odata.bind") || Self.hostFunctions.contains(fn) { continue }
                bad.append("\(rel):\(n)")
            }
        }
        XCTAssertTrue(bad.isEmpty, "Graph host spelled outside the request helpers (route it through them so the allowlist sees it):\n  "
            + bad.joined(separator: "\n  "))
    }

    /// The guard itself catches a new call site (positive control).
    func testScannerSeesKnownSitesAndNoLongerSeesSwitchedOnes() throws {
        let sites = try Self.callSites()
        XCTAssertNotNil(sites["rust/ost/src/api/teams.rs::list_teams_data"])
        XCTAssertNotNil(sites["swift/Sources/OstMacCore/CalendarGraph.swift::range"])
        XCTAssertNotNil(sites["swift/Sources/OstMacCore/ReadCore.swift::whoami"])
        for switched in [
            "rust/ost/src/api/chat.rs::create_group_chat_data",
            "rust/ost/src/api/chat.rs::list_chat_members_data",
            "rust/ost/src/api/chat.rs::chat_pinned_messages_data",
            "rust/ost/src/api/chat.rs::chat_unpin_message_with_client",
            "rust/ost/src/api/files.rs::list_via_chat_messages",
            "rust/ostmac-core/src/lib.rs::set_presence_json",
            "rust/ostmac-core/src/lib.rs::user_presence_json",
            "swift/Sources/OstMacCore/ReadCore.swift::presence",
            // §GRAPHSWEEP3: Teams middle tier / chat service now.
            "rust/ost/src/api/teams.rs::create_team_data",
            "rust/ost/src/api/teams.rs::update_channel_data",
            "rust/ost/src/api/teams.rs::delete_channel_data",
            "rust/ost/src/api/apps.rs::install_app_for_user",
            "rust/ost/src/api/chat.rs::set_chat_hidden_with_client",
            // §GRAPH2: tags come from the CSA service.
            "rust/ost/src/api/tags.rs::my_tag_cards_data",
            "swift/Sources/OstMacCore/CatchUpTags.swift::load",
        ] {
            XCTAssertNil(sites[switched], "\(switched) still calls Graph")
        }
    }

    /// §GRAPH2: the tag read is a Teams CSA call. Nothing on that path may
    /// name the Graph host or a Graph helper (TeamworkTag.Read is not on the
    /// Teams token), and the Swift side must go through the core FFI.
    func testTagReadNeverTouchesGraph() throws {
        for rel in ["rust/ost/src/api/tags.rs", "rust/ostmac-core/src/catchup_tags.rs"] {
            for (n, line) in try Self.codeLines(rel) {
                XCTAssertFalse(line.contains("graph_get") || line.contains("graph.microsoft.com") || line.contains("graph_post"),
                               "\(rel):\(n) sends the tag read through Graph")
            }
        }
        let swift = try String(contentsOf: Self.root.appendingPathComponent("swift/Sources/OstMacCore/CatchUpTags.swift"),
                               encoding: .utf8)
        guard let load = swift.range(of: "public static func load(") else { return XCTFail("CatchUpTags.load missing") }
        let body = String(swift[load.lowerBound...])
        XCTAssertTrue(body.contains("RustCore.catchUpTags()"))
        XCTAssertFalse(body.contains("graphGET") || body.contains("ownerTagNames"), "CatchUpTags.load must not use the Graph walk")
    }
}
