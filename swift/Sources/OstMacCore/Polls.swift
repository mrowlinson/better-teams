// Polls.swift — polls lane: poll create + vote + results.
//
// Teams posts polls as Forms-backed Adaptive Cards (composeExtension /
// Input.ChoiceSet + Action.Submit on the wire). The chat-service send
// path in this client is text-only (`send_message_body`), so create
// posts a stable text fallback the parser reads back, plus a card-JSON
// builder for the future attachment post. Votes are device-local until
// a server invoke endpoint lands (LIVE-PENDING): the registry + tally
// below are the contract the server vote will feed.
//
// Wire shapes (real, from AdaptiveCard/CardActions mining):
//   - our fallback text: first line "📊 <question>", then "1. <opt>" rows
//   - Forms cards: Input.ChoiceSet with choices[] + Action.Submit
import Combine
import Foundation

/// One poll option. Ids are stable within the poll (`o1`, `o2`, …).
public struct PollOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// A poll: question + 2...6 options. `allowMultiple` lets one voter
/// pick several options; `closed` freezes voting.
public struct Poll: Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let options: [PollOption]
    public let allowMultiple: Bool
    public var closed: Bool

    public init(
        id: String = UUID().uuidString,
        question: String,
        options: [PollOption],
        allowMultiple: Bool = false,
        closed: Bool = false
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.allowMultiple = allowMultiple
        self.closed = closed
    }

    public func option(id: String) -> PollOption? {
        options.first { $0.id == id }
    }
}

/// Validation failures for poll create (guards live on these strings).
public enum PollValidation: Sendable, Equatable {
    /// Question blank, or an option blank.
    public static let emptyQuestion = "Ask a question first."
    public static let emptyOption = "Options can't be blank."
    /// Shape limits.
    public static let tooFewOptions = "Add at least 2 options."
    public static let tooManyOptions = "Keep it to 6 options or fewer."
    public static let questionTooLong = "Keep the question under 256 characters."
    public static let optionTooLong = "Keep each option under 128 characters."
    public static let duplicateOption = "Make each option different."

    public static let maxOptions = 6
    public static let maxQuestionChars = 256
    public static let maxOptionChars = 128

    /// First failure, nil when the draft is postable. Trims whitespace
    /// before every check so "  " counts as blank.
    public static func validate(question: String, options: [String]) -> String? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return emptyQuestion }
        if q.count > maxQuestionChars { return questionTooLong }
        let texts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if texts.count < 2 || texts.filter({ !$0.isEmpty }).count < 2 { return tooFewOptions }
        if texts.count > maxOptions { return tooManyOptions }
        for t in texts {
            if t.isEmpty { return emptyOption }
            if t.count > maxOptionChars { return optionTooLong }
        }
        let lowered = texts.map { $0.lowercased() }
        if Set(lowered).count != lowered.count { return duplicateOption }
        return nil
    }

    /// Build a postable poll from a validated draft (ids `o1…`).
    public static func make(question: String, options: [String], allowMultiple: Bool = false) -> Poll {
        let texts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let opts = texts.enumerated().map { PollOption(id: "o\($0.offset + 1)", text: $0.element) }
        return Poll(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            options: opts, allowMultiple: allowMultiple)
    }
}

/// Vote failures (vote guards live on these strings).
public enum PollVoteError: String, Sendable, Equatable, Error {
    case unknownPoll = "That poll is gone."
    case unknownOption = "That option isn't in this poll."
    case closed = "This poll is closed."
    case multiNotAllowed = "This poll takes one choice — change it instead."
}

/// One voter's ballot plus the tally math.
public enum PollTally {
    /// Counts per option id from all ballots.
    public static func count(options: [PollOption], ballots: [[String]]) -> [(option: PollOption, votes: Int)] {
        options.map { opt in
            (option: opt, votes: ballots.filter { $0.contains(opt.id) }.count)
        }
    }

    /// Share of total ballots per option (0 when nobody voted).
    public static func percent(votes: Int, totalBallots: Int) -> Double {
        guard totalBallots > 0 else { return 0 }
        return Double(votes) / Double(totalBallots)
    }
}

/// Device-local votes until the server invoke lands. Keyed by message
/// id (one poll per message); each ballot is one voter's option ids.
/// Single-vote polls replace the ballot on re-vote (change, not add).
@MainActor
public final class PollVoteStore: ObservableObject {
    /// messageID -> voterKey -> option ids.
    private var ballots: [String: [String: Set<String>]] = [:]
    /// messageID -> closed.
    private var closed: [String: Bool] = [:]
    /// This device's voter key (one ballot per poll per device).
    public var voterKey = "me"

    public init() {}

    public func register(poll: Poll, messageID: String) {
        closed[messageID] = poll.closed
        if ballots[messageID] == nil { ballots[messageID] = [:] }
    }

    public func close(messageID: String) { closed[messageID] = true }
    public func reopen(messageID: String) { closed[messageID] = false }
    public func isClosed(messageID: String) -> Bool { closed[messageID] ?? false }

