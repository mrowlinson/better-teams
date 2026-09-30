// TeamsLinkRouter.swift — the one place a URL leaves the app (LINKGUARD).
//
// Owner rule: a Teams / Microsoft 365 link opens in Better Teams, on the
// matching native screen. Never the browser, never the Teams web app. A
// Microsoft link with no native screen is refused with an error (Copy
// Link), not handed to the browser. Links to anything else (and file,
// mailto, tel and Settings URLs) go to the system, as before.
//
// This file is the only one allowed to call NSWorkspace.open; the guard
// test `TeamsLinkGuardTests` fails the build of any other caller.
import AppKit
import Foundation

public enum TeamsLinkRouter {
    /// Where a URL belongs.
    public enum Family: Equatable, Sendable {
        /// Teams web hosts and `msteams:` links (chat, channel, post,
        /// meeting, profile, app/tab, file).
        case teams
        /// Outlook web hosts (calendar events).
        case outlook
        /// SharePoint, OneDrive and Office document hosts.
        case files
        /// Everything else: the system opens it.
        case other
    }

    public enum Outcome: Equatable, Sendable {
        /// Handed to the system (default browser, Mail, Finder, Settings).
        case system
        /// Opened on a native screen of the app.
        case native
        /// A Microsoft link with no native screen: the error was shown.
        case refused
    }

    public static let outlookHosts = ["outlook.office.com", "outlook.office365.com", "outlook.live.com",
                                      "outlook.cloud.microsoft", "outlook.office365.us"]
    public static let fileHosts = ["sharepoint.com", "sharepoint.us", "sharepoint-df.com", "onedrive.com",
                                   "onedrive.live.com", "1drv.ms", "office.com", "office.net", "officeapps.live.com"]

    public static func family(_ url: URL) -> Family {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "msteams" || scheme == "msteams-beta" { return .teams }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return .other }
        if hostMatches(host, ChatTabCatalog.teamsHosts) { return .teams }
        if hostMatches(host, outlookHosts) { return .outlook }
        if hostMatches(host, fileHosts) { return .files }
        return .other
    }

    /// True when the URL is a Teams / Microsoft 365 link the app must
    /// keep out of the browser.
    public static func isMicrosoftApp(_ url: URL) -> Bool { family(url) != .other }

    static func hostMatches(_ host: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The Graph event id an Outlook web link names: `/calendar/item/<id>`
    /// or `?itemid=<id>` on a `/calendar/` path. Nil for any other link.
    public static func outlookEventID(_ url: URL) -> String? {
        guard family(url) == .outlook else { return nil }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = (c?.percentEncodedPath ?? "").split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        let query = c?.queryItems ?? []
        let calendarPath = parts.contains { $0.lowercased() == "calendar" }
            || query.contains { $0.name.lowercased() == "path" && ($0.value ?? "").lowercased().contains("calendar") }
        guard calendarPath else { return nil }
        if let i = parts.firstIndex(where: { ["item", "read"].contains($0.lowercased()) }),
           parts.count > i + 1, !parts[i + 1].isEmpty {
            return parts[i + 1]
        }
        return query.first { $0.name.lowercased() == "itemid" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: hooks (the UI layer installs the first two; tests replace all three)

    /// Opens a Microsoft link on a native screen. `window` is the window
    /// the link came from (a `WindowModel`), or nil for the key window.
    /// Returns false when no native screen matches.
    @MainActor public static var nativeHandler: ((URL, AnyObject?) -> Bool)?
    /// Shows the error for a Microsoft link that has no native screen.
    @MainActor public static var refusalHandler: ((URL, AnyObject?) -> Void)?
    /// Every URL that is not a Microsoft link, and nothing else, ends here.
    /// Never opens under XCTest.
    public nonisolated(unsafe) static var systemOpener: @Sendable (URL) -> Bool = { url in
        if NSClassFromString("XCTestCase") != nil { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Refusals since launch (diagnostics, tests).
    @MainActor public private(set) static var refusedCount = 0
    @MainActor public private(set) static var lastRefused: URL?

    // MARK: entry points

    /// Opens `url` the way the owner wants: Microsoft links natively (or
    /// refused with an error), everything else via the system. Safe from
    /// any thread; native work hops to the main actor. True unless the
    /// system declined a non-Microsoft URL.
    @discardableResult
    public nonisolated static func open(_ url: URL, window: AnyObject? = nil) -> Bool {
        if family(url) == .other { return systemOpener(url) }
        let box = UncheckedBox(window)
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = route(url, window: box.value) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = route(url, window: box.value) } }
        }
        return true
    }

    /// An explicit "Open in Browser" command: the page itself in the
    /// default browser, except a Teams address (the Teams web app), which
    /// always takes the native route.
    @discardableResult
    public nonisolated static func openInBrowser(_ url: URL, window: AnyObject? = nil) -> Bool {
        if family(url) == .teams { return open(url, window: window) }
        return systemOpener(url)
    }

    /// Main-actor routing with the outcome (tests call this).
    @MainActor
    public static func route(_ url: URL, window: AnyObject? = nil) -> Outcome {
        if family(url) == .other {
            _ = systemOpener(url)
            return .system
        }
        if nativeHandler?(url, window) == true { return .native }
        refusedCount += 1
        lastRefused = url
        refusalHandler?(url, window)
        return .refused
    }

    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ v: T) { value = v }
    }
}
