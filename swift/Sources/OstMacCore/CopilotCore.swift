// CopilotCore.swift — COPILOT-BUILD live transport: core FFI calls.
//
// Blocking FFI + network; the store runs these off the main thread.
// Failures arrive typed (`CopilotFailure.kind`) so the chat input can
// disable itself with the honest reason instead of a spinner.
import COstMac
import Foundation

/// Typed Copilot failure. `kind` drives the disabled-with-reason UI.
public struct CopilotFailure: Error, Sendable {
    public enum Kind: Sendable, Equatable {
        /// Sign in first (no cached auth / token mint refused).
        case auth
        /// The Taiger gate (UNLICENSED / NO_ACCESS).
        case license
        /// Transport or server failure (text is the reason).
        case server
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Taiger licence payload (core `copilot_license_status`).
public struct CopilotLicensePayload: Decodable, Sendable {
    public let status: String
    public let licensed: Bool
    public let reason: String?
    public let error: String?
}

/// Turn-start payload (core `copilot_chat_start`).
public struct CopilotTurnStart: Decodable, Sendable {
    public let turnID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
    }
}

/// One attribution (type:2 `sourceAttributions` row).
public struct CopilotAttributionPayload: Decodable, Sendable {
    public let title: String
    public let url: String
}

/// Final answer payload (core `answer`; `cards`/`throttling` stay
/// core-side until a card renderer exists — unknown keys ignored).
public struct CopilotAnswerPayload: Decodable, Sendable {
    public let text: String
    public let attributions: [CopilotAttributionPayload]?
    public let suggestions: [String]?
    public let conversationID: String?
    public let chatName: String?

    enum CodingKeys: String, CodingKey {
        case text, attributions, suggestions
        case conversationID = "conversation_id"
        case chatName = "chat_name"
    }
}

/// Poll payload (core `copilot_chat_poll`; `text` is cumulative).
public struct CopilotPollPayload: Decodable, Sendable {
    public let turnID: String
    public let text: String
    public let done: Bool
    public let progress: String?
    public let answer: CopilotAnswerPayload?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case text, done, progress, answer, error
    }
}

/// Core failure envelope (`{ok:false}` + either `{code,error}` or the
/// shared `{error:code,detail}` shape).
struct CopilotFailureEnvelope: Decodable {
    let ok: Bool
    let code: String?
    let error: String?
    let detail: String?
}

/// Injected transport (core live, demo/tests stubbed).
public protocol CopilotTransport: Sendable {
    func license() throws -> CopilotLicensePayload
    func start(prompt: String, conversationID: String?) throws -> String
    func poll(turnID: String) throws -> CopilotPollPayload
    func stop(turnID: String) throws
}

/// Live transport over the `ostmac_copilot_*` FFI.
public struct CoreCopilotTransport: CopilotTransport {
    public init() {}

    public func license() throws -> CopilotLicensePayload {
        try Self.decode(ostmac_copilot_license_status())
    }

    public func start(prompt: String, conversationID: String?) throws -> String {
        let arg: String
        if let c = conversationID, !c.isEmpty {
            let obj = ["prompt": prompt, "conversation_id": c]
            arg = String(decoding: try JSONEncoder().encode(obj), as: UTF8.self)
        } else {
            arg = prompt
        }
        let r: CopilotTurnStart = try arg.withCString { try Self.decode(ostmac_copilot_chat_start($0)) }
        return r.turnID
    }

    public func poll(turnID: String) throws -> CopilotPollPayload {
        try turnID.withCString { try Self.decode(ostmac_copilot_chat_poll($0)) }
    }

    public func stop(turnID: String) throws {
        struct Ack: Decodable {}
        let _: Ack = try turnID.withCString { try Self.decode(ostmac_copilot_chat_stop($0)) }
    }

    /// Take a Rust-allocated C string, throw the typed failure on
    /// `{ok:false}` (keeping `code`), else decode `T`. Never traps.
    static func decode<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let raw else { throw CopilotFailure(.server, "null from core") }
        defer { ostmac_free(raw) }
        let data = Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
        return try decode(data)
    }

    /// Same over already-owned bytes (tests pin the envelopes here).
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        if let env = try? JSONDecoder().decode(CopilotFailureEnvelope.self, from: data), !env.ok {
            // Shared shape `{error:code,detail}` vs ours `{code,error}`.
            let code = env.code ?? env.error ?? "server"
            let message = env.detail ?? env.error ?? code
            let kind: CopilotFailure.Kind
            switch code {
            case "auth": kind = .auth
            case "license": kind = .license
            default: kind = .server
            }
            throw CopilotFailure(kind, kind == .server ? "\(code): \(message)" : message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CopilotFailure(.server, "bad Copilot answer: \(error)")
        }
    }
}
