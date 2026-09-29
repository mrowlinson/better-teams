// WebSessionKeeper.swift — keeps an account's Microsoft web session
// across quits (APPNATIVE4: zero second login). Signing in without
// "Stay signed in" leaves the Microsoft login cookies session-only, and
// WebKit drops session-only cookies when the app quits: the next launch
// would show a Microsoft sign-in page inside an app pane. Every
// session-only login cookie is saved again with an expiry, so the
// session made by the app's own sign-in serves every app, every launch.
// Cookie values are copied, never read out or logged.
import Foundation
import WebKit

@MainActor
final class WebSessionKeeper: NSObject, WKHTTPCookieStoreObserver {
    /// Microsoft sign-in hosts whose session cookies make the web session.
    nonisolated static let hosts = ["login.microsoftonline.com", "login.microsoft.com", "login.windows.net"]
    /// Matches the "Stay signed in" session lifetime.
    nonisolated static let lifetime: TimeInterval = 90 * 24 * 3600

    /// One keeper per store, for the life of the process (cookie stores
    /// hold their observers weakly).
    private static var keepers: [ObjectIdentifier: WebSessionKeeper] = [:]

    /// Starts keeping `store`'s web session (idempotent) and saves any
    /// session-only login cookie it holds now.
    static func watch(_ store: WKWebsiteDataStore) {
        guard store.isPersistent else { return }
        let id = ObjectIdentifier(store)
        if let k = keepers[id] { k.keep(); return }
        let k = WebSessionKeeper(store.httpCookieStore)
        keepers[id] = k
        k.keep()
    }

    /// A Microsoft login cookie WebKit would drop at quit.
    nonisolated static func needsKeeping(_ c: HTTPCookie) -> Bool {
        guard c.isSessionOnly else { return false }
        let domain = (c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain).lowercased()
        return FramePolicy.hostMatches(domain, hosts)
    }

    /// The same cookie with an expiry (no longer session-only).
    nonisolated static func persistent(_ c: HTTPCookie, now: Date = Date()) -> HTTPCookie? {
        var p = c.properties ?? [:]
        p[.expires] = now.addingTimeInterval(lifetime)
        p.removeValue(forKey: .discard)
        p.removeValue(forKey: .maximumAge)
        let out = HTTPCookie(properties: p)
        return out?.isSessionOnly == false ? out : nil
    }

    private weak var store: WKHTTPCookieStore?
    private var busy = false

    private init(_ store: WKHTTPCookieStore) {
        self.store = store
        super.init()
        store.add(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.keep() }
    }

    func keep() {
        guard !busy, let store else { return }
        busy = true
        store.getAllCookies { [weak self] all in
            let saved = all.filter(Self.needsKeeping).compactMap { Self.persistent($0) }
            for c in saved { store.setCookie(c) }
            Task { @MainActor in self?.busy = false }
        }
    }
}
