// CatchUp.swift — om-catchup lane: opt-in AI thread catch-up.
//
// AICATCH (2026-09-28): Apple's on-device model is the default and the
// ONLY engine the UI shows. One setting, `CatchUpMode` (Off / When I
// click the AI button / Always up to date). The OpenCode CLI and
// OpenAI-compatible providers are DEPRECATED — kept compiled and
// tested for a possible return, reachable only when the hidden
// defaults key `BetterTeams.deprecatedOpencodeCatchUp` is true (see
// `CatchUp.deprecatedProvidersKey`). With the key off, a stored legacy
// provider loads as on-device and Settings shows no provider choice.
//
// IDEA-only inspiration from Teamsly (AGPL): a summarize / TL;DR /
// action-items entry point on long threads. No Teamsly code is used here.
//
// Contract:
//   - OFF by default; nothing leaves the machine until the user enables
//     it and taps Summarize.
//   - Provider picker (OpenCode CLI | OpenAI-compatible | On-device)
//     + configurable base URL + model (om-settings-org retired the
//     Zen-HTTPS "OpenCode" row; the CLI covers that account via
//     `opencode auth login`). OpenCode CLI is
//     the default and is CLI-ONLY: it always shells out to `opencode
//     run` (CLI auth covers the free-tier Spark model) and never
//     attempts HTTPS, even when a key is configured. Direct
//     providers use HTTPS only and still require a key. On-device
//     uses Apple Foundation Models (ANE, private, zero bytes
//     off-machine), needs no key/URL/CLI, and caches per thread.
//   - The key lives in the macOS keychain (service
//     "dev.ostmac.OstMac.catchup", account "catchup-api-key"), never
//     in UserDefaults/plist. The Settings key field writes keychain.
//     The key is only used by the direct-HTTPS path.
//   - The privacy note (thread text leaves the machine) shows in both
//     Settings and the sheet, every time.
//   - Tests inject a mock transport (same seam style as PresenceStore's
//     fetchers) + a memory key store; live direct traffic goes through
//     URLSessionCatchUpTransport, live CLI traffic through
//     OpenCodeCLICatchUpTransport + an injected CatchUpCLIRunner.
//   - Every failure surfaces in the UI as .failed(detail); nothing
//     fails silently.
//
// OpenCode discovery (opencode.ai, 2026-09-22):
//   - Config file: opencode.json — {"$schema":
//     "https://opencode.ai/config.json", "provider": {<id>: {"npm":
//     "@ai-sdk/openai-compatible", "name": ..., "options":
//     {"baseURL": ...}, "models": {<model-id>: {...}}}}}
//   - Hosted API (OpenCode Zen): base https://opencode.ai/zen/v1,
//     OpenAI-compatible; POST {base}/chat/completions, auth
//     `Authorization: Bearer <key>` (key from https://opencode.ai/auth,
//     env OPENCODE_API_KEY). Model-id format on Zen: bare ids
//     ("provider/model" only in opencode.json references).
//   - 'Meta Muse Spark 1.3 Free' candidates: Zen
//     "muse-spark-1.3-contributor-free" ($0, models.dev opencode page,
//     exact name match) > Zen "muse-spark-1.3" (paid $1.25/$4.25) >
//     OpenRouter "meta/muse-spark-1.3:free" (wrong provider for the
//     Zen base URL) > "muse-spark-1.2-contributor-free" (free, older).
//     Preloaded CLI id: "opencode/muse-spark-1.3-contributor-free"
//     (PROVIDER-QUALIFIED): `opencode run` rejects the bare id
//     (exit 1 + {"type":"error",...} on stdout, probed 2026-09-24)
//     and only the qualified id succeeds.
import Foundation
import Security
import Combine

// MARK: - Pure helpers

public enum CatchUp {
    /// Hidden defaults key (Bool): true re-enables the deprecated
    /// provider picker (OpenCode CLI, OpenAI-compatible) in Settings ▸
    /// AI and honors a stored legacy provider. Deprecated: kept for
    /// possible return. `defaults write <bundle-id>
    /// BetterTeams.deprecatedOpencodeCatchUp -bool YES`.
    public static let deprecatedProvidersKey = "BetterTeams.deprecatedOpencodeCatchUp"

    /// Threads this long (or longer) get the Catch-up entry point.
    public static let threshold = 20
    /// Max transcript chars sent to the model; overflow drops the head.
    public static let maxTranscriptChars = 12_000

    public static let privacyNote =
        "Catch-up sends this thread's text to your configured AI endpoint. It leaves this machine."

    public static let onDevicePrivacyNote =
        "Catch Up summarizes on this Mac. Your conversations never leave it."

    /// Sheet + Settings privacy line for the active provider.
    public static func privacyNote(for provider: CatchUpProvider) -> String {
        provider == .onDevice ? onDevicePrivacyNote : privacyNote
    }

    public static func shouldOffer(messageCount: Int) -> Bool {
        messageCount >= threshold
    }

