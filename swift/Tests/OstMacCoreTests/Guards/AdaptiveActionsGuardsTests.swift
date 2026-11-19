// AdaptiveActionsGuardsTests.swift — ADAPTIVE-ACTIONS lane: adopted
// action sets (Submit/ShowCard/ToggleVisibility), the approvals hub
// path, and fallback preservation (Execute/unknown still fall back,
// hostile blobs never crash).
import XCTest

@testable import OstMacCore

@MainActor
final class AdaptiveActionsGuardsTests: XCTestCase {
    // MARK: - Submit adopted (disabled, honest)

    func testPureSubmitCardAdoptedNoFallback() {
        let raw = """
            {"type":"AdaptiveCard","version":"1.4",\
            "body":[{"type":"TextBlock","text":"Pick a slot"}],\
            "actions":[{"type":"Action.Submit","title":"Book","data":{"slot":"am"}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards[0].needsFallback)
        XCTAssertEqual(cards[0].actions.count, 1)
        guard case .submit(let s) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertEqual(s.title, "Book")
        XCTAssertEqual(s.data, ["slot": "am"])
        XCTAssertTrue(cards[0].actions[0].isSubmit)
        XCTAssertNil(cards[0].approval)
        XCTAssertNil(cards[0].approvalRoute)
    }

    func testSubmitDisabledReasonPinned() {
        // The exact honest copy on every Submit button (help + caption).
        XCTAssertEqual(
            AdaptiveCard.submitDisabledReason,
            "Submit needs the bot reply channel, which this build doesn't have yet.")
    }

    func testSubmitDataCapsHostile() {
        let pairs = (1 ... 100).map { "\"k\($0)\":\"v\($0)\"" }.joined(separator: ",")
        let raw = "{\"type\":\"AdaptiveCard\",\"body\":[{\"type\":\"TextBlock\",\"text\":\"T\"}],"
            + "\"actions\":[{\"type\":\"Action.Submit\",\"title\":\"Go\",\"data\":{\(pairs),"
            + "\"n\":1,\"b\":true,\"o\":{\"x\":1},\"a\":[1],\"e\":\"  \"}}]}"
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards[0].needsFallback)
        guard case .submit(let s) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertLessThanOrEqual(s.data.count, AdaptiveCard.maxDataPairs)
        XCTAssertNil(s.data["n"])
        XCTAssertNil(s.data["b"])
        XCTAssertNil(s.data["o"])
        XCTAssertNil(s.data["a"])
        XCTAssertNil(s.data["e"])
    }

    func testSubmitCopyLineHonest() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.Submit","title":"Book"}]}
            """
        let lines = AdaptiveCard.cards(fromRaw: raw)[0].copyLines
        XCTAssertTrue(lines.contains("T"))
        XCTAssertTrue(lines.contains("Book — submit unavailable in this build"))
    }

    // MARK: - ShowCard adopted (inline expansion)

