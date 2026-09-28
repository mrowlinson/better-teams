// MentionsTests.swift — om-mentions: compose picker, mine highlight, filter.
import XCTest

@testable import OstMacCore

@MainActor
final class MentionsTests: XCTestCase {
    // MARK: - helpers

    static func bubble(
        id: String = "m", sender: String = "Megan Harper",
        content: String, raw: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, sender: sender, timestamp: "2026-09-23T10:00:00Z",
            content: content, raw: raw)
    }

    func event(
        chatID: String = "19:chat@thread.v2",
        sender: String = "Megan Harper",
        senderID: String? = "8:orgid:megan",
        text: String = "hello",
        raw: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: "m1", sender: sender,
            senderID: senderID, text: text, time: "2026-09-23T10:00:00Z",
            isEdit: false, raw: raw)
    }

    // MARK: - picker: roster

    func testRosterRecentFirstDistinct() {
        let msgs = [
            Self.bubble(id: "1", sender: "Megan Harper", content: "a"),
            Self.bubble(id: "2", sender: "Tom Becker", content: "b"),
            Self.bubble(id: "3", sender: "Megan Harper", content: "c"),
            Self.bubble(id: "4", sender: "Me", content: "d"),
            Self.bubble(id: "5", sender: "  ", content: "blank sender dropped"),
        ]
        XCTAssertEqual(
            MentionCompose.roster(from: msgs),
            ["Me", "Megan Harper", "Tom Becker"])
    }

    func testRosterExcludesSelf() {
        let msgs = [
            Self.bubble(id: "1", sender: "Megan Harper", content: "a"),
            Self.bubble(id: "2", sender: "Me", content: "b"),
        ]
        XCTAssertEqual(
            MentionCompose.roster(from: msgs, excluding: "me"),
            ["Megan Harper"])
        // Whitespace-tolerant, case-insensitive.
        XCTAssertEqual(
            MentionCompose.roster(from: msgs, excluding: "  ME  "),
            ["Megan Harper"])
        // Nil exclusion keeps everyone.
        XCTAssertEqual(MentionCompose.roster(from: msgs).count, 2)
        XCTAssertTrue(MentionCompose.roster(from: []).isEmpty)
    }

    func testRosterDedupesCaseInsensitively() {
        let msgs = [
            Self.bubble(id: "1", sender: "megan harper", content: "a"),
            Self.bubble(id: "2", sender: "Megan Harper", content: "b"),
        ]
        // Reverse walk: the later spelling wins, single entry.
        XCTAssertEqual(MentionCompose.roster(from: msgs), ["Megan Harper"])
    }

    // MARK: - picker: query filter

    func testFilteredQuery() {
        let roster = ["Me", "Megan Harper", "Tom Becker"]
        XCTAssertEqual(MentionCompose.filtered(roster, query: "meg"), ["Megan Harper"])
        XCTAssertEqual(
            MentionCompose.filtered(roster, query: "  TOM "),
            ["Tom Becker"])
        XCTAssertEqual(MentionCompose.filtered(roster, query: ""), roster)
        XCTAssertEqual(MentionCompose.filtered(roster, query: "   "), roster)
        XCTAssertTrue(MentionCompose.filtered(roster, query: "zzz").isEmpty)
    }

    // MARK: - picker: insertion

    func testInsertSpacing() {
        XCTAssertEqual(MentionCompose.insert("Bo", into: ""), "@Bo ")
        XCTAssertEqual(MentionCompose.insert("Bo", into: "hi"), "hi @Bo ")
        XCTAssertEqual(MentionCompose.insert("Bo", into: "hi "), "hi @Bo ")
        // A leading @ on the picked name never doubles the sigil.
        XCTAssertEqual(MentionCompose.insert("@Bo", into: ""), "@Bo ")
        // Blank names leave the draft untouched.
        XCTAssertEqual(MentionCompose.insert("  ", into: "hi"), "hi")
    }

    // MARK: - mine: matching

    func testBareName() {
        XCTAssertEqual(Mentions.bareName("@Me"), "Me")
        XCTAssertEqual(Mentions.bareName("  Me  "), "Me")
        XCTAssertEqual(Mentions.bareName("@"), "")
        XCTAssertEqual(Mentions.bareName(""), "")
    }

    func testMentionsOwnerStripsAtSigil() {
        let at = [Mention(id: "0", mri: nil, displayName: "@Me")]
        XCTAssertTrue(Mentions.mentionsOwner(at, ownerMRI: nil, ownerDisplayName: "Me"))
        XCTAssertTrue(Mentions.mentionsOwner(at, ownerMRI: nil, ownerDisplayName: "me"))
        XCTAssertFalse(Mentions.mentionsOwner(at, ownerMRI: nil, ownerDisplayName: "Bo"))
        // Channel spellings strip too.
        XCTAssertTrue(Mentions.mentionsChannelOrEveryone(
            [Mention(id: "0", mri: nil, displayName: "@channel")]))
        // MRI mismatch still wins over the stripped name.
        let m = [Mention(id: "0", mri: "8:orgid:other", displayName: "@Me")]
        XCTAssertFalse(Mentions.mentionsOwner(m, ownerMRI: "8:orgid:me", ownerDisplayName: "Me"))
    }

    func testChatMessageMinesOwnerFromRaw() {
        let at = Self.bubble(
            content: "Nice. @Me please double-check.",
            raw: #"<p>Nice. <at id="8:me">@Me</at> please double-check.</p>"#)
        XCTAssertTrue(at.mentionsOwner(ownName: "Me"))
        XCTAssertTrue(at.mentionsOwner(ownName: "me"))
        XCTAssertFalse(at.mentionsOwner(ownName: "Bo"))
        XCTAssertFalse(at.mentionsOwner(ownName: nil))
        XCTAssertFalse(at.mentionsOwner(ownName: "  "))

        let span = Self.bubble(
            content: "hi Me",
            raw: #"hi <span itemtype="http://schema.skype.com/Mention" itemid="0">Me</span>"#)
        XCTAssertTrue(span.mentionsOwner(ownName: "Me"))
    }

    func testMentionsOwnerMatchesSplitSpans() {
        // Live wire shape: one person across two adjacent Mention spans.
        let split = [
            Mention(id: "0", mri: nil, displayName: "Rowlinson,"),
            Mention(id: "1", mri: nil, displayName: "Michael"),
        ]
        XCTAssertTrue(Mentions.mentionsOwner(split, ownerMRI: nil, ownerDisplayName: "Michael Rowlinson"))
        XCTAssertTrue(Mentions.mentionsOwner(split, ownerMRI: nil, ownerDisplayName: "Rowlinson, Michael"))
        // Non-owner and non-adjacent coverage never match.
        XCTAssertFalse(Mentions.mentionsOwner(split, ownerMRI: nil, ownerDisplayName: "Bo"))
        let scattered = [
            Mention(id: "0", mri: nil, displayName: "Rowlinson,"),
            Mention(id: "1", mri: nil, displayName: "Tom Becker"),
            Mention(id: "2", mri: nil, displayName: "Michael"),
        ]
        XCTAssertFalse(Mentions.mentionsOwner(scattered, ownerMRI: nil, ownerDisplayName: "Michael Rowlinson"))
        // Single Last,First span vs First Last owner: same class, matches.
        XCTAssertTrue(Mentions.mentionsOwner(
            [Mention(id: "0", mri: nil, displayName: "Rowlinson, Michael")],
            ownerMRI: nil, ownerDisplayName: "Michael Rowlinson"))
        // End-to-end through raw mining.
        let bubble = Self.bubble(
            content: "Rowlinson, Michael STOP ASSIGNING ME TICKETS",
            raw: #"<span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Rowlinson,</span> <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="1">Michael</span>STOP ASSIGNING ME TICKETS"#)
        XCTAssertTrue(bubble.mentionsOwner(ownName: "Michael Rowlinson"))
        // MRI mismatch still vetoes the join; IDs-only mode disables it.
        let veto = [
            Mention(id: "0", mri: "8:orgid:other", displayName: "Rowlinson,"),
            Mention(id: "1", mri: nil, displayName: "Michael"),
        ]
        XCTAssertFalse(Mentions.mentionsOwner(veto, ownerMRI: "8:orgid:me", ownerDisplayName: "Michael Rowlinson"))
        XCTAssertFalse(Mentions.mentionsOwner(split, ownerMRI: nil, ownerDisplayName: "Michael Rowlinson", matchByName: false))
    }

    func testChatMessageMineNeedsRaw() {
        // Content-only @-text without raw never mines (render fallback
        // is bubble-only; matching stays on MessageInfo.raw).
        let echo = Self.bubble(content: "hi @Me", raw: nil)
        XCTAssertTrue(echo.mentions.isEmpty)
        XCTAssertFalse(echo.mentionsOwner(ownName: "Me"))
        let other = Self.bubble(
            content: "hi @Bo",
            raw: #"<p>hi <at id="8:b">@Bo</at></p>"#)
        XCTAssertFalse(other.mentionsOwner(ownName: "Me"))
    }

    // MARK: - mine: bubble highlight

    func testAttributedBodyHighlightsMine() {
        let m = Self.bubble(
            content: "Nice. @Me please double-check.",
            raw: #"<p>Nice. <at id="8:me">@Me</at> please double-check.</p>"#)
        let a = MessageRender.attributedBody(for: m, highlighting: "Me")
        let washed = a.runs.filter { $0.mention == .own }
        XCTAssertEqual(washed.count, 1)
        let want = Range(m.content.range(of: "@Me")!, in: a)!
        XCTAssertEqual(washed[0].range, want)
        // The mine still bolds like every mention.
        XCTAssertFalse(a.runs.filter { $0.isStyledSpan }.isEmpty)
    }

    func testAttributedBodyLeavesNonMineUnwashed() {
        let m = Self.bubble(
            content: "Hi @Bo, ship it",
            raw: #"<p>Hi <at id="8:b">@Bo</at>, ship it</p>"#)
        let other = MessageRender.attributedBody(for: m, highlighting: "Me")
        XCTAssertTrue(other.runs.filter { $0.mention == .own }.isEmpty)
        // …but still bolds.
        XCTAssertEqual(other.runs.filter { $0.isStyledSpan }.count, 1)
        // Nil/blank owner disables the wash entirely.
        let nilOwn = MessageRender.attributedBody(for: m)
        XCTAssertTrue(nilOwn.runs.filter { $0.mention == .own }.isEmpty)
        let mine = Self.bubble(
            content: "hi @Me", raw: #"<p>hi <at id="0">@Me</at></p>"#)
        let blankOwn = MessageRender.attributedBody(for: mine, highlighting: "  ")
        XCTAssertTrue(blankOwn.runs.filter { $0.mention == .own }.isEmpty)
    }

    func testIsOwnerMention() {
        XCTAssertTrue(MessageRender.isOwnerMention("@Me", ownName: "Me"))
        XCTAssertTrue(MessageRender.isOwnerMention("me", ownName: "Me"))
        XCTAssertFalse(MessageRender.isOwnerMention("@Bo", ownName: "Me"))
        XCTAssertFalse(MessageRender.isOwnerMention("@Me", ownName: nil))
        XCTAssertFalse(MessageRender.isOwnerMention("", ownName: "Me"))
        XCTAssertFalse(MessageRender.isOwnerMention("@", ownName: "Me"))
    }

    // MARK: - filter: mentioning threads

    static func chat(id: String, name: String) -> ChatItem {
        ChatItem(chatId: id, name: name, is_group: true)
    }

    func testFilterMentionsPreservesOrder() {
        let chats = [
            Self.chat(id: "a", name: "A"),
            Self.chat(id: "b", name: "B"),
            Self.chat(id: "c", name: "C"),
        ]
        // Set order never leaks through: list order wins (no re-sort —
        // pin-top owns the comparator).
        let out = ChatListFormat.filterMentions(chats, mentionedIDs: ["c", "a"])
        XCTAssertEqual(out.map(\.id), ["a", "c"])
    }

    func testFilterMentionsEmptyAndUnknown() {
        let chats = [Self.chat(id: "a", name: "A")]
        XCTAssertTrue(ChatListFormat.filterMentions(chats, mentionedIDs: []).isEmpty)
        XCTAssertTrue(
            ChatListFormat.filterMentions(chats, mentionedIDs: ["zzz"]).isEmpty)
        XCTAssertEqual(
            ChatListFormat.filterMentions(chats, mentionedIDs: ["a", "zzz"]).map(\.id),
            ["a"])
    }

    func testFilterMentionsComposesWithQuery() {
        let chats = [
            Self.chat(id: "a", name: "Design Sync"),
            Self.chat(id: "b", name: "Design Review"),
            Self.chat(id: "c", name: "Watercooler"),
        ]
        let queried = ChatListFormat.filter(chats, query: "design")
        let out = ChatListFormat.filterMentions(queried, mentionedIDs: ["b", "c"])
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    // MARK: - store: MentionStore

    func testStoreFlagsMentioningEvent() {
        let store = MentionStore()
        XCTAssertEqual(store.count, 0)
        store.ingest(
            realtime: event(raw: #"hi <at id="0">@Me</at>"#),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        XCTAssertTrue(store.contains(chatID: "19:chat@thread.v2"))
        XCTAssertEqual(store.count, 1)
    }

    func testStoreSkipsOwnOpenPlainAndBlank() {
        let store = MentionStore()
        let mining = #"hi <at id="0">@Me</at>"#
        // Own message (MRI): self-mentions never accrue.
        store.ingest(
            realtime: event(sender: "Me", senderID: "8:orgid:me", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        // Own message (name backup, no sender MRI).
        store.ingest(
            realtime: event(chatID: "19:other", sender: "Me", senderID: nil, raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        // Open chat: visible bubbles never accrue.
        store.ingest(
            realtime: event(chatID: "19:open", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: "19:open")
        // Plain event: no mined mention.
        store.ingest(
            realtime: event(chatID: "19:plain", text: "hello"),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        // Blank chat id.
        store.ingest(
            realtime: event(chatID: "  ", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        // Blank identity fails closed (never flags the world).
        store.ingest(
            realtime: event(chatID: "19:noid", raw: mining),
            ownName: "  ", ownerMRI: nil, openChatID: nil)
        XCTAssertEqual(store.count, 0)
    }

    func testStoreMarkRead() {
        let store = MentionStore()
        store.adopt(["a", "b"])
        XCTAssertEqual(store.count, 2)
        store.markRead(chatID: "a")
        XCTAssertFalse(store.contains(chatID: "a"))
        XCTAssertTrue(store.contains(chatID: "b"))
        store.markRead(chatID: "unknown") // no-op
        XCTAssertEqual(store.count, 1)
        store.markAllRead()
        XCTAssertEqual(store.count, 0)
        store.markAllRead() // no-op
        XCTAssertEqual(store.count, 0)
    }

    func testStoreNoteThread() {
        let store = MentionStore()
        let mining = [
            Self.bubble(id: "1", content: "hello"),
            Self.bubble(
                id: "2", content: "hi @Me",
                raw: #"<p>hi <at id="0">@Me</at></p>"#),
        ]
        store.noteThread(chatID: "19:t", messages: mining, ownName: "Me")
        XCTAssertTrue(store.contains(chatID: "19:t"))
        // No mined mention: no flag. Blank id: no flag.
        store.noteThread(chatID: "19:u", messages: [mining[0]], ownName: "Me")
        store.noteThread(chatID: "  ", messages: mining, ownName: "Me")
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - demo seed

    func testDemoMentionSeedMatchesThread() {
        XCTAssertEqual(DemoData.mentionedChatIDs, [DemoData.richID, DemoData.showcaseID])
        // The seed is real: the rich thread mines an owner mention.
        let store = MentionStore()
        store.noteThread(
            chatID: DemoData.richID,
            messages: ConversationStore.richDemoMessages(),
            ownName: DemoData.ownerDisplayName)
        XCTAssertTrue(store.contains(chatID: DemoData.richID))
        // om-demo-showcase: the showcase kickoff mines one too.
        store.noteThread(
            chatID: DemoData.showcaseID,
            messages: DemoData.showcaseMessages(),
            ownName: DemoData.ownerDisplayName)
        XCTAssertTrue(store.contains(chatID: DemoData.showcaseID))
    }
}
