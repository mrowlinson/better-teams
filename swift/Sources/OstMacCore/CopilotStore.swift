// CopilotStore.swift — COPILOT-BUILD: the Copilot chat store.
//
// One live conversation: `send` starts a core turn and polls it
// (~6/s) until done, replacing the streaming bubble's text per poll
// (the hub stream is cumulative). Licence gates disable the input
// with the reason; suggestions send as new prompts. Tests inject a
// stub transport; demo seeds canned states (CopilotDemo).
import Combine
import Foundation

public enum CopilotRole: String, Sendable {
    case user, assistant
}

public struct CopilotAttribution: Sendable, Hashable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct CopilotMessage: Identifiable, Sendable {
    public let id: String
    public let role: CopilotRole
    public var text: String
    public var attributions: [CopilotAttribution]
    public var suggestions: [String]
    public var isStreaming: Bool

    public init(id: String = UUID().uuidString, role: CopilotRole, text: String,
                attributions: [CopilotAttribution] = [], suggestions: [String] = [],
                isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.attributions = attributions
        self.suggestions = suggestions
        self.isStreaming = isStreaming
    }
}

/// Chat input state. `.disabled` always carries the honest reason.
public enum CopilotChatState: Equatable, Sendable {
    /// No messages yet; input live.
    case idle
    /// Messages present; input live.
    case ready
    /// A turn is streaming; sends wait (Stop first, then send).
    case streaming
    /// Last send failed; input live (retry by sending again).
    case error(String)
    /// Input disabled with the reason (auth / licence / transport).
    case disabled(String)
}

/// Licence state (Taiger; refreshed on show + on demand).
public enum CopilotLicenseState: Equatable, Sendable {
    case unknown
    case checking
    /// Licensed; status is the raw Taiger status (only
    /// COPILOT_LICENSE grounds in work data — every other tier is
    /// web-grounded), note the informational PAYG/promo line, if any.
    case licensed(status: String, note: String?)
    case unlicensed(reason: String)

    /// Work-grounded tiers (the paid seat only).
    public var workGrounded: Bool {
        if case .licensed(let status, _) = self { return status == "COPILOT_LICENSE" }
        return false
    }
}

@MainActor
public final class CopilotStore: ObservableObject {
    /// Latest messages (only meaningful outside `.idle`).
    @Published public private(set) var messages: [CopilotMessage] = []
    /// Current chat state. Starts `.idle`.
    @Published public private(set) var state: CopilotChatState = .idle
    /// Current licence state. Starts `.unknown`.
    @Published public private(set) var license: CopilotLicenseState = .unknown
    /// Transient hub progress ("Taking a look…") while streaming.
    @Published public private(set) var progress: String? = nil

    /// Input is live in `.idle`/`.ready`/`.error` (held while a
    /// turn streams; disabled with the reason in `.disabled`).
    public var inputEnabled: Bool {
        switch state {
        case .idle, .ready, .error: true
        case .streaming, .disabled: false
        }
    }

    /// A turn is in flight (Stop is real only then).
    public var streaming: Bool {
        if case .streaming = state { return true }
        return false
    }

    private let transport: CopilotTransport
    private var pollTask: Task<Void, Never>?
    private var licenseTask: Task<Void, Never>?
    private var conversationID: String? = nil
    /// Demo-only: `adoptDemo` pins the seeded state so the show-time
    /// licence refresh (or an in-flight one) can't clobber a capture;
    /// any user gesture unpins. Live never pins.
    private var demoPinned = false

    public init(transport: CopilotTransport) {
        self.transport = transport
    }

    public static func live() -> CopilotStore {
        CopilotStore(transport: CoreCopilotTransport())
    }

    // MARK: - licence

    /// Refresh the Taiger licence; gates the input on the result.
    /// Safe to call on every show (in flight = no-op; a pinned demo
    /// seed holds until a user gesture).
    public func refreshLicense() {
        guard licenseTask == nil, !demoPinned else { return }
        if case .unknown = license { license = .checking }
        licenseTask = Task { [weak self] in
            guard let self else { return }
            let payload: CopilotLicensePayload?
            do {
                let t = self.transport
                payload = try await Task.blocking(priority: .userInitiated) { try t.license() }.value
            } catch let f as CopilotFailure {
                payload = nil
                await MainActor.run { [weak self] in
                    self?.applyLicenseFailure(f)
                }
            } catch {
                payload = nil
                await MainActor.run { [weak self] in
                    self?.applyLicenseFailure(CopilotFailure(.server, "\(error)"))
                }
            }
            if let p = payload {
                await MainActor.run { [weak self] in
                    self?.applyLicense(p)
                }
            }
            await MainActor.run { [weak self] in self?.licenseTask = nil }
        }
    }

