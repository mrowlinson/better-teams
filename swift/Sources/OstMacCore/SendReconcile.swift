// SendReconcile.swift — §106 (SENDFIX): one logical send = one server
// message, and the optimistic bubble always settles.
//
// Every own send carries a client message id (`clientmessageid`, the
// idempotency key). The bubble starts as `pending-<cmid>` ("Sending…")
// and settles on whichever lands first:
//   1. the POST answer (2xx + server id)            → bubble takes the id
//   2. the echo (live push or poll) carrying the cmid → bubble := server row
//   3. a failed/timed-out POST → VERIFY: newest page searched by cmid;
//      found → sent; not found → Failed (Retry).
// Retry re-verifies first, then re-posts with the SAME cmid, so a post
// whose answer was lost is never posted twice. A 2xx without a named id
// verifies once; still unnamed → `sent-<cmid>` (settled, reconciled by
// the next page/echo).
import Foundation

/// One logical send's wire request (the route is resolved by the store).
public struct OutgoingSend: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        case plain
        case reply(parentID: String, parentSender: String, parentText: String)
        case thread(rootID: String)
    }

    public let chatID: String
    public let text: String
    public let route: Route
    public let clientMessageID: String

    public init(chatID: String, text: String, route: Route = .plain, clientMessageID: String) {
        self.chatID = chatID
        self.text = text
        self.route = route
        self.clientMessageID = clientMessageID
    }
}

/// Injectable send wire (tests fake it). Both calls block: run off-main.
public struct SendTransport: Sendable {
    /// POST once; returns the server id when the answer named it.
    public var post: @Sendable (OutgoingSend) throws -> String?
    /// Newest-page lookup by client message id (nil = not posted).
    public var find: @Sendable (_ chatID: String, _ clientMessageID: String) throws -> ChatMessage?

    public init(
        post: @escaping @Sendable (OutgoingSend) throws -> String?,
        find: @escaping @Sendable (_ chatID: String, _ clientMessageID: String) throws -> ChatMessage?
    ) {
        self.post = post
        self.find = find
    }

    /// Core-backed wire (active profile; the store wraps calls in its
    /// account hop).
    public static let live = SendTransport(
        post: { r in
            switch r.route {
            case .plain:
                return try RustCore.sendIdem(
                    chatID: r.chatID, text: r.text, clientMessageID: r.clientMessageID).id
            case .reply(let pid, let sender, let ptext):
                return try RustCore.replyIdem(
                    chatID: r.chatID, parentID: pid, parentSender: sender, parentText: ptext,
                    text: r.text, clientMessageID: r.clientMessageID).id
            case .thread(let root):
                return try RustCore.threadReplyIdem(
                    channelID: r.chatID, rootID: root, text: r.text,
                    clientMessageID: r.clientMessageID).id
            }
        },
        find: { chat, cmid in
            let r = try RustCore.findClientMessage(chatID: chat, clientMessageID: cmid)
            return r.found ? r.message : nil
        })

    /// Diagnostics shim (`--send-timeout-shim`): the first post really
    /// goes out, then reports a timeout as if the answer was lost — the
    /// verify path must settle it without a second post.
    public func losingFirstAnswer() -> SendTransport {
        let armed = ShimLatch()
        let base = self
        return SendTransport(
            post: { r in
                let id = try base.post(r)
                if armed.fire() { throw URLError(.timedOut) }
                return id
            },
            find: base.find)
    }
}

/// One-shot latch (thread-safe) for the timeout shim.
final class ShimLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// How one delivery attempt settled.
public enum SendOutcome: Sendable, Equatable {
    /// Posted. `serverID` when known; `row` when a verify read it back.
    case sent(serverID: String?, row: ChatMessage?, via: Via)
    /// Not on the server as far as the verify read shows.
    case failed(String)

    public enum Via: String, Sendable, Equatable {
        case post, verify
    }
}

public enum SendPipeline {
    /// One blocking delivery attempt (call off-main). `verifyFirst`
    /// (retries): a copy that landed late settles without re-posting.
    /// Any POST error verifies before it can count as failed.
    public static func run(
        _ r: OutgoingSend, transport: SendTransport, verifyFirst: Bool = false
    ) -> SendOutcome {
        if verifyFirst, let row = try? transport.find(r.chatID, r.clientMessageID) {
            return .sent(serverID: row.id, row: row, via: .verify)
        }
        do {
            if let id = try transport.post(r) {
                return .sent(serverID: id, row: nil, via: .post)
            }
            // 2xx without a named id: read it back once (best effort).
            let row = try? transport.find(r.chatID, r.clientMessageID)
            return .sent(serverID: row?.id, row: row, via: .post)
        } catch {
            if let row = try? transport.find(r.chatID, r.clientMessageID) {
                return .sent(serverID: row.id, row: row, via: .verify)
            }
            return .failed(String(describing: error))
        }
    }
}

public enum SendReconcile {
    /// Fresh 19-digit decimal client message id (Teams' shape).
    public static func newClientMessageID() -> String {
        let hi = UInt64.random(in: 100_000_000...999_999_999)
        let lo = UInt64.random(in: 0...9_999_999_999)
        return String(hi) + String(format: "%010llu", lo)
    }

    public static func pendingID(for cmid: String) -> String { "pending-\(cmid)" }
    public static func settledID(for cmid: String) -> String { "sent-\(cmid)" }

    /// Local own-send rows the server can't have named yet.
    public static func isLocalRow(_ m: ChatMessage) -> Bool {
        m.id.hasPrefix("pending-") || m.id.hasPrefix("sent-")
    }

    /// Pure: the row `localID` becomes `server` in place (position kept,
    /// so the timeline never jumps). A row already carrying `server.id`
    /// elsewhere wins and the local row drops (no duplicate). Unknown
    /// `localID` = unchanged.
    public static func replacing(
        _ localID: String, with server: ChatMessage, in list: [ChatMessage]
    ) -> [ChatMessage] {
        guard let i = list.firstIndex(where: { $0.id == localID }) else { return list }
        var out = list
        if server.id != localID, list.contains(where: { $0.id == server.id }) {
            out.remove(at: i)
            return out
        }
        out[i] = server
        return out
    }
}

public extension SendPipeline {
    /// Surfaces without a bubble (quick send, contact card, notification
    /// reply, scheduled, forward): ONE idempotent post, verified on error
    /// (a post whose answer was lost counts as sent, so nobody re-sends a
    /// copy). Throws only when the verify read shows it did not land.
    /// Blocking: call off-main. Returns the server id when known.
    @discardableResult
    static func postVerified(
        chatID: String, text: String, transport: SendTransport = .live
    ) throws -> String? {
        let r = OutgoingSend(chatID: chatID, text: text, clientMessageID: SendReconcile.newClientMessageID())
        switch run(r, transport: transport) {
        case .sent(let id, _, _):
            return id
        case .failed(let err):
            throw CoreCallError.failed(err)
        }
    }
}
