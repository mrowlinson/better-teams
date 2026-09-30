// PaneContentRules.swift — the content rules every app pane gets
// (APPEFF R5). Requests to hosts that only collect telemetry, analytics
// or session recordings are blocked inside WebKit, before they leave the
// pane: no network, no Networking-process work, and (for the recorders)
// no DOM-watching script running in the app's page.
//
// Only pure collection endpoints are listed: never a host that serves an
// app's code, data, sign-in, configuration or experiments. A blocked
// telemetry call fails the way an offline beacon does, which every such
// SDK already handles. Script CDNs whose code an app might call directly
// (the Application Insights SDK, Tag Manager, Segment's loader) are not
// blocked; only their ingestion hosts are.
import Foundation
import WebKit

@MainActor
enum PaneContentRules {
    /// Blocked hosts (each also blocks its subdomains).
    static let blockedHosts: [String] = [
        // Microsoft 1DS / OneCollector and Aria telemetry ingestion.
        "events.data.microsoft.com",
        "pipe.aria.microsoft.com",
        "vortex.data.microsoft.com",
        // Office telemetry ingestion and its sampling rules.
        "nexus.officeapps.live.com",
        "nexusrules.officeapps.live.com",
        // Office network-performance probes (config, probe, upload) and
        // Content-Security-Policy violation reports.
        "fp.measure.office.com",
        "csp.microsoft.com",
        // Application Insights ingestion + live metrics (not the SDK CDN).
        "applicationinsights.azure.com",
        "dc.services.visualstudio.com",
        "rt.services.visualstudio.com",
        "livediagnostics.monitor.azure.com",
        // Session recorders and analytics.
        "clarity.ms",
        "hotjar.com",
        "hotjar.io",
        "fullstory.com",
        "heapanalytics.com",
        "google-analytics.com",
        "analytics.google.com",
        "stats.g.doubleclick.net",
        "bat.bing.com",
        "api.segment.io",
        "api.mixpanel.com",
        "api-js.mixpanel.com",
        "api.amplitude.com",
        "api2.amplitude.com",
        "nr-data.net",
        "browser-intake-datadoghq.com",
        "browser-intake-datadoghq.eu",
        "ingest.sentry.io",
        "ingest.us.sentry.io",
        "ingest.de.sentry.io",
    ]

    static let identifier = "bt.pane.telemetry"

    /// WebKit's content-rule regex for `host` and its subdomains, any
    /// scheme and port.
    static func urlFilter(_ host: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
    }

    /// The rule list JSON.
    static func encoded() -> String {
        let rules: [[String: Any]] = blockedHosts.map {
            ["trigger": ["url-filter": urlFilter($0)], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private final class WeakController {
        weak var controller: WKUserContentController?
        init(_ c: WKUserContentController) { controller = c }
    }

    private static var list: WKContentRuleList?
    private static var compiling = false
    private static var failed = false
    private static var waiting: [WeakController] = []

    /// Adds the rules to a pane's controller: now, or as soon as they are
    /// compiled (the first pane of a launch may start before that).
    static func apply(to controller: WKUserContentController) {
        if let list {
            controller.add(list)
            return
        }
        guard !failed else { return }
        waiting.append(WeakController(controller))
        prepare()
    }

    /// Compiles the rules once per launch (milliseconds) into a store in
    /// the temporary folder: nothing in the user's Library.
    static func prepare() {
        guard list == nil, !compiling, !failed else { return }
        compiling = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-pane-rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WKContentRuleListStore(url: dir)
        store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded()) { compiled, _ in
            MainActor.assumeIsolated {
                compiling = false
                guard let compiled else {
                    failed = true
                    waiting = []
                    return
                }
                list = compiled
                for w in waiting { w.controller?.add(compiled) }
                waiting = []
            }
        }
        if store == nil {
            compiling = false
            failed = true
        }
    }

    /// The compiled list, once ready (tests).
    static var compiled: WKContentRuleList? { list }
}