    /// Cast (or change) this device's vote. Throws on closed / unknown
    /// option / second option in a single-choice poll.
    public func vote(messageID: String, poll: Poll, optionIDs: Set<String>) throws {
        if closed[messageID] ?? poll.closed { throw PollVoteError.closed }
        guard !optionIDs.isEmpty else {
            ballots[messageID]?[voterKey] = []
            return
        }
        for id in optionIDs {
            guard poll.option(id: id) != nil else { throw PollVoteError.unknownOption }
        }
        if !poll.allowMultiple, optionIDs.count > 1 { throw PollVoteError.multiNotAllowed }
        if ballots[messageID] == nil { ballots[messageID] = [:] }
        ballots[messageID]?[voterKey] = optionIDs
    }

    public func myVote(messageID: String) -> Set<String> {
        ballots[messageID]?[voterKey] ?? []
    }

    public func allBallots(messageID: String) -> [[String]] {
        guard let byVoter = ballots[messageID] else { return [] }
        return byVoter.values.map { Array($0) }.filter { !$0.isEmpty }
    }

    /// Distinct voters with a non-empty ballot.
    public func ballotCount(messageID: String) -> Int {
        allBallots(messageID: messageID).count
    }

    public func tally(messageID: String, poll: Poll) -> [(option: PollOption, votes: Int)] {
        PollTally.count(options: poll.options, ballots: allBallots(messageID: messageID))
    }
}

/// Process-wide poll registry: message id -> poll + its local votes.
/// The timeline reads through here; create registers, vote mutates.
@MainActor
public enum PollRegistry {
    private static var polls: [String: Poll] = [:]
    private static var store = PollVoteStore()

    public static func resetForTests() {
        polls.removeAll()
        store = PollVoteStore()
    }

    public static func register(_ poll: Poll, messageID: String) {
        polls[messageID] = poll
        store.register(poll: poll, messageID: messageID)
    }

    public static func poll(messageID: String) -> Poll? { polls[messageID] }

    /// Resolve the poll for a bubble: registry first (created or voted
    /// here), else parsed back from the message payload and registered
    /// (own fallback text, our card marker, or a Forms ChoiceSet card).
    public static func resolve(messageID: String, content: String, raw: String?) -> Poll? {
        if let known = polls[messageID] { return known }
        guard let parsed = PollInfo.extract(messageID: messageID, content: content, raw: raw)
        else { return nil }
        register(parsed, messageID: messageID)
        return parsed
    }

    public static func vote(messageID: String, optionIDs: Set<String>) throws {
        guard let poll = polls[messageID] else { throw PollVoteError.unknownPoll }
        try store.vote(messageID: messageID, poll: poll, optionIDs: optionIDs)
    }

    public static func myVote(messageID: String) -> Set<String> {
        store.myVote(messageID: messageID)
    }

    public static func tally(messageID: String) -> [(option: PollOption, votes: Int)]? {
        guard let poll = polls[messageID] else { return nil }
        return store.tally(messageID: messageID, poll: poll)
    }

    /// Distinct voters with a non-empty ballot (exact total).
    public static func ballotCount(messageID: String) -> Int {
        store.ballotCount(messageID: messageID)
    }

    public static func close(messageID: String) {
        store.close(messageID: messageID)
        if var p = polls[messageID] {
            p.closed = true
            polls[messageID] = p
        }
    }
}

/// Card payload builders: text fallback (posted today) + Adaptive
/// Card JSON (posted once the attachment path exists).
public enum PollPayload {
    /// Stable text fallback. First line carries the question so the
    /// parser reads the poll back from any bubble.
    public static func fallbackText(poll: Poll) -> String {
        var lines = ["📊 \(poll.question)"]
        for (i, opt) in poll.options.enumerated() {
            lines.append("\(i + 1). \(opt.text)")
        }
        lines.append(poll.allowMultiple ? "Pick as many as you like." : "Pick one.")
        return lines.joined(separator: "\n")
    }

    /// Adaptive Card JSON for the poll (question + per-option Submit).
    /// Carries a `btPoll` marker so the parser claims our cards.
    public static func cardJSON(poll: Poll) -> String {
        let actions = poll.options.map { opt in
            "{\"type\":\"Action.Submit\",\"title\":\(jsonString(opt.text)),"
                + "\"data\":{\"btPoll\":\(jsonString(poll.id)),\"option\":\(jsonString(opt.id))}}"
        }.joined(separator: ",")
        return "{\"type\":\"AdaptiveCard\",\"version\":\"1.4\","
            + "\"body\":[{\"type\":\"TextBlock\",\"text\":\(jsonString(poll.question)),"
            + "\"size\":\"Medium\",\"weight\":\"Bolder\",\"wrap\":true}],"
            + "\"actions\":[\(actions)]}"
    }

    private static func jsonString(_ s: String) -> String {
        let esc = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(esc)\""
    }
}

/// Read polls back from message payloads: our fallback text, our card
/// marker, and best-effort Forms shapes (question TextBlock +
/// Input.ChoiceSet choices). Nil when the message holds no poll.
public enum PollInfo {
    public static func extract(messageID: String, content: String, raw: String?) -> Poll? {
        if let fromRaw = extractFromRaw(raw, messageID: messageID) { return fromRaw }
        return extractFromText(content, messageID: messageID)
    }