    /// True when the Base URL affects requests: direct providers
    /// always use it; the CLI provider never does (exclusive routing:
    /// CLI-selected shells out and ignores baseURL even with a key
    /// set), and the on-device provider has no endpoint at all. The
    /// Settings row hides exactly when this is false, so no dead row
    /// is ever shown.
    /// - Note: `apiKey` is kept for caller compatibility; it plays no
    ///   role under exclusive routing.
    public static func usesBaseURL(provider: CatchUpProvider, apiKey: String) -> Bool {
        _ = apiKey
        return provider != .openCodeCLI && provider != .onDevice
    }

    /// True when an API key affects requests: direct providers only.
    /// The CLI provider authenticates via `opencode auth login`; the
    /// on-device provider needs no credential at all.
    public static func usesAPIKey(provider: CatchUpProvider) -> Bool {
        provider != .openCodeCLI && provider != .onDevice
    }

    /// True when the Model field affects requests: every provider but
    /// on-device (the system model is fixed).
    public static func usesModel(provider: CatchUpProvider) -> Bool {
        provider != .onDevice
    }

    /// "{base}/chat/completions" — exactly one join slash.
    public static func endpoint(baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/chat/completions"
    }

    /// "Sender: one-line content" per message, oldest first, tail-capped
    /// at maxTranscriptChars on a line boundary when possible.
    public static func transcript(from messages: [ChatMessage]) -> String {
        let lines = messages.map { "\($0.sender): \(singleLine($0.content))" }
        var text = lines.joined(separator: "\n")
        if text.count > maxTranscriptChars {
            text = String(text.suffix(maxTranscriptChars))
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
        }
        return text
    }

    /// TL;DR + key points + action items instruction over the transcript.
    public static func prompt(transcript: String) -> String {
        """
        Catch me up on this chat thread. Reply in exactly three sections:
        1. TL;DR — two sentences max.
        2. Key points — short bullets, oldest first.
        3. Action items — one bullet per item, with owner when named, else "Unassigned".

        Thread:
        \(transcript)
        """
    }

    /// OpenAI-compatible chat-completions body (pure, test seam).
    public static func requestBody(model: String, prompt: String) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Config

/// AI endpoint provider. Switching preloads that provider's base URL
/// + model (see `CatchUpStore.selectProvider`).
/// `.onDevice` is the product. `.openCodeCLI` and `.openAICompatible`
/// are Deprecated: kept for possible return — hidden unless
/// `CatchUp.deprecatedProvidersKey` is set.
public enum CatchUpProvider: String, Sendable, Equatable, CaseIterable, Identifiable {
    case openAICompatible = "openai-compatible"
    case openCodeCLI = "opencode-cli"
    case onDevice = "on-device"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .openCodeCLI: "OpenCode CLI"
        case .onDevice: "On-device (Apple Intelligence)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        case .openCodeCLI: "https://opencode.ai/zen/v1"
        // No endpoint (unused; the row hides via usesBaseURL).
        case .onDevice: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAICompatible: "gpt-4o-mini"
        // Qualified: `opencode run` rejects the bare Zen id (exit 1 +
        // {"type":"error",...} on stdout); only the qualified id
        // succeeds (see header).
        case .openCodeCLI: "opencode/muse-spark-1.3-contributor-free"
        // System model (fixed; the row hides via usesModel).
        case .onDevice: ""
        }
    }

    /// Stored-value migration (om-settings-org): the retired
    /// Zen-HTTPS "opencode" row maps onto the CLI provider (same
    /// account via `opencode auth login`); unknown values stay nil
    /// (the store keeps its default).
    public static func stored(rawValue: String) -> CatchUpProvider? {
        CatchUpProvider(rawValue: rawValue)
            ?? (rawValue == "opencode" ? .openCodeCLI : nil)
    }
}

/// Catch Up config. `mode` defaults `.off`; the provider defaults to
/// on-device (no URL, model, or key). BYO credentials only matter to
/// the deprecated providers. The key is in-memory only here —
/// persisted in the keychain, never in UserDefaults (see
/// `CatchUpStore.save`).
public struct CatchUpConfig: Sendable, Equatable {
    public var provider: CatchUpProvider
    public var mode: CatchUpMode
    public var baseURL: String
    public var model: String
    public var apiKey: String

    /// Catch Up on at all (any mode but `.off`). Setting true from
    /// `.off` picks on-click; setting false turns it off.
    public var enabled: Bool {
        get { mode != .off }
        set { mode = newValue ? (mode == .off ? .onClick : mode) : .off }
    }

    public init(
        provider: CatchUpProvider = .onDevice,
        enabled: Bool = false,
        mode: CatchUpMode? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        apiKey: String = ""
    ) {
        self.provider = provider
        self.mode = mode ?? (enabled ? .onClick : .off)
        // Unset endpoint fields follow the provider (on-device: none).
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.model = model ?? provider.defaultModel
        self.apiKey = apiKey
    }

    /// Preset config for a provider: its base URL + model, key untouched.
    public func withProvider(_ provider: CatchUpProvider) -> CatchUpConfig {
        var out = self
        out.provider = provider
        out.baseURL = provider.defaultBaseURL
        out.model = provider.defaultModel
        return out
    }
}

// MARK: - Errors

