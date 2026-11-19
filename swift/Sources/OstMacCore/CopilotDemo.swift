// CopilotDemo.swift — COPILOT-BUILD demo: canned Copilot states.
//
// Offline fixtures for captures + tests. Western demo names only
// (lane rules). No network, ever.
import Foundation

/// Canned Copilot conversation states (captures pick one).
public enum CopilotDemoState: String, Sendable {
    /// Fresh chat: empty, input live, licensed.
    case empty
    /// Mid-turn: user prompt + streaming partial answer + progress.
    case streaming
    /// Finished turn: answer + attributions + suggestion chips.
    case finished
    /// Licence gate: input disabled with the UNLICENSED reason.
    case unlicensed
}

public enum CopilotDemo {
    public static let prompt = "What are the company guidelines for team events?"

    public static let answer = """
        **From your company**
        Company guidelines for team events are written policies that outline \
        the practices and procedures of the business. They set expectations \
        for behavior, keep events consistent, and help with compliance.

        **From the web**
        Generally, company guidelines refer to written policies that outline \
        the practices and procedures of a business.
        """

    public static let partialAnswer = """
        **From your company**
        Company guidelines for team events are written policies that outline \
        the practices and procedures of the bus
        """

    public static let attributions = [
        CopilotAttribution(title: "Team event policy", url: "https://example.invalid/policy"),
        CopilotAttribution(title: "The 5 company policies you need to have in writing",
                           url: "https://example.invalid/policies"),
    ]

    public static let suggestions = [
        "Can you find the email from Kris Smith?",
        "What are the key points in the company guidelines?",
    ]

    public static let progress = "Taking a look…"
    public static let unlicensedReason = "Copilot isn't licensed for this account yet."

    /// Canned content for one capture state.
    public static func seed(_ state: CopilotDemoState)
        -> (messages: [CopilotMessage], chat: CopilotChatState, license: CopilotLicenseState, progress: String?)
    {
        switch state {
        case .empty:
            return ([], .idle, .licensed(status: "COPILOT_LICENSE", note: nil), nil)
        case .streaming:
            return ([
                CopilotMessage(role: .user, text: prompt),
                CopilotMessage(role: .assistant, text: partialAnswer, isStreaming: true),
            ], .streaming, .licensed(status: "COPILOT_LICENSE", note: nil), progress)
        case .finished:
            return ([
                CopilotMessage(role: .user, text: prompt),
                CopilotMessage(role: .assistant, text: answer,
                               attributions: attributions, suggestions: suggestions),
            ], .ready, .licensed(status: "COPILOT_LICENSE", note: nil), nil)
        case .unlicensed:
            return ([], .disabled(unlicensedReason), .unlicensed(reason: unlicensedReason), nil)
        }
    }

    /// Demo store (empty chat; captures reseed via `adoptDemo`).
    @MainActor
    public static func store() -> CopilotStore {
        let s = CopilotStore(transport: DemoCopilotTransport())
        let seed = seed(.empty)
        s.adoptDemo(messages: seed.messages, state: seed.chat, license: seed.license)
        return s
    }
}

/// Demo transport: canned licence + one scripted turn (never core).
public struct DemoCopilotTransport: CopilotTransport {
    public init() {}

    public func license() throws -> CopilotLicensePayload {
        CopilotLicensePayload(status: "COPILOT_LICENSE", licensed: true, reason: nil, error: nil)
    }

    public func start(prompt: String, conversationID: String?) throws -> String {
        "demo-turn"
    }

    public func poll(turnID: String) throws -> CopilotPollPayload {
        CopilotPollPayload(
            turnID: turnID, text: CopilotDemo.answer, done: true, progress: nil,
            answer: CopilotAnswerPayload(
                text: CopilotDemo.answer,
                attributions: CopilotDemo.attributions.map {
                    CopilotAttributionPayload(title: $0.title, url: $0.url)
                },
                suggestions: CopilotDemo.suggestions,
                conversationID: "demo-conversation", chatName: "Company guidelines"),
            error: nil)
    }

    public func stop(turnID: String) throws {}
}
