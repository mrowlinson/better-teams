// ShareOutlook.swift — SHAREOUTLOOK lane: share one chat message as
// email through Graph sendMail.
//
// The app's Teams token scopes (docs/graph-allowlist.txt) do NOT list
// Mail.Send, so the send maps a 403 to a capability message instead of
// retrying. Pure draft builders + the Graph client on the CalendarGraph
// seam (tests inject stubs; zero live network).
import Foundation

/// One share-to-Outlook draft: recipient + subject + body.
public struct ShareOutlookDraft: Equatable, Sendable {
    public var to: String
    public var subject: String
    public var body: String

    public init(to: String = "", subject: String = "", body: String = "") {
        self.to = to
        self.subject = subject
        self.body = body
    }

    /// Prefill from a message: To stays empty (the user types it),
    /// the subject names the sender, the body is the bubble text.
    public static func prefill(from message: ChatMessage) -> ShareOutlookDraft {
        let who = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = who.isEmpty ? "Unknown" : who
        return ShareOutlookDraft(
            to: "",
            subject: "Message from \(name)",
            body: MessageActions.copyText(for: message))
    }

    /// Minimal address check: one @ with text on both sides and a dot
    /// in the domain half.
    public static func isValidAddress(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.filter({ $0 == "@" }).count == 1 else { return false }
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = String(parts[1])
        guard let dot = domain.range(of: ".", options: .backwards) else { return false }
        return !domain[..<dot.lowerBound].isEmpty && !domain[dot.upperBound...].isEmpty
    }

    /// Send enables with a valid To and a non-blank body (the subject
    /// may stay blank — Graph accepts it).
    public var canSend: Bool {
        Self.isValidAddress(to) && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// POST /me/sendMail JSON: the message plus saveToSentItems so the
    /// sent mail is verifiable (and deletable) in the sender's mailbox.
    public func sendMailBody() -> [String: Any] {
        let address = to.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "message": [
                "subject": subject,
                "body": ["contentType": "Text", "content": body],
                "toRecipients": [["emailAddress": ["address": address]]],
            ] as [String: Any],
            "saveToSentItems": true,
        ]
    }
}

/// Graph sendMail client (the CalendarGraph seam; tests inject stubs).
public struct ShareOutlookGraph: Sendable {
    var graph: CalendarGraph

    init(http: any CalendarHTTP, token: @escaping @Sendable () throws -> String) {
        graph = CalendarGraph(http: http, token: token)
    }

    /// Signed-in profile, URLSession transport.
    public static func production() -> ShareOutlookGraph {
        ShareOutlookGraph(http: URLSessionCalendarHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "share", ctx: CoreReads.production())
        }
    }

    /// Sends one draft (explicit user action only — the sheet's Send).
    /// A 403 is the missing-scope capability message (the Teams token
    /// does not list Mail.Send); anything else throws user-facing text.
    public func send(_ draft: ShareOutlookDraft) throws {
        do {
            try graph.request("POST", "/me/sendMail", json: draft.sendMailBody())
        } catch let e as CoreCallError {
            if case .failed(let msg) = e, msg.contains(" 403") {
                throw CoreCallError.failed("share: not allowed — Mail.Send is not granted.")
            }
            throw e
        }
    }
}
