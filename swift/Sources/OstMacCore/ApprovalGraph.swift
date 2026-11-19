// ApprovalGraph.swift — approvals lane: Graph beta Approvals app API
// client. One funnel (`execute`) so the allowlist sees a single call
// site. Tests inject a stub transport; production uses URLSession with
// the profile's Graph token. 401/403 fails closed with the consent
// message (the app token lacks ApprovalSolution.ReadWrite; the trial
// probe 11-19 returned 401 "required scope(s) or role(s) not present").
// Blocking: call off the main thread (same contract as `CoreReads`).
import Foundation
import os

/// One sync Graph request (tests inject stubs; zero live network).
protocol ApprovalHTTP: Sendable {
    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ApprovalHTTPResponse
}

struct ApprovalHTTPResponse: Sendable {
    var status: Int
    var data: Data
}

/// URLSession-backed sync request (semaphore bridge; production use).
struct URLSessionApprovalHTTP: ApprovalHTTP {
    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ApprovalHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let request = req
        return try SyncBridge.run {
            let (data, resp) = try await URLSession.shared.data(for: request)
            return ApprovalHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
    }
}

/// One approvals operation (method + path + body in one place).
public enum ApprovalOperation: Sendable {
    /// `GET /solutions/approval/approvalItems` (received + sent).
    case list
    /// `GET /solutions/approval/approvalItems/{id}`.
    case get(String)
    /// `GET /solutions/approval/approvalItems/{id}/responses`.
    case responses(String)
    /// `POST .../{id}/responses` (approve or reject + optional comment).
    case respond(id: String, response: String, comments: String?)
    /// `POST .../{id}/cancel` (owner only; the service enforces it).
    case cancel(String)
}

public struct ApprovalGraph: Sendable {
    /// Beta base (the Approvals app API is beta-only). Spelled here so
    /// call sites never carry the host (allowlist lint).
    static let betaBase = "https://graph.microsoft.com/beta"
    static let itemsPath = "/solutions/approval/approvalItems"
    /// Decoder for Graph DateTimeOffset fields.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    var http: any ApprovalHTTP
    var token: @Sendable () throws -> String

    init(http: any ApprovalHTTP, token: @escaping @Sendable () throws -> String) {
        self.http = http
        self.token = token
    }

    /// Signed-in profile, URLSession transport.
    public static func production() -> ApprovalGraph {
        ApprovalGraph(http: URLSessionApprovalHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "approvals", ctx: CoreReads.production())
        }
    }

    // MARK: transport

    static func encode(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// Graph `error.message` (or code) of a failed call.
    static func graphError(_ data: Data) -> String {
        struct E: Decodable {
            struct Inner: Decodable {
                let code: String?
                let message: String?
            }
            let error: Inner?
        }
        let e = try? JSONDecoder().decode(E.self, from: data)
        return e?.error?.message ?? e?.error?.code ?? "request failed"
    }

    /// Run one approvals operation; non-2xx throws a user-facing error
    /// (no URL, no body echo of tokens). 401/403 means the token lacks
    /// `ApprovalSolution.ReadWrite`: fail closed with the consent story,
    /// never a bare status code. Every case calls `request` with a
    /// literal method so the allowlist lint sees this one call site.
    @discardableResult
    public func execute(_ op: ApprovalOperation) throws -> Data {
        switch op {
        case .list:
            return try request("GET", Self.itemsPath + "?$top=50&$orderby=createdDateTime desc", json: nil)
        case .get(let id):
            return try request("GET", Self.itemsPath + "/" + Self.encode(id), json: nil)
        case .responses(let id):
            return try request("GET", Self.itemsPath + "/" + Self.encode(id) + "/responses?$top=100", json: nil)
        case .respond(let id, let response, let comments):
            var body: [String: Any] = ["response": response]
            if let comments, !comments.isEmpty { body["comments"] = comments }
            return try request("POST", Self.itemsPath + "/" + Self.encode(id) + "/responses", json: body)
        case .cancel(let id):
            return try request("POST", Self.itemsPath + "/" + Self.encode(id) + "/cancel", json: nil)
        }
    }

    /// One request; non-2xx throws a user-facing error (no URL, no body
    /// echo of tokens).
    @discardableResult
    private func request(_ method: String, _ path: String, json: [String: Any]?) throws -> Data {
        let full = Self.betaBase + path
        guard let url = URL(string: full), url.host == "graph.microsoft.com" else {
            throw CoreCallError.failed("approvals: bad Graph path")
        }
        var headers = ["Authorization": "Bearer \(try token())"]
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            headers["Content-Type"] = "application/json"
        }
        let resp: ApprovalHTTPResponse
        do {
            resp = try http.send(method, url: url, headers: headers, body: body)
        } catch {
            throw CoreCallError.failed("approvals: \(method) failed: \(error.localizedDescription)")
        }
        if resp.status == 401 || resp.status == 403 {
            throw CoreCallError.failed(
                "approvals: the sign-in lacks ApprovalSolution.ReadWrite — ask the owner for admin consent, then retry.")
        }
        guard (200 ... 299).contains(resp.status) else {
            throw CoreCallError.failed("approvals: HTTP \(resp.status) (\(Self.graphError(resp.data)))")
        }
        return resp.data
    }
}
