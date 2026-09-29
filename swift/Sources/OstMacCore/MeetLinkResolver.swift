// MeetLinkResolver.swift — FIXPACK F12: a short Teams `/meet/` link resolves
// to its meeting thread natively, by following the redirect chain read-only.
// No Teams web page is loaded and no browser is opened: each hop is one GET
// whose first redirect is captured and stopped, the response body is never
// read, and no cookies or credentials are sent.
import Foundation

public enum MeetLinkResolver {
    /// One hop: the URL the given one redirects to (nil = no redirect,
    /// unreachable, or a body-bearing answer, which is never read).
    public typealias Hop = @Sendable (URL) async -> URL?

    /// Microsoft Teams hosts: teams.microsoft.com, teams.live.com,
    /// teams.cloud.microsoft and any subdomain of them. Host-exact: a look-alike
    /// such as `teams.microsoft.com.example.net` is NOT Microsoft.
    public static func isMicrosoftTeamsHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasSuffix(".") { h.removeLast() }  // fully-qualified form: teams.microsoft.com.
        for root in ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"] {
            if h == root || h.hasSuffix("." + root) { return true }
        }
        return false
    }

    public static func isMicrosoftTeamsURL(_ url: URL) -> Bool {
        isMicrosoftTeamsHost(url.host)
    }

    /// A short meeting link: `/meet/<id>` on a Microsoft Teams host.
    public static func isShortMeetLink(_ url: URL) -> Bool {
        isMicrosoftTeamsURL(url) && url.path.lowercased().hasPrefix("/meet/")
    }

    /// The meeting thread id a URL carries: a `meetup-join` link, or the
    /// launcher form (`/dl/launcher/…?url=%2F_%23%2Fl%2Fmeetup-join%2F19%3A…`).
    static func thread(in url: URL) -> String? {
        let raw = url.absoluteString
        let parsed = JoinParse.parse(raw: raw)
        if parsed.kind == "thread", let tid = parsed.threadID { return tid }
        let decoded = JoinParse.pctDecode(raw)
        if decoded.lowercased().contains("meetup-join") { return JoinParse.extractThreadID(decoded) }
        return nil
    }

    /// Follow up to `maxHops` redirects from `start` and return the thread
    /// id of the first hop that carries a meeting thread.
    /// Only Microsoft Teams hops are followed; nil when the chain ends
    /// without a thread (the caller shows an error, never a browser).
    public static func resolve(_ start: URL, maxHops: Int = 5, hop: Hop) async -> String? {
        var current = start
        for _ in 0 ..< maxHops {
            guard isMicrosoftTeamsURL(current), let next = await hop(current) else { return nil }
            if let tid = thread(in: next) { return tid }
            current = next
        }
        return nil
    }

    /// Live hop: a cookie-less, credential-less, cache-less GET that stops at
    /// the first redirect (and at any non-redirect answer, unread).
    public static let liveHop: Hop = { url in
        await withCheckedContinuation { cont in
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 6
            cfg.timeoutIntervalForResource = 8
            let stop = StopAtRedirect(cont)
            let session = URLSession(configuration: cfg, delegate: stop, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("text/html", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: req)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    private final class StopAtRedirect: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<URL?, Never>?
        init(_ c: CheckedContinuation<URL?, Never>) { cont = c }

        private func finish(_ url: URL?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: url)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            finish(request.url)
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            // A page, not a redirect: never read it.
            finish(nil)
            completionHandler(.cancel)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(nil)
        }
    }
}
