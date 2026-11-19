// PollTests.swift — polls lane: create validation, payload
// round-trips, vote guards, and results math.
import XCTest

@testable import OstMacCore

@MainActor
final class PollTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PollRegistry.resetForTests()
    }

    // MARK: - Validation

    func testBlankQuestionRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: "   ", options: ["A", "B"]),
            PollValidation.emptyQuestion)
    }

    func testOneOptionRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: "Lunch?", options: ["Pizza"]),
            PollValidation.tooFewOptions)
    }

    func testBlankOptionRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: "Lunch?", options: ["Pizza", "  "]),
            PollValidation.tooFewOptions)
    }

    func testSevenOptionsRejected() {
        XCTAssertEqual(
            PollValidation.validate(
                question: "Lunch?", options: ["1", "2", "3", "4", "5", "6", "7"]),
            PollValidation.tooManyOptions)
    }

    func testDuplicateOptionsRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: "Lunch?", options: ["Pizza", " pizza "]),
            PollValidation.duplicateOption)
    }

    func testLongQuestionRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: String(repeating: "q", count: 257), options: ["A", "B"]),
            PollValidation.questionTooLong)
    }

    func testLongOptionRejected() {
        XCTAssertEqual(
            PollValidation.validate(question: "Lunch?", options: ["A", String(repeating: "o", count: 129)]),
            PollValidation.optionTooLong)
    }

    func testValidDraftPasses() {
        XCTAssertNil(PollValidation.validate(question: "Lunch?", options: ["Pizza", "Salad"]))
    }

    func testMakeTrimsAndNumbersIDs() {
        let poll = PollValidation.make(question: "  Lunch?  ", options: [" Pizza ", "Salad"])
        XCTAssertEqual(poll.question, "Lunch?")
        XCTAssertEqual(poll.options.map(\.id), ["o1", "o2"])
        XCTAssertEqual(poll.options.map(\.text), ["Pizza", "Salad"])
        XCTAssertFalse(poll.allowMultiple)
    }

    // MARK: - Payload round-trips

    func testFallbackTextRoundTrips() {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Salad"])
        let text = PollPayload.fallbackText(poll: poll)
        let back = PollInfo.extract(messageID: "m1", content: text, raw: nil)
        XCTAssertEqual(back?.question, "Lunch?")
        XCTAssertEqual(back?.options.map(\.text), ["Pizza", "Salad"])
        XCTAssertEqual(back?.allowMultiple, false)
    }

    func testFallbackTextMarksMulti() {
        let poll = PollValidation.make(question: "Days?", options: ["Mon", "Tue"], allowMultiple: true)
        let back = PollInfo.extract(
            messageID: "m2", content: PollPayload.fallbackText(poll: poll), raw: nil)
        XCTAssertEqual(back?.allowMultiple, true)
    }

    func testPlainTextIsNotAPoll() {
        XCTAssertNil(PollInfo.extract(messageID: "m3", content: "Hello team", raw: nil))
        XCTAssertNil(PollInfo.extract(messageID: "m4", content: "📊 Only a question", raw: nil))
    }

    func testCardJSONRoundTrips() throws {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Salad"])
        let json = PollPayload.cardJSON(poll: poll)
        let raw = "{\"attachments\":[{\"contentType\":\"application/vnd.microsoft.card.adaptive\","
            + "\"content\":\(json)}]}"
        let back = PollInfo.extract(messageID: "m5", content: "", raw: raw)
        XCTAssertEqual(back?.question, "Lunch?")
        XCTAssertEqual(back?.options.map(\.text), ["Pizza", "Salad"])
        XCTAssertEqual(back?.id, poll.id)
    }

    func testFormsChoiceSetParses() {
        let raw = """
            {"type":"AdaptiveCard","version":"1.4","body":[\
            {"type":"TextBlock","text":"Pick a slot"},\
            {"type":"Input.ChoiceSet","id":"slot","isMultiSelect":false,\
            "choices":[{"title":"Morning","value":"am"},{"title":"Evening","value":"pm"}]}],\
            "actions":[{"type":"Action.Submit","title":"Vote"}]}
            """
        let back = PollInfo.extract(messageID: "m6", content: "", raw: raw)
        XCTAssertEqual(back?.question, "Pick a slot")
        XCTAssertEqual(back?.options.map(\.text), ["Morning", "Evening"])
    }

    func testBotCardWithoutPollIsNil() {
        XCTAssertNil(PollInfo.extract(messageID: "m7", content: "", raw: AdaptiveCardsTests.bareCard))
    }

    // MARK: - Votes

    private func registeredPoll(multi: Bool = false) -> Poll {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Salad"], allowMultiple: multi)
        PollRegistry.register(poll, messageID: "mv")
        return poll
    }

    func testVoteAndChange() throws {
        let poll = registeredPoll()
        try PollRegistry.vote(messageID: "mv", optionIDs: ["o1"])
        XCTAssertEqual(PollRegistry.myVote(messageID: "mv"), ["o1"])
        try PollRegistry.vote(messageID: "mv", optionIDs: ["o2"])
        XCTAssertEqual(PollRegistry.myVote(messageID: "mv"), ["o2"])
        let tally = PollRegistry.tally(messageID: "mv")
        XCTAssertEqual(tally?.map(\.votes), [0, 1])
        XCTAssertEqual(PollRegistry.ballotCount(messageID: "mv"), 1)
    }

    func testSecondOptionInSinglePollRejected() {
        _ = registeredPoll()
        XCTAssertThrowsError(try PollRegistry.vote(messageID: "mv", optionIDs: ["o1", "o2"])) { error in
            XCTAssertEqual(error as? PollVoteError, .multiNotAllowed)
        }
    }

    func testMultiPollTakesSeveral() throws {
        _ = registeredPoll(multi: true)
        try PollRegistry.vote(messageID: "mv", optionIDs: ["o1", "o2"])
        XCTAssertEqual(PollRegistry.myVote(messageID: "mv"), ["o1", "o2"])
    }

    func testUnknownOptionRejected() {
        _ = registeredPoll()
        XCTAssertThrowsError(try PollRegistry.vote(messageID: "mv", optionIDs: ["o9"])) { error in
            XCTAssertEqual(error as? PollVoteError, .unknownOption)
        }
    }

    func testUnknownPollRejected() {
        XCTAssertThrowsError(try PollRegistry.vote(messageID: "nope", optionIDs: ["o1"])) { error in
            XCTAssertEqual(error as? PollVoteError, .unknownPoll)
        }
    }

    func testClosedPollRejectsVotes() {
        let poll = registeredPoll()
        PollRegistry.close(messageID: "mv")
        XCTAssertThrowsError(try PollRegistry.vote(messageID: "mv", optionIDs: ["o1"])) { error in
            XCTAssertEqual(error as? PollVoteError, .closed)
        }
        XCTAssertEqual(PollRegistry.poll(messageID: "mv")?.closed, true)
        XCTAssertEqual(poll.closed, false)
    }

    func testResolveParsesAndRegisters() {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Salad"])
        let text = PollPayload.fallbackText(poll: poll)
        let resolved = PollRegistry.resolve(messageID: "mr", content: text, raw: nil)
        XCTAssertEqual(resolved?.question, "Lunch?")
        XCTAssertNotNil(PollRegistry.poll(messageID: "mr"))
    }

    // MARK: - Results math

    func testTallyCountsBallots() {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Salad"])
        let counts = PollTally.count(options: poll.options, ballots: [["o1"], ["o1", "o2"], []])
        XCTAssertEqual(counts.map(\.votes), [2, 1])
    }

    func testPercentNeedsNoVotes() {
        XCTAssertEqual(PollTally.percent(votes: 0, totalBallots: 0), 0)
        XCTAssertEqual(PollTally.percent(votes: 1, totalBallots: 4), 0.25)
    }
}