public enum CatchUpError: Error, Sendable, Equatable {
    case off
    case missingKey
    case badURL
    case empty
    case server(String)
    case forbidden
    case cliMissing
    case cliAuthExpired
    case cliTimeout
    case cliBadOutput
    case onDeviceUnsupported
    case onDeviceUnavailable(String)
    case onDeviceFailed(String)

    /// Pure HTTP-status mapping (test seam): 403 gets its own clean
    /// message; every other non-2xx stays a generic server failure.
    public static func http(_ statusCode: Int) -> CatchUpError {
        statusCode == 403 ? .forbidden : .server("HTTP \(statusCode)")
    }

    public var message: String {
        switch self {
        case .off: "Catch Up is off. Turn it on in Settings ▸ AI."
        case .missingKey: "No API key. Add your key in Settings first."
        case .badURL: "Bad base URL. Check it in Settings."
        case .empty: "The endpoint returned an empty summary."
        case let .server(detail): "Catch-up failed: \(detail)"
        case .forbidden: "The endpoint refused the request (HTTP 403). Check your API key and model access, then retry."
        case .cliMissing: "opencode CLI not found. Install it from opencode.ai, run `opencode auth login`, then retry."
        case .cliAuthExpired: "OpenCode CLI login expired. Run `opencode auth login` and retry."
        case .cliTimeout: "OpenCode CLI timed out. Retry."
        case .cliBadOutput: "OpenCode CLI returned unreadable output. Retry."
        case .onDeviceUnsupported: "Catch Up needs an Apple silicon Mac with Apple Intelligence. This Mac can't run it."
        case let .onDeviceUnavailable(guidance): guidance
        case let .onDeviceFailed(detail): "On-device summary failed: \(detail)"
        }
    }

    /// True for the on-device cases (drives the sheet's guidance box).
    public var isOnDevice: Bool {
        switch self {
        case .onDeviceUnsupported, .onDeviceUnavailable, .onDeviceFailed: true
        default: false
        }
    }
}

// MARK: - Key storage

/// API-key persistence seam. Live = macOS keychain; tests and the
/// --show-catchup shot hook inject `CatchUpMemoryKeyStore` so they
/// never touch the real keychain.
public protocol CatchUpKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String)
    func clear()
}

/// macOS keychain item: service "dev.ostmac.OstMac.catchup", account
/// "catchup-api-key". Preload from a shell (key via $KEY only):
///   security add-generic-password -a catchup-api-key \
///     -s dev.ostmac.OstMac.catchup -w "$KEY" -U
public struct CatchUpSystemKeychain: CatchUpKeyStore {
    public static let service = "dev.ostmac.OstMac.catchup"
    public static let account = "catchup-api-key"

    public init() {}

    public func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public func save(_ key: String) {
        guard !key.isEmpty else { clear(); return }
        let data = Data(key.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            _ = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        _ = SecItemDelete(q as CFDictionary)
    }
}

/// In-memory key store for tests, previews, and the shot hook.
public final class CatchUpMemoryKeyStore: CatchUpKeyStore, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() -> String? { key }
    public func save(_ key: String) { self.key = key.isEmpty ? nil : key }
    public func clear() { key = nil }
}

// MARK: - Transport

/// One OpenAI-compatible chat completion. The mock seam: tests and the
/// --show-catchup shot hook inject fakes; live uses URLSession.
public protocol CatchUpTransport: Sendable {
    func complete(baseURL: String, apiKey: String, model: String, prompt: String) async throws -> String
}

/// Deprecated: kept for possible return (OpenAI-compatible provider,
/// hidden behind `CatchUp.deprecatedProvidersKey`).
/// Live transport: POST {baseURL}/chat/completions, Bearer key.
public struct URLSessionCatchUpTransport: CatchUpTransport {
    public init() {}

    public func complete(baseURL: String, apiKey: String, model: String, prompt: String) async throws -> String {
        guard let url = URL(string: CatchUp.endpoint(baseURL: baseURL)) else {
            throw CatchUpError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = CatchUp.requestBody(model: model, prompt: prompt)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CatchUpError.server("no response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CatchUpError.http(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw CatchUpError.empty
        }
        return text
    }
}

/// Minimal chat-completions response: choices[0].message.content.
public struct ChatCompletionsResponse: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Message: Decodable, Sendable {
            public let content: String
        }

        public let message: Message
    }

    public let choices: [Choice]
}

/// Canned transport for tests, previews, and the --show-catchup shot
/// hook. Records every prompt it was given.
public final class CatchUpCannedTransport: CatchUpTransport, @unchecked Sendable {
    public private(set) var prompts: [String] = []
    public var stub: String
    public var failure: Error?

    public init(stub: String = "", failure: Error? = nil) {
        self.stub = stub
        self.failure = failure
    }

    public func complete(baseURL _: String, apiKey _: String, model _: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if let failure { throw failure }
        return stub
    }
}

/// Demo transport (`--demo`): a canned summary per demo conversation
/// (`DemoData.catchUpSummaries`, matched on the prompt's transcript).
/// Evidence seam: while `holding`, a run streams `holdPartial` (when
/// set) and never finishes, so captures show the streaming and
/// updating states. Never a model, network or CLI.
public final class CatchUpDemoTransport: CatchUpStreamingTransport, @unchecked Sendable {
    public var holding = false
    public var holdPartial: String?