    /// True when content is our fallback text (the bubble renders the
    /// card instead of the raw lines).
    public static func isFallbackText(_ content: String) -> Bool {
        extractFromText(content, messageID: "") != nil
    }

    /// Our fallback text: "📊 question" + "N. option" rows.
    static func extractFromText(_ content: String, messageID: String) -> Poll? {
        let lines = content.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.count >= 3,
              let first = lines.first, first.hasPrefix("📊 ")
        else { return nil }
        let question = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return nil }
        var options: [PollOption] = []
        var idx = 0
        for line in lines.dropFirst() {
            guard let dot = line.firstIndex(of: ".") else { break }
            let num = line[..<dot].trimmingCharacters(in: .whitespaces)
            guard Int(num) == idx + 1 else { break }
            let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { break }
            idx += 1
            options.append(PollOption(id: "o\(idx)", text: text))
        }
        guard options.count >= 2 else { return nil }
        let multi = lines.last == "Pick as many as you like."
        return Poll(id: messageID, question: question, options: options, allowMultiple: multi)
    }

    /// Card JSON: our `btPoll` marker or a Forms ChoiceSet shape.
    static func extractFromRaw(_ raw: String?, messageID: String) -> Poll? {
        guard let raw,
              MessageRender.looksLikeJSONObject(raw),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return formsPoll(from: json, messageID: messageID)
    }

    /// Forms shape: any Input.ChoiceSet choices[] + a question TextBlock.
    /// Our own cardJSON matches too: per-option Action.Submit titles
    /// read back as choices, with the poll id from data.btPoll.
    static func formsPoll(from json: Any, messageID: String) -> Poll? {
        var questions: [String] = []
        var choices: [[String]] = []
        var markedIDs: [String] = []
        var submits: [(title: String, option: String?)] = []
        scan(
            json, depth: 8, questions: &questions, choices: &choices,
            markedIDs: &markedIDs, submits: &submits)
        if choices.isEmpty {
            let titles = submits.map { $0.title }.filter { !$0.isEmpty }
            if titles.count >= 2 { choices.append(titles) }
        }
        guard let question = questions.first, !question.isEmpty,
              let first = choices.first, first.count >= 2
        else { return nil }
        let opts = first.prefix(PollValidation.maxOptions).enumerated().map {
            PollOption(id: "o\($0.offset + 1)", text: $0.element)
        }
        return Poll(id: markedIDs.first ?? messageID, question: question, options: Array(opts))
    }

    private static func scan(
        _ value: Any, depth: Int,
        questions: inout [String], choices: inout [[String]], markedIDs: inout [String],
        submits: inout [(title: String, option: String?)]
    ) {
        guard depth > 0 else { return }
        if let dict = value as? [String: Any] {
            let type = (dict["type"] as? String) ?? ""
            if type == "Input.ChoiceSet",
               let rawChoices = dict["choices"] as? [[String: Any]]
            {
                let titles = rawChoices.compactMap { $0["title"] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if titles.count >= 2 { choices.append(titles) }
            }
            if type == "Action.Submit",
               let title = dict["title"] as? String
            {
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    let opt = (dict["data"] as? [String: Any])?["option"] as? String
                    submits.append((title: t, option: opt))
                }
            }
            if type == "TextBlock",
               let text = dict["text"] as? String
            {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("📊") { questions.append(t) }
            }
            if let data = dict["data"] as? [String: Any],
               let id = data["btPoll"] as? String, !id.isEmpty
            {
                markedIDs.append(id)
            }
            for child in dict.values {
                scan(
                    child, depth: depth - 1, questions: &questions, choices: &choices,
                    markedIDs: &markedIDs, submits: &submits)
            }
        } else if let array = value as? [Any] {
            for child in array {
                scan(
                    child, depth: depth - 1, questions: &questions, choices: &choices,
                    markedIDs: &markedIDs, submits: &submits)
            }
        }
    }
}

// MARK: - Create (ConversationStore)

public extension ConversationStore {
    /// Post a poll: validates the draft, sends the text fallback through
    /// the existing send path, and registers the poll on the optimistic
    /// bubble (same tick on this actor, so `messages.last` is ours).
    /// Returns the posted poll, or nil when the draft is invalid.
    @discardableResult
    func sendPoll(question: String, options: [String], allowMultiple: Bool = false) -> Poll? {
        guard PollValidation.validate(question: question, options: options) == nil else { return nil }
        let poll = PollValidation.make(question: question, options: options, allowMultiple: allowMultiple)
        let before = messages.last?.id
        send(text: PollPayload.fallbackText(poll: poll))
        let bubbleID: String? = {
            guard let last = messages.last, last.id != before else { return nil }
            return last.id
        }()
        if let bubbleID {
            PollRegistry.register(poll, messageID: bubbleID)
        } else {
            PollRegistry.register(poll, messageID: poll.id)
        }
        return poll
    }
}
