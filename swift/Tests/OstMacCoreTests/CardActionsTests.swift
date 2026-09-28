// CardActionsTests.swift — om-jd-cardactions lane: Adaptive/O365 action
// mining (OpenUrl buttons vs Teams fallback) + fallback URL shapes.
import XCTest

@testable import OstMacCore

@MainActor
final class CardActionsTests: XCTestCase {
    // MARK: - Adaptive actions

    func testOpenUrlActionsBecomeButtons() {
        let raw = #"{"type":"AdaptiveCard","body":[],"actions":[{"type":"Action.OpenUrl","title":"Docs","url":"https://h/docs"},{"type":"Action.OpenUrl","title":"Run","url":"https://h/run"}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertEqual(set.openURLs.map(\.title), ["Docs", "Run"])
        XCTAssertEqual(
            set.openURLs.map { $0.url.absoluteString },
            ["https://h/docs", "https://h/run"])
        XCTAssertFalse(set.needsTeamsFallback)
        XCTAssertFalse(set.isEmpty)
    }

    func testSubmitExecuteAndInputsNeedTeamsFallback() {
        let raw = #"{"type":"AdaptiveCard","body":[{"type":"Input.Text","id":"note"}],"actions":[{"type":"Action.Submit","title":"Send"},{"type":"Action.Execute","verb":"ok"}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertTrue(set.openURLs.isEmpty)
        XCTAssertTrue(set.needsTeamsFallback)
        XCTAssertFalse(set.isEmpty)
    }

    func testUnknownActionTypesFallBack() {
        let set = CardActions.actions(fromRaw:
            #"{"type":"AdaptiveCard","actions":[{"type":"Action.SomethingNew"}]}"#)
        XCTAssertTrue(set.openURLs.isEmpty)
        XCTAssertTrue(set.needsTeamsFallback)
    }

    func testNonHTTPOpenUrlFallsBack() {
        // Custom-scheme targets are for Teams, never the browser.
        let set = CardActions.actions(fromRaw:
            #"{"type":"AdaptiveCard","actions":[{"type":"Action.OpenUrl","title":"App","url":"msteams://l/meetup-join/x"}]}"#)
        XCTAssertTrue(set.openURLs.isEmpty)
        XCTAssertTrue(set.needsTeamsFallback)
    }

    func testShowCardRecurses() {
        let raw = #"{"type":"AdaptiveCard","actions":[{"type":"Action.ShowCard","card":{"actions":[{"type":"Action.OpenUrl","title":"Deep","url":"https://h/deep"}]}}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertEqual(set.openURLs.map(\.title), ["Deep"])
        XCTAssertFalse(set.needsTeamsFallback)
    }

    func testButtonsCapped() {
        let acts = (1 ... 9).map {
            #"{"type":"Action.OpenUrl","title":"L\#( $0 )","url":"https://h/\#( $0 )"}"#
        }.joined(separator: ",")
        let set = CardActions.actions(fromRaw:
            #"{"type":"AdaptiveCard","actions":[\#(acts)]}"#)
        XCTAssertEqual(set.openURLs.count, CardActions.maxButtons)
    }

    // MARK: - O365 + extensions

    func testO365OpenUriBecomesButton() {
        let raw = #"{"@type":"MessageCard","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://h/builds/7"}]}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertEqual(set.openURLs.map(\.title), ["View run"])
        XCTAssertEqual(set.openURLs.first?.url.absoluteString, "https://h/builds/7")
        XCTAssertFalse(set.needsTeamsFallback)
    }

    func testO365HttpPostAndActionCardFallBack() {
        let raw = #"{"@type":"MessageCard","potentialAction":[{"@type":"HttpPOST","name":"Approve"},{"@type":"ActionCard","name":"Comment"}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertTrue(set.openURLs.isEmpty)
        XCTAssertTrue(set.needsTeamsFallback)
    }

    func testComposeExtensionFallsBack() {
        let set = CardActions.actions(fromRaw:
            #"{"type":"AdaptiveCard","composeExtension":{"botId":"b"}}"#)
        XCTAssertTrue(set.needsTeamsFallback)
    }

    func testNestedContentActionsMined() {
        // Adaptive cards nest under attachments[].content.
        let raw = #"{"attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","actions":[{"type":"Action.OpenUrl","title":"N","url":"https://h/n"}]}}]}"#
        let set = CardActions.actions(fromRaw: raw)
        XCTAssertEqual(set.openURLs.map(\.title), ["N"])
        XCTAssertFalse(set.needsTeamsFallback)
    }

    // MARK: - Non-cards

    func testNonCardRawYieldsEmpty() {
        XCTAssertTrue(CardActions.actions(fromRaw: nil).isEmpty)
        XCTAssertTrue(CardActions.actions(fromRaw: "  ").isEmpty)
        XCTAssertTrue(CardActions.actions(fromRaw: "<p>hi</p>").isEmpty)
        XCTAssertTrue(CardActions.actions(fromRaw:
            #"<attachment><a href="https://h/a">Post A</a></attachment>"#).isEmpty)
        XCTAssertTrue(CardActions.actions(fromRaw: #"{"a": 1}"#).isEmpty)
        XCTAssertTrue(CardActions.actions(fromRaw: "{oops").isEmpty)
    }

    // MARK: - Fallback URLs (browser form; msteams:// unverified)

    func testChannelFallbackIsMessageLink() {
        let url = CardActions.fallbackURL(
            chatID: "19:abc@thread.tacv2", messageID: "1758552345000")
        XCTAssertEqual(
            url.absoluteString,
            "https://teams.microsoft.com/l/message/19:abc@thread.tacv2/1758552345000")
    }

    func testChatFallbackIsChatLink() {
        let url = CardActions.fallbackURL(
            chatID: "19:abc@thread.v2", messageID: "123")
        XCTAssertEqual(
            url.absoluteString,
            "https://teams.microsoft.com/l/chat/19:abc@thread.v2/conversations")
    }

    func testMissingIDsFallBackToTeamsHome() {
        XCTAssertEqual(
            CardActions.fallbackURL(chatID: nil, messageID: "1"),
            CardActions.teamsHomeURL)
        XCTAssertEqual(
            CardActions.fallbackURL(chatID: "19:a@thread.v2", messageID: ""),
            CardActions.teamsHomeURL)
        XCTAssertEqual(CardActions.teamsHomeURL.absoluteString, "https://teams.microsoft.com")
    }
}
