// WaveFBannerTests — om-merge-waveF regression: one event, one banner.
//
// The merged pipeline (AppState.maybeNotify) is: rules engine → per-chat
// mute guard → NcDelivery.makeBanner(preview, sound) → single Notifier
// post. These tests pin that shape at the core level: exactly one banner
// object per notify decision, muted chats suppressed at both layers,
// preview-off redacting text, sound-off posting silent.
import XCTest

@testable import OstMacCore

final class WaveFBannerTests: XCTestCase {
    func msg(
        chatID: String = "19:chat@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan",
        text: String = "hello there"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            text: text, time: "2026-09-23T10:00:00Z",
            isEdit: false, messageType: "Text")
    }

    func cfg(mutes: Set<String> = []) -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.mutedChatIDs = mutes
        c.applyRules()
        return c
    }

    /// Core-level mirror of AppState.maybeNotify: decision → mute guard →
    /// single makeBanner. Nil = no post; non-nil = exactly one post.
    func pipelineBanner(
        for m: RealtimeMessage, chatName: String = "Team Chat",
        rules: RulesConfig, showPreview: Bool = true, sound: Bool = true
    ) -> NcDelivery.Banner? {
        let decision = ChatFilter.decide(
            message: m, chatDisplayName: chatName,
            ownerMRI: "8:orgid:me", rules: rules)
        guard !rules.mutedChatIDs.contains(m.chatID) else { return nil }
        return NcDelivery.makeBanner(
            for: m, chatName: chatName, decision: decision,
            screenLocked: false, showPreview: showPreview, sound: sound)
    }

    func testOneEventOneBanner() {
        let rules = cfg()
        let events = (1...5).map { i in msg(msgId: "m\(i)", text: "text \(i)") }
        let banners = events.compactMap {
            pipelineBanner(for: $0, rules: rules)
        }
        // Exactly one banner per event — no drops, no doubles.
        XCTAssertEqual(banners.count, events.count)
        XCTAssertEqual(banners.map(\.id), events.map(\.msgId))
    }

    func testMutedChatSuppressesAtBothLayers() {
        let rules = cfg(mutes: ["19:chat@thread.v2"])
        // Rules engine skips muted chats (never reaches the banner home).
        XCTAssertEqual(
            ChatFilter.decide(
                message: msg(), chatDisplayName: "Team Chat",
                ownerMRI: "8:orgid:me", rules: rules),
            .skip(reason: ChatFilter.chatMutedReason))
        // And the explicit mute guard suppresses even a notify decision.
        XCTAssertNil(pipelineBanner(for: msg(), rules: rules))
        XCTAssertNil(NcDelivery.makeBanner(
            for: msg(), chatName: "Team Chat",
            decision: .skip(reason: ChatFilter.chatMutedReason),
            screenLocked: false))
        // A sibling chat still banners.
        XCTAssertNotNil(pipelineBanner(
            for: msg(chatID: "19:other@thread.v2"), rules: rules))
    }

    func testPreviewOffRedactsBannerBody() {
        let rules = cfg()
        let b = pipelineBanner(
            for: msg(text: "secret plans"), rules: rules, showPreview: false)
        XCTAssertEqual(b?.body, MessageNotifications.hiddenPreviewBody)
        XCTAssertFalse(b?.body.contains("secret plans") ?? true)
        XCTAssertEqual(b?.title, "Megan in Team Chat")
        // Preview on shows the text.
        let open = pipelineBanner(for: msg(text: "secret plans"), rules: rules)
        XCTAssertEqual(open?.body, "secret plans")
    }

    func testPreviewOffKeepsMeetingBody() {
        let b = NcDelivery.makeBanner(
            for: msg(text: "StandupPlay"), chatName: "Standup",
            decision: .notify(reason: ChatFilter.meetingStartingReason),
            screenLocked: false, showPreview: false)
        // Synthesized bodies are not message content — they stay.
        XCTAssertEqual(b?.body, "Meeting starting: Standup")
    }

    func testSoundReachesBanner() {
        let rules = cfg()
        XCTAssertEqual(
            pipelineBanner(for: msg(), rules: rules)?.sound, true)
        XCTAssertEqual(
            pipelineBanner(for: msg(), rules: rules, sound: false)?.sound, false)
    }
}