    /// "Check Again": the user asked, so unpin and refresh.
    public func recheckLicense() {
        demoPinned = false
        refreshLicense()
    }

    private func applyLicense(_ p: CopilotLicensePayload) {
        guard !demoPinned else { return }
        if p.licensed {
            license = .licensed(status: p.status, note: p.reason)
            // A licence recovery re-arms a licence-disabled input.
            if case .disabled = state { state = messages.isEmpty ? .idle : .ready }
        } else {
            let reason = p.reason ?? p.error ?? "Copilot isn't licensed for this account yet."
            license = .unlicensed(reason: reason)
            state = .disabled(reason)
        }
    }

    private func applyLicenseFailure(_ f: CopilotFailure) {
        guard !demoPinned else { return }
        let reason: String
        switch f.kind {
        case .auth: reason = "Sign in to use Copilot."
        case .license, .server: reason = f.message
        }
        license = .unlicensed(reason: reason)
        state = .disabled(reason)
    }

    // MARK: - chat

    /// Send one prompt (no-op when disabled or blank).
    public func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, inputEnabled, pollTask == nil else { return }
        demoPinned = false
        stopStreaming()
        messages.append(CopilotMessage(role: .user, text: text))
        let bubble = CopilotMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(bubble)
        let bubbleID = bubble.id
        state = .streaming
        progress = nil
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(prompt: text, bubbleID: bubbleID)
            await MainActor.run { [weak self] in self?.pollTask = nil }
        }
    }

    /// Cancel the in-flight turn (Stop button; no-op when idle).
    public func stop() {
        stopStreaming()
        if case .streaming = state {
            // Keep the partial bubble, marked finished.
            if let i = messages.lastIndex(where: { $0.isStreaming }) {
                messages[i].isStreaming = false
            }
            state = .ready
            progress = nil
        }
    }

    /// Clear the conversation (the next turn starts a new one).
    public func newChat() {
        demoPinned = false
        stopStreaming()
        messages = []
        conversationID = nil
        progress = nil
        if case .disabled = state { return }
        state = .idle
    }

    private func stopStreaming() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func runTurn(prompt: String, bubbleID: String) async {
        let transport = transport
        let turnID: String
        do {
            let conv = conversationID
            turnID = try await Task.blocking(priority: .userInitiated) {
                try transport.start(prompt: prompt, conversationID: conv)
            }.value
        } catch let f as CopilotFailure {
            finishFailed(f.message, bubbleID: bubbleID)
            return
        } catch {
            finishFailed("\(error)", bubbleID: bubbleID)
            return
        }
        // Poll until the core reports done (cumulative text replaces).
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { break }
            let poll: CopilotPollPayload
            do {
                poll = try await Task.blocking(priority: .userInitiated) { try transport.poll(turnID: turnID) }.value
            } catch {
                continue // transient poll miss; the turn continues core-side
            }
            replaceText(bubbleID: bubbleID, text: poll.text)
            if let p = poll.progress { progress = p }
            if poll.done {
                finishTurn(poll, bubbleID: bubbleID, turnID: turnID)
                return
            }
        }
        // Cancelled: tell the core to drop the turn (best-effort).
        let stopID = turnID
        Task.blocking(priority: .utility) { try? transport.stop(turnID: stopID) }
    }

    private func replaceText(bubbleID: String, text: String) {
        guard let i = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        messages[i].text = text
    }

    private func finishTurn(_ poll: CopilotPollPayload, bubbleID: String, turnID: String) {
        if let e = poll.error, poll.answer == nil {
            finishFailed(e, bubbleID: bubbleID)
            return
        }
        if let i = messages.firstIndex(where: { $0.id == bubbleID }) {
            messages[i].isStreaming = false
            if let a = poll.answer {
                messages[i].text = a.text
                messages[i].attributions = (a.attributions ?? []).map {
                    CopilotAttribution(title: $0.title, url: $0.url)
                }
                messages[i].suggestions = a.suggestions ?? []
                if let c = a.conversationID { conversationID = c }
            }
        }
        progress = nil
        state = .ready
    }

    private func finishFailed(_ message: String, bubbleID: String) {
        // Drop the empty streaming bubble; the error state explains.
        messages.removeAll { $0.id == bubbleID && $0.text.isEmpty }
        if let i = messages.firstIndex(where: { $0.id == bubbleID }) {
            messages[i].isStreaming = false
        }
        progress = nil
        state = .error(message)
    }

    // MARK: - demo

    /// Demo-only: adopt a canned state for captures (never live).
    public func adoptDemo(messages: [CopilotMessage], state: CopilotChatState,
                          license: CopilotLicenseState, progress: String? = nil) {
        stopStreaming()
        demoPinned = true
        self.messages = messages
        self.state = state
        self.license = license
        self.progress = progress
    }
}
