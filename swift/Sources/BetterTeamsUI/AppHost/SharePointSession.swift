// SharePointSession.swift — SharePoint and OneDrive pages run on a web
// cookie session, not a bearer token (APPNATIVE2). Before such a page
// loads natively, the host signs the account's web store in to each
// SharePoint host with a token from the same broker getAuthToken uses:
// SharePoint's native-client sign-in answers a bearer token with its
// session cookie, which goes into the account's WKWebsiteDataStore.
// The page then opens signed in with no second (web) sign-in.
// Cookie and token values are never logged or shown.
import Foundation
import WebKit

public enum SharePointSession {
    /// SharePoint Online host suffixes (commercial and sovereign clouds).
    static let suffixes = ["sharepoint.com", "sharepoint.us", "sharepoint.de", "sharepoint.cn", "sharepoint-mil.us"]

    public static func isSharePointHost(_ host: String) -> Bool {
        FramePolicy.hostMatches(host.lowercased(), suffixes)
    }

    /// Exact SharePoint hosts a resolved launch loads or asks tokens for:
    /// the content page's host, the token resource's host, and plain
    /// (non-wildcard) validDomains. Order kept, no duplicates.
    public static func hosts(for l: TeamsAppLaunch, content: URL?) -> [String] {
        var raw: [String] = []
        if let h = content?.host { raw.append(h) }
        if let r = l.resource, let h = URL(string: r)?.host { raw.append(h) }
        raw += l.validDomains.filter { !$0.contains("*") && !$0.contains("{") }.compactMap { d in
            URL(string: d.contains("://") ? d : "https://" + d)?.host
        }
        var seen = Set<String>()
        return raw.map { $0.lowercased() }.filter { isSharePointHost($0) && seen.insert($0).inserted }
    }

    /// The native-client sign-in request for `host` (POST, no body).
    static func request(host: String, token: String) -> URLRequest? {
        guard let url = URL(string: "https://\(host)/_api/SP.OAuth.NativeClient/Authenticate") else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json;odata=nometadata", forHTTPHeaderField: "Accept")
        r.setValue("0", forHTTPHeaderField: "Content-Length")
        return r
    }

    /// The session cookies SharePoint set for `host` (https only, and
    /// only for that host or a parent SharePoint domain of it).
    static func cookies(from response: HTTPURLResponse, host: String) -> [HTTPCookie] {
        guard let url = URL(string: "https://\(host)/") else { return [] }
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String, let v = v as? String { fields[k] = v }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { c in
            let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == d || host.hasSuffix("." + d)) && isSharePointHost(d)
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Signed in: this many session cookies stored.
        case signedIn(Int)
        /// No token for the host (the reason, never the token).
        case noToken(String)
        /// SharePoint answered without a session (HTTP status).
        case refused(Int)
        /// Network failure or timeout.
        case unreachable
    }
}

/// Per-account SharePoint sign-ins, each host at most once per
/// `lifetime` (a failed try also waits, so a page never loops).
@MainActor
final class SharePointSessions {
    static let lifetime: TimeInterval = 30 * 60
    private var tried: [String: Date] = [:]
    private(set) var outcomes: [String: SharePointSession.Outcome] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// Hosts not tried within `lifetime`.
    func stale(_ hosts: [String], now: Date = Date()) -> [String] {
        hosts.filter { h in tried[h].map { now.timeIntervalSince($0) >= Self.lifetime } ?? true }
    }

    /// Sign-ins still running, by host.
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Whether a page on `hosts` must wait before it loads: a host is
    /// stale, or its sign-in (started by another page) is still running.
    /// A second page that loaded then would reach SharePoint before the
    /// session cookies and land on a sign-in page.
    func mustWait(_ hosts: [String], now: Date = Date()) -> Bool {
        !stale(hosts, now: now).isEmpty || hosts.contains { inFlight[$0] != nil }
    }

    /// Signs `store` in to every stale host (in parallel), and waits for
    /// those and any sign-in to `hosts` another page already started.
    func prepare(_ hosts: [String], broker: TeamsJSTokenBroker, store: WKWebsiteDataStore) async {
        let now = Date()
        for h in stale(hosts, now: now) {
            tried[h] = now
            inFlight[h] = Task { @MainActor in
                self.outcomes[h] = await self.signIn(h, broker: broker, store: store)
                self.inFlight[h] = nil
            }
        }
        for h in hosts { await inFlight[h]?.value }
    }

    private func signIn(_ host: String, broker: TeamsJSTokenBroker, store: WKWebsiteDataStore) async
        -> SharePointSession.Outcome {
        let token: String
        switch await broker.authToken(resource: "https://\(host)") {
        case .token(let t, _, _): token = t
        case .failure(let why, _):
            let code = why.range(of: "AADSTS").map { "AADSTS" + why[$0.upperBound...].prefix { $0.isNumber } }
            return .noToken(code ?? "token refused")
        }
        guard let req = SharePointSession.request(host: host, token: token),
              let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse
        else { return .unreachable }
        let cookies = SharePointSession.cookies(from: http, host: host)
        guard (200..<300).contains(http.statusCode), !cookies.isEmpty else { return .refused(http.statusCode) }
        for c in cookies { await store.httpCookieStore.setCookie(c) }
        return .signedIn(cookies.count)
    }
}