    public init() {}

    public func complete(baseURL _: String, apiKey _: String, model _: String, prompt: String) async throws -> String {
        try await stream(prompt: prompt, maxTokens: nil) { _ in }
    }

    public func stream(prompt: String, maxTokens _: Int?, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        if holding {
            if let holdPartial { onPartial(holdPartial) }
            try await Task.sleep(for: .seconds(3600))
        }
        if let canned = DemoData.catchUpSummaries.first(where: { prompt.contains($0.marker) })?.text { return canned }
        return Self.extractive(prompt) ?? DemoData.catchUpSummary
    }

    /// Demo summary built from the prompt's own message lines (so each
    /// period tab shows what it actually read): who spoke, then the most
    /// salient lines as points. Never a model.
    static func extractive(_ prompt: String) -> String? {
        let lines = prompt.components(separatedBy: "\n").filter { l in
            guard let r = l.range(of: ": "), !l.hasPrefix(" ") else { return false }
            let sender = l[..<r.lowerBound]
            return !sender.isEmpty && sender.count <= 40 && sender.first?.isUppercase == true
                && !sender.contains(".") && !["SUMMARY", "POINTS", "ACTIONS", "Messages, oldest first, one per line as \"Sender"].contains(String(sender))
        }
        guard !lines.isEmpty else { return nil }
        var senders: [String] = []
        for l in lines {
            let s = String(l[..<l.range(of: ": ")!.lowerBound])
            if !senders.contains(s) { senders.append(s) }
        }
        let ctx = CatchUpFilterContext(now: DemoData.catchUpNow)
        let ranked = lines.enumerated().sorted { a, b in
            let sa = CatchUpNoise.salience(ChatMessage(id: "", sender: "", timestamp: "", content: a.element), ctx)
            let sb = CatchUpNoise.salience(ChatMessage(id: "", sender: "", timestamp: "", content: b.element), ctx)
            return sa != sb ? sa > sb : a.offset > b.offset
        }.prefix(4).sorted { $0.offset < $1.offset }.map(\.element)
        let who = senders.prefix(3).joined(separator: ", ")
        return "SUMMARY: \(lines.count) message\(lines.count == 1 ? "" : "s") from \(who).\nPOINTS:\n"
            + ranked.map { "- \($0)" }.joined(separator: "\n") + "\nACTIONS:\n- None"
    }
}

// MARK: - OpenCode CLI path

/// Deprecated: kept for possible return (OpenCode CLI provider, hidden
/// behind `CatchUp.deprecatedProvidersKey`).
/// Pure CLI helpers: argv shape, auth-failure sniffing, JSON output
/// parsing. `opencode run --format json` emits JSON (one object per
/// line for streaming events); the summary is the last assistant
/// text payload we can find (message content or text part).
/// {"type":"error",...} blobs surface via errorMessage(in:).
public enum CatchUpCLI {
    public static let executable = "opencode"
    public static let defaultTimeoutSeconds: Double = 60
    /// Install guide surface (sheet + Settings when the CLI is
    /// missing). Install via `installCommand`, then `loginCommand`.
    public static let installSite = "https://opencode.ai"
    public static let installCommand = "curl -fsSL https://opencode.ai/install | bash"
    public static let loginCommand = "opencode auth login"

    public static func arguments(model: String, prompt: String) -> [String] {
        ["run", "--format", "json", "--model", model, prompt]
    }

    /// True when a nonzero-exit blob looks like expired/missing CLI
    /// auth rather than a generic failure. Only called on failure
    /// output, never on a successful summary.
    public static func isAuthFailure(stderr: String, stdout: String) -> Bool {
        let blob = (stderr + "\n" + stdout).lowercased()
        return blob.contains("unauthorized")
            || blob.contains("unauthenticated")
            || blob.contains("auth")
            || blob.contains("login")
            || blob.contains("expired")
            || blob.contains("invalid key")
            || blob.contains("invalid api key")
            || blob.contains("forbidden")
            || blob.contains(" 401")
            || blob.contains(" 403")
    }