    func testShowCardAdoptedNestedParses() {
        let raw = """
            {"type":"AdaptiveCard","version":"1.4",\
            "body":[{"type":"TextBlock","text":"Deploy checklist"}],\
            "actions":[{"type":"Action.ShowCard","title":"Details",\
            "card":{"type":"AdaptiveCard","version":"1.4",\
            "body":[{"type":"TextBlock","text":"Staging is green"}],\
            "actions":[{"type":"Action.OpenUrl","title":"Run","url":"https://h/run"}]}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards[0].needsFallback)
        guard case .showCard(let s) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertEqual(s.title, "Details")
        XCTAssertEqual(s.card.body.count, 1)
        XCTAssertEqual(s.card.actions.count, 1)
        XCTAssertFalse(s.card.needsFallback)
    }

    func testShowCardMissingCardFallsBack() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.ShowCard","title":"Broken"}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertTrue(cards[0].actions.isEmpty)
    }

    func testShowCardDepthCapFallsBack() {
        // Nested-nested ShowCard: the outer ShowCard still adopts, the
        // inner one drops and the fallback signal propagates up.
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.ShowCard","title":"L1",\
            "card":{"type":"AdaptiveCard",\
            "body":[{"type":"TextBlock","text":"N"}],\
            "actions":[{"type":"Action.ShowCard","title":"L2",\
            "card":{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"D"}]}}]}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        guard case .showCard(let s) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertEqual(s.card.body.count, 1)
        XCTAssertTrue(s.card.actions.isEmpty)
        XCTAssertTrue(s.card.needsFallback)
    }

    func testShowCardNestedFallbackPropagates() {
        // A nested Execute: the ShowCard adopts, fallback still signals.
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.ShowCard","title":"More",\
            "card":{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"N"}],\
            "actions":[{"type":"Action.Execute","verb":"go"}]}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertEqual(cards[0].actions.count, 1)
        guard case .showCard(let s) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertTrue(s.card.needsFallback)
    }

    // MARK: - ToggleVisibility adopted (client-side)

    func testToggleAdoptedStringTargets() {
        let raw = """
            {"type":"AdaptiveCard","body":[\
            {"type":"TextBlock","text":"Head"},\
            {"type":"TextBlock","text":"Notes","id":"notes"}],\
            "actions":[{"type":"Action.ToggleVisibility","title":"Hide notes",\
            "targetElements":["notes"]}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards[0].needsFallback)
        guard case .toggle(let t) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertEqual(t.title, "Hide notes")
        XCTAssertEqual(t.targets, [AdaptiveCard.ToggleTarget(elementId: "notes")])
    }

    func testToggleAdoptedObjectTargets() {
        let raw = """
            {"type":"AdaptiveCard","body":[\
            {"type":"TextBlock","text":"A","id":"a"},\
            {"type":"TextBlock","text":"B","id":"b"}],\
            "actions":[{"type":"Action.ToggleVisibility","title":"Flip",\
            "targetElements":[{"elementId":"a","isVisible":false},"b"]}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards[0].needsFallback)
        guard case .toggle(let t) = cards[0].actions[0] else {
            return XCTFail("actions[0] is \(cards[0].actions[0])")
        }
        XCTAssertEqual(t.targets, [
            AdaptiveCard.ToggleTarget(elementId: "a", isVisible: false),
            AdaptiveCard.ToggleTarget(elementId: "b"),
        ])
    }

    func testToggleAllMissDroppedWithFallback() {
        // No target resolves to a rendered id: no button (a button that
        // flips nothing would be fake), fallback signals for Teams.
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.ToggleVisibility","title":"Ghost",\
            "targetElements":["nope"]}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertTrue(cards[0].actions.isEmpty)
    }

    func testToggleEmptyTargetsFallsBack() {
        for targets in ["[]", "[\"  \"]", "[{}]", "[1]"] {
            let raw = "{\"type\":\"AdaptiveCard\",\"body\":[{\"type\":\"TextBlock\",\"text\":\"T\"}],"
                + "\"actions\":[{\"type\":\"Action.ToggleVisibility\",\"title\":\"T\","
                + "\"targetElements\":\(targets)}]}"
            let cards = AdaptiveCard.cards(fromRaw: raw)
            XCTAssertEqual(cards.count, 1, targets)
            XCTAssertTrue(cards[0].needsFallback, targets)
            XCTAssertTrue(cards[0].actions.isEmpty, targets)
        }
    }

    // MARK: - Approvals path (the channel that exists)

    func testApprovalSubmitRoutesToHub() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Travel?"}],\
            "actions":[{"type":"Action.Submit","title":"Approve",\
            "data":{"approvalId":"demo-appr-1","decision":"approve"}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].approval, AdaptiveCard.ApprovalLink(id: "demo-appr-1"))
        XCTAssertEqual(cards[0].approvalRoute, "app/approvals/demo-appr-1")
        // Submit adoption is orthogonal: no fallback from the Submit.
        XCTAssertFalse(cards[0].needsFallback)
    }

    func testApprovalMinedFromExecuteData() {
        // Execute still falls back — but its approval id still routes.
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.Execute","title":"Approve","verb":"approve",\
            "data":{"approvalItemId":"demo-appr-2"}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertTrue(cards[0].actions.isEmpty)
        XCTAssertEqual(cards[0].approvalRoute, "app/approvals/demo-appr-2")
    }

    func testApprovalRejectsRouteUnsafeIDs() {
        for id in ["a/b", "a?b", "a b", ""] {
            let raw = "{\"type\":\"AdaptiveCard\",\"body\":[{\"type\":\"TextBlock\",\"text\":\"T\"}],"
                + "\"actions\":[{\"type\":\"Action.Submit\",\"title\":\"Go\","
                + "\"data\":{\"approvalId\":\"\(id)\"}}]}"
            let cards = AdaptiveCard.cards(fromRaw: raw)
            XCTAssertEqual(cards.count, 1, id)
            XCTAssertNil(cards[0].approval, id)
            XCTAssertNil(cards[0].approvalRoute, id)
            // The Submit itself still adopts.
            XCTAssertEqual(cards[0].actions.count, 1, id)
        }
    }

    func testNonApprovalSubmitHasNoLink() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.Submit","title":"Go","data":{"slot":"am"}}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertNil(cards[0].approval)
        XCTAssertNil(cards[0].approvalRoute)
    }

    // MARK: - Fallback preservation

    func testExecuteStillFallsBack() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.Execute","title":"Go","verb":"go"}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertTrue(cards[0].actions.isEmpty)
    }

    func testUnknownActionStillFallsBack() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.SomethingNew","title":"?"}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertTrue(cards[0].actions.isEmpty)
    }

    func testHostileActionsNeverCrash() {
        let raw = """
            {"type":"AdaptiveCard","body":[{"type":"TextBlock"},1,null,"x",{}],\
            "actions":[{"type":"Action.Submit"},\
            {"type":"Action.ShowCard","card":{}},\
            {"type":"Action.ToggleVisibility"},\
            1,null,"x",{},{"type":5},\
            [{"type":"Action.OpenUrl","url":"https://h/x"}]]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        // The bare Submit adopts (default title); the broken ShowCard /
        // Toggle mark fallback. Nothing throws, nothing hangs.
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        XCTAssertEqual(cards[0].actions.count, 1)
        XCTAssertEqual(cards[0].actions[0].title, "Submit")
    }

    func testElementIDsParsed() {
        let raw = """
            {"type":"AdaptiveCard","body":[\
            {"type":"TextBlock","text":"t","id":"t1"},\
            {"type":"Image","url":"https://h/i.png","id":"i1"},\
            {"type":"FactSet","id":"f1","facts":[{"title":"a","value":"b"}]},\
            {"type":"Container","id":"c1","items":[{"type":"TextBlock","text":"n","id":"t2"}]},\
            {"type":"ColumnSet","id":"cs1","columns":[{"type":"Column","items":[]}]}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(
            AdaptiveCard.elementIDs(in: cards[0].body),
            ["t1", "i1", "f1", "c1", "t2", "cs1"])
    }

    // MARK: - Demo seeds (capture fixtures)

    func testActionCardSeedsParse() {
        let seeds = DemoData.actionCardSeeds()
        XCTAssertEqual(seeds.count, 3)
        // Submit card: 2 submits, adopted, no approval.
        let s = AdaptiveCard.cards(fromRaw: seeds[0].raw)
        XCTAssertEqual(s.count, 1)
        XCTAssertFalse(s[0].needsFallback)
        XCTAssertEqual(s[0].actions.count, 2)
        XCTAssertTrue(s[0].actions.allSatisfy(\.isSubmit))
        XCTAssertNil(s[0].approval)
        // Interactive card: showcard + toggle + openurl, no fallback.
        let i = AdaptiveCard.cards(fromRaw: seeds[1].raw)
        XCTAssertEqual(i.count, 1)
        XCTAssertFalse(i[0].needsFallback)
        XCTAssertEqual(i[0].actions.count, 3)
        // Approval card: 2 submits + hub link.
        let a = AdaptiveCard.cards(fromRaw: seeds[2].raw)
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a[0].needsFallback)
        XCTAssertEqual(a[0].approvalRoute, "app/approvals/demo-appr-1")
    }

    // MARK: - Polls interaction (no phantom ballots)

    func testSubmitCardsAreNotPolls() {
        // Adopted Submit cards (booking, approval) must not mine as
        // polls: submit titles read back only with the btPoll marker.
        for seed in DemoData.actionCardSeeds() {
            XCTAssertNil(
                PollInfo.extract(messageID: seed.id, content: seed.content, raw: seed.raw),
                seed.id)
        }
    }

    func testMarkedPollCardStillExtracts() {
        let poll = PollValidation.make(question: "Lunch?", options: ["Pizza", "Sushi"])
        let raw = PollPayload.cardJSON(poll: poll)
        let back = PollInfo.extract(messageID: "m1", content: "", raw: raw)
        XCTAssertEqual(back?.question, "Lunch?")
        XCTAssertEqual(back?.options.map(\.text), ["Pizza", "Sushi"])
    }
}