    /// Extract the summary text from `opencode run --format json`
    /// stdout. Accepts a single JSON object or JSON lines; picks the
    /// last non-empty assistant payload. A {"type":"error",...} blob
    /// surfaces as .server with the CLI's own message instead of the
    /// opaque .cliBadOutput. Throws .cliBadOutput when nothing parses
    /// or nothing usable is found.
    public static func parseOutput(_ stdout: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatchUpError.cliBadOutput }
        var candidates: [String] = []
        // Whole-blob first (single JSON object), then line by line
        // (streaming JSONL events).
        var blobs = [trimmed]
        blobs.append(contentsOf: trimmed.components(separatedBy: "\n"))
        for blob in blobs {
            let line = blob.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            if let found = extractText(from: json), !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(found)
            }
        }
        if let last = candidates.last { return last }
        if let message = errorMessage(in: stdout) {
            throw CatchUpError.server("opencode CLI error: \(message)")
        }
        throw CatchUpError.cliBadOutput
    }

    /// First {"type":"error",...} message in a CLI stdout blob, if any.
    /// Shape: {"type":"error","error":{"name":...,"data":{"message":...}}}.
    /// Pure (test seam); also feeds the nonzero-exit detail so a
    /// stdout-only failure keeps the CLI's own words.
    public static func errorMessage(in stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var blobs = [trimmed]
        blobs.append(contentsOf: trimmed.components(separatedBy: "\n"))
        for blob in blobs {
            let line = blob.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "error"
            else { continue }
            if let err = json["error"] as? [String: Any] {
                if let data = err["data"] as? [String: Any],
                   let msg = data["message"] as? String, !msg.isEmpty
                {
                    return msg
                }
                if let msg = err["message"] as? String, !msg.isEmpty { return msg }
                if let name = err["name"] as? String, !name.isEmpty { return name }
            }
            if let msg = json["message"] as? String, !msg.isEmpty { return msg }
            return "unknown CLI error"
        }
        return nil
    }

    private static func extractText(from json: Any) -> String? {
        guard let obj = json as? [String: Any] else { return nil }
        // Streaming event: {"type":"message","role":"assistant","content":...}
        if let type = obj["type"] as? String, type == "message" {
            if let role = obj["role"] as? String, role != "assistant" { return nil }
            return stringOrBlockText(obj["content"])
        }
        // Error events never carry summary text (see errorMessage(in:)).
        if let type = obj["type"] as? String, type == "error" { return nil }
        // Streaming text event: {"type":"text","part":{"type":"text","text":...}}
        // (live `opencode run --format json` shape, probed 2026-09-24).
        if let part = obj["part"] as? [String: Any],
           let s = stringOrBlockText(part["text"]), !s.isEmpty
        {
            return s
        }
        // Direct payload keys.
        for key in ["content", "text", "result", "output", "summary"] {
            if let s = stringOrBlockText(obj[key]), !s.isEmpty { return s }
        }
        // OpenAI-compatible shape.
        if let choices = obj["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let s = stringOrBlockText(message["content"]), !s.isEmpty
        {
            return s
        }
        // Message list: last assistant wins.
        if let messages = obj["messages"] as? [[String: Any]] {
            for message in messages.reversed() {
                let role = message["role"] as? String
                if role == nil || role == "assistant",
                   let s = stringOrBlockText(message["content"]), !s.isEmpty
                {
                    return s
                }
            }
        }
        return nil
    }

    private static func stringOrBlockText(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let blocks = value as? [[String: Any]] {
            let parts = blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return nil
    }
}

/// Captured CLI run: stdout + stderr + exit code.
public struct CatchUpCLIResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Shell-out seam. Live = Process; tests inject
/// `CatchUpMockCLIRunner` and never spawn.
public protocol CatchUpCLIRunner: Sendable {
    /// False when the `opencode` executable cannot be found (drives
    /// the missing-CLI install prompt; the run path still throws
    /// .cliMissing if the binary vanishes between check and run).
    var isAvailable: Bool { get }
    func run(model: String, prompt: String, timeoutSeconds: Double) async throws -> CatchUpCLIResult
}

/// Live runner: resolves `opencode` on PATH (+ brew locations GUI
/// apps miss), runs `opencode run --format json --model <m> <prompt>`
/// with a timeout, captures stdout/stderr.
public struct ProcessCatchUpCLIRunner: CatchUpCLIRunner {
    public init() {}

    public var isAvailable: Bool { Self.resolveExecutable() != nil }

    public func run(model: String, prompt: String, timeoutSeconds: Double) async throws -> CatchUpCLIResult {
        guard let executableURL = Self.resolveExecutable() else {
            throw CatchUpError.cliMissing
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = CatchUpCLI.arguments(model: model, prompt: prompt)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw CatchUpError.cliMissing
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                // Brief grace, then force.
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning { process.interrupt() }
                throw CatchUpError.cliTimeout
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CatchUpCLIResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus)
    }

    static func resolveExecutable() -> URL? {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":").filter { !$0.isEmpty }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(CatchUpCLI.executable)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Mock CLI runner for tests. Records every (model, prompt) call;
/// returns `result` or throws `failure`.
public final class CatchUpMockCLIRunner: CatchUpCLIRunner, @unchecked Sendable {
    public private(set) var calls: [(model: String, prompt: String)] = []
    public var result: CatchUpCLIResult?
    public var failure: Error?
    public var isAvailable: Bool

    public init(result: CatchUpCLIResult? = nil, failure: Error? = nil, isAvailable: Bool = true) {
        self.result = result
        self.failure = failure
        self.isAvailable = isAvailable
    }

    public func run(model: String, prompt: String, timeoutSeconds _: Double) async throws -> CatchUpCLIResult {
        calls.append((model: model, prompt: prompt))
        if let failure { throw failure }
        return result ?? CatchUpCLIResult(stdout: "", stderr: "", exitCode: 0)
    }
}

/// Deprecated: kept for possible return (hidden behind
/// `CatchUp.deprecatedProvidersKey`; on-device is the product).
/// CLI transport: shells out via the injected runner, maps the four
/// CLI modes (missing / auth-expiry / timeout / bad output) to
/// CatchUpError, surfaces everything — never silent.
public struct OpenCodeCLICatchUpTransport: CatchUpTransport {
    public let runner: any CatchUpCLIRunner
    public let timeoutSeconds: Double

    public init(
        runner: (any CatchUpCLIRunner)? = nil,
        timeoutSeconds: Double = CatchUpCLI.defaultTimeoutSeconds
    ) {
        self.runner = runner ?? ProcessCatchUpCLIRunner()
        self.timeoutSeconds = timeoutSeconds
    }

    /// CLI presence check for the install prompt (see
    /// `CatchUpStore.cliAvailable`).
    public var isAvailable: Bool { runner.isAvailable }

    public func complete(baseURL _: String, apiKey _: String, model: String, prompt: String) async throws -> String {
        let res: CatchUpCLIResult
        do {
            res = try await runner.run(model: model, prompt: prompt, timeoutSeconds: timeoutSeconds)
        } catch let e as CatchUpError {
            throw e
        } catch {
            throw CatchUpError.server(String(describing: error))
        }
        if res.exitCode != 0 {
            if CatchUpCLI.isAuthFailure(stderr: res.stderr, stdout: res.stdout) {
                throw CatchUpError.cliAuthExpired
            }
            if res.exitCode == 127
                && (res.stderr + res.stdout).lowercased().contains(CatchUpCLI.executable)
            {
                throw CatchUpError.cliMissing
            }
            // Both streams: failures like a rejected model id land on
            // stdout ({"type":"error",...}) with stderr empty; prefer
            // the parsed CLI message over raw JSON.
            let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let outText = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            var parts: [String] = []
            if !errText.isEmpty { parts.append(errText) }
            if let cliMessage = CatchUpCLI.errorMessage(in: res.stdout), !cliMessage.isEmpty {
                parts.append(cliMessage)
            } else if !outText.isEmpty {
                parts.append(outText)
            }
            let detail = parts.joined(separator: "\n")
            throw CatchUpError.server("opencode CLI failed: \(detail.isEmpty ? "exit \(res.exitCode)" : String(detail.prefix(500)))")
        }
        let text = try CatchUpCLI.parseOutput(res.stdout)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatchUpError.empty
        }
        return text
    }
}

// MARK: - Store

/// Catch-up state for the app. Non-secret config persists in
/// UserDefaults (OFF default); the key lives in the key store (live:
/// macOS keychain) and is only ever in memory on `config`. The key
/// store is read LAZILY (first run with a key-needing provider, or
/// Settings open) — init never touches it, so app launch cannot
/// trigger a SecurityAgent prompt on re-signed builds. The summary
/// state resets per tap.
@MainActor
public final class CatchUpStore: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(String)
        case failed(String)
    }

    enum Keys {
        static let provider = "catchup.provider"
        /// Pre-AICATCH on/off flag: still written (older builds read
        /// it); read only when `mode` is absent (true → on-click).
        static let enabled = "catchup.enabled"
        static let mode = "catchup.mode"
        static let baseURL = "catchup.baseURL"
        static let model = "catchup.model"
        /// Legacy: the pre-keychain lane kept the key here. Read
        /// lazily once for migration (see ensureKeyLoaded), never
        /// written.
        static let legacyKey = "catchup.apiKey"
    }

    @Published public var config: CatchUpConfig {
        didSet { save() }
    }

    @Published public private(set) var state: State = .idle

    /// Conversation the current `state` belongs to (views show idle for
    /// any other chat, so a chat switch never shows a stale summary).
    @Published public private(set) var stateChatID: String?

    /// Streaming text of the summary being written (cumulative), nil
    /// when nothing streams. The previous summary for the same chat
    /// stays in `previousText` while a new one runs (no blank pane).
    @Published public private(set) var partial: String?
    /// Period of `state` (nil = unbounded, the legacy path).
    @Published public private(set) var statePeriod: CatchUpPeriod?
    /// Last text per "chatID|period" (shown while that period refreshes).
    private var periodTexts: [String: String] = [:]
    @Published public private(set) var previousText: String?

    /// True when the hidden deprecated-provider key is set (Settings
    /// shows the legacy picker; a stored legacy provider is honored).
    public let deprecatedProvidersEnabled: Bool

    /// The one Catch Up setting.
    public var mode: CatchUpMode {
        get { config.mode }
        set { config.mode = newValue }
    }

    /// Structured form of the current `.failed` detail (nil unless the
    /// last summarize ended in a known `CatchUpError`). The sheet uses
    /// it to show the CLI install prompt for `.cliMissing`.
    @Published public private(set) var lastError: CatchUpError?

    /// Whether the `opencode` binary resolves on PATH (via the CLI
    /// runner). Non-CLI transports assume true; refresh explicitly
    /// with `refreshCLIStatus()` (e.g. after the user installs it).
    @Published public private(set) var cliAvailable: Bool

    private let transport: any CatchUpTransport
    private let cliTransport: any CatchUpTransport
    private let onDeviceTransport: any CatchUpTransport
    private let defaults: UserDefaults
    private let keys: any CatchUpKeyStore
    /// Memory-only on-device summary cache (cloud/CLI bypass it).
    private var summaryCache = ThreadSummaryCache()
    /// True once the key state is known (lazy load ran, or a key was
    /// set explicitly). Guards save() from wiping the stored key
    /// with a pre-load empty apiKey.
    private var keyLoaded = false
    /// Suppresses the key write for the assignment that adopts a
    /// just-loaded key (no write-back of the identical value).
    private var skipKeyWrite = false

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        transport: (any CatchUpTransport)? = nil,
        cliTransport: (any CatchUpTransport)? = nil,
        onDeviceTransport: (any CatchUpTransport)? = nil,
        defaults: UserDefaults = .standard,
        keyStore: (any CatchUpKeyStore)? = nil
    ) {
        self.transport = transport ?? URLSessionCatchUpTransport()
        let cli = cliTransport ?? OpenCodeCLICatchUpTransport()
        self.cliTransport = cli
        self.onDeviceTransport = onDeviceTransport ?? OnDeviceCatchUpTransport()
        self.defaults = defaults
        let keys = keyStore ?? CatchUpSystemKeychain()
        self.keys = keys
        var cfg = CatchUpConfig()
        let legacy = defaults.bool(forKey: CatchUp.deprecatedProvidersKey)
        deprecatedProvidersEnabled = legacy
        // Deprecated providers load only behind the hidden key; without
        // it every install runs on-device (no URL/model/key in play).
        if legacy {
            if let p = defaults.string(forKey: Keys.provider),
               let provider = CatchUpProvider.stored(rawValue: p)
            {
                cfg.provider = provider
            }
            if let b = defaults.string(forKey: Keys.baseURL), !b.isEmpty { cfg.baseURL = b }
            if let m = defaults.string(forKey: Keys.model), !m.isEmpty { cfg.model = m }
        }
        if let raw = defaults.string(forKey: Keys.mode), let mode = CatchUpMode(rawValue: raw) {
            cfg.mode = mode
        } else if defaults.bool(forKey: Keys.enabled) {
            cfg.mode = .onClick
        }
        // No key-store touch here: the key loads lazily via
        // ensureKeyLoaded (first key-needing run, or Settings open).
        _config = Published(initialValue: cfg)
        _state = Published(initialValue: .idle)
        _lastError = Published(initialValue: nil)
        _cliAvailable = Published(initialValue: (cli as? OpenCodeCLICatchUpTransport)?.isAvailable ?? true)
    }

    /// Summarize the given messages. Disabled/empty-thread always fail
    /// WITHOUT touching any transport. Provider select is exclusive:
    /// the CLI provider (default) ALWAYS shells out and never
    /// attempts HTTPS, even with a key configured; direct providers
    /// ALWAYS use HTTPS and require a key, failing with missingKey
    /// WITHOUT touching the transport; the on-device provider uses
    /// the local model only (no key, no URL, no CLI) and consults the
    /// per-thread cache first. Every failure lands in `.failed` with
    /// a Retry path — never stuck in `.loading`.
    /// `period` + `filter` (CATCHTABS, the inspector): input is bounded
    /// to the period, noise-filtered and salience-ranked, and the result
    /// gets the deterministic bullet pass; each (conversation, period) keeps its
    /// last text, which stays on screen while that period refreshes.
    public func summarize(messages rawMessages: [ChatMessage], chatID: String? = nil,
                          period: CatchUpPeriod? = nil, filter: CatchUpFilterContext? = nil) async {
        let periodKey = period.map { "\(chatID ?? "")|\($0.rawValue)" }
        if let periodKey {
            previousText = periodTexts[periodKey]
        } else if stateChatID != chatID {
            previousText = nil
        } else if case let .loaded(text) = state {
            previousText = text
        }
        stateChatID = chatID
        statePeriod = period
        // A newer run supersedes any in flight (tab or chat switch).
        generation += 1
        let gen = generation
        partial = nil
        defer { partial = nil }
        guard config.enabled else {
            lastError = .off
            state = .failed(CatchUpError.off.message)
            return
        }
        // Lazy key read: only a key-needing (direct HTTPS) provider
        // touches the key store; the CLI and on-device providers
        // never do.
        if CatchUp.usesAPIKey(provider: config.provider) {
            ensureKeyLoaded()
        }
        let hasKey = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if CatchUp.usesAPIKey(provider: config.provider), !hasKey {
            lastError = .missingKey
            state = .failed(CatchUpError.missingKey.message)
            return
        }
        var messages = rawMessages
        var cacheChatID = chatID
        if let period, let filter {
            guard !CatchUpBound.messages(rawMessages, period: period, now: filter.now).isEmpty else {
                lastError = nil
                state = .loaded("SUMMARY: No messages in the last \(period.title.lowercased()).")
                return
            }
            messages = CatchUpPipeline.prepare(rawMessages, period: period, filter)
            guard !messages.isEmpty else {
                lastError = nil
                state = .loaded("SUMMARY: Nothing in the last \(period.title.lowercased()) needs your attention.")
                if let periodKey { periodTexts[periodKey] = nil }
                return
            }
            cacheChatID = "\(chatID ?? "")|\(period.rawValue)|\(filter.feedback.dismissals.count)"
        }
        let transcript = CatchUp.transcript(from: messages)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = nil
            state = .failed("Nothing to summarize.")
            return
        }
        // On-device cache: an unchanged thread replays without a new
        // model session. Cloud/CLI providers always run fresh.
        if config.provider == .onDevice,
           let hit = summaryCache.lookup(chatID: cacheChatID, messages: messages)
        {
            lastError = nil
            state = .loaded(hit)
            if let periodKey { periodTexts[periodKey] = hit }
            return
        }
        state = .loading
        do {
            // Exclusive routing: CLI-selected => CLI ONLY, on-device
            // => local model ONLY (never HTTP, never a cloud fallback).
            let text: String
            if config.provider == .onDevice {
                // 4096-token window: chunked map-reduce, streamed.
                let engine = OnDeviceCatchUpEngine(transport: onDeviceTransport)
                let raw = try await engine.summarize(messages: messages) { [weak self] snapshot in
                    Task { @MainActor [weak self] in self?.applyPartial(snapshot, gen: gen) }
                }
                if let filter {
                    text = CatchUpPipeline.refine(raw, filter)
                } else {
                    text = raw
                }
            } else {
                let active: any CatchUpTransport = config.provider == .openCodeCLI ? cliTransport : transport
                text = try await active.complete(
                    baseURL: config.baseURL, apiKey: config.apiKey,
                    model: config.model, prompt: CatchUp.prompt(transcript: transcript))
            }
            guard gen == generation else {
                // Superseded: keep the text for its period, show nothing.
                if let periodKey, !text.isEmpty { periodTexts[periodKey] = text }
                return
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastError = .empty
                state = .failed(CatchUpError.empty.message)
            } else {
                if config.provider == .onDevice {
                    summaryCache.store(chatID: cacheChatID, messages: messages, text: text)
                }
                lastError = nil
                state = .loaded(text)
                if let periodKey { periodTexts[periodKey] = text }
            }
        } catch let e as CatchUpError {
            guard gen == generation else { return }
            lastError = e
            state = .failed(e.message)
        } catch {
            guard gen == generation else { return }
            lastError = nil
            state = .failed(String(describing: error))
        }
    }

    /// Back to idle (sheet reopen, chat switch).
    public func reset() {
        state = .idle
        lastError = nil
        stateChatID = nil
        statePeriod = nil
        partial = nil
        previousText = nil
    }

    private var generation = 0

    /// Streamed snapshot → `partial`, only for the run still in flight
    /// and never shorter than what is shown (hops can reorder).
    private func applyPartial(_ text: String, gen: Int) {
        guard gen == generation, state == .loading else { return }
        if let p = partial, text.count < p.count { return }
        partial = text
    }

    /// Re-check whether the `opencode` binary resolves (Settings
    /// "Check again" after the user installs it).
    public func refreshCLIStatus() {
        cliAvailable = (cliTransport as? OpenCodeCLICatchUpTransport)?.isAvailable ?? true
    }

    /// Test/demo seam: adopt a config without touching persistence.
    public func adopt(_ cfg: CatchUpConfig) {
        config = cfg
    }

    /// Provider switch from the Settings picker: preloads the
    /// provider's base URL + model, keeps the key + enabled flag.
    public func selectProvider(_ provider: CatchUpProvider) {
        config = config.withProvider(provider)
    }

    /// Lazy key load: reads the key store at most once per store —
    /// on the first run with a key-needing provider (via
    /// summarize) or when Settings opens — never at init/launch.
    /// A no-op when a key is already set. Includes the one-time
    /// legacy-defaults migration (persist via save, scrubbed).
    public func ensureKeyLoaded() {
        guard !keyLoaded else { return }
        keyLoaded = true
        guard config.apiKey.isEmpty else { return }
        if let k = keys.load(), !k.isEmpty {
            skipKeyWrite = true
            config.apiKey = k
            skipKeyWrite = false
        } else if let legacy = defaults.string(forKey: Keys.legacyKey), !legacy.isEmpty {
            config.apiKey = legacy
            defaults.removeObject(forKey: Keys.legacyKey)
        }
    }

    private func save() {
        defaults.set(config.provider.rawValue, forKey: Keys.provider)
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.mode.rawValue, forKey: Keys.mode)
        defaults.set(config.baseURL, forKey: Keys.baseURL)
        defaults.set(config.model, forKey: Keys.model)
        // Key → key store only. Never UserDefaults (see the legacy
        // migration in ensureKeyLoaded for the one pre-keychain
        // exception we scrub). A pre-load empty apiKey means "not
        // loaded", not "no key" — writing it would wipe the stored
        // key, so the write waits until the key state is known. An
        // explicitly set (non-empty) key always persists, and marks
        // the state known so a later clear propagates.
        if !config.apiKey.isEmpty { keyLoaded = true }
        if !skipKeyWrite, keyLoaded {
            keys.save(config.apiKey)
        }
    }
}

