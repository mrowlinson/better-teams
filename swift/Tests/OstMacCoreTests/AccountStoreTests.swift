// AccountStoreTests.swift — d1-accounts: multi-account list, switch,
// remove, relaunch restore, per-account cache namespacing (mocked core).
import XCTest

@testable import OstMacCore

private final class OrderBox: @unchecked Sendable {
    var events: [String] = []
}

private final class ProfileBox: @unchecked Sendable {
    var profiles: [String] = []
    var fail: Bool = false
}

@MainActor
final class AccountStoreTests: XCTestCase {
    // MARK: - Fixtures

    private static let alice = "Alice Barrett"
    private static let bob = "Bob Carpenter"
    private static let aliceUPN = "alice.barrett@example.com"
    private static let bobUPN = "bob.carpenter@example.com"

    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "d1-accounts-\(name)") ?? .standard
        d.removePersistentDomain(forName: "d1-accounts-\(name)")
        return d
    }

    nonisolated static func status(signedIn: Bool) -> StatusResponse {
        let json = """
            {"ok":true,"signed_in":\(signedIn),"tokens":\
            {"aad":{"present":\(signedIn),"expired":false},\
            "refresh_present":\(signedIn),\
            "graph":{"present":false,"expired":false},\
            "ic3":{"present":false,"expired":false},\
            "recorder":{"present":false,"expired":false},\
            "skype":{"present":false,"expired":false},\
            "region_gtms_present":false}}
            """
        return try! decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    private func store(
        _ defaults: UserDefaults,
        profiles: ProfileBox = ProfileBox(),
        order: OrderBox = OrderBox(),
        status: @escaping @Sendable (String) -> StatusResponse = { _ in
            AccountStoreTests.status(signedIn: true)
        }
    ) -> AccountStore {
        let s = AccountStore(
            defaults: defaults,
            profileSet: { profile in
                profiles.profiles.append(profile)
                if profiles.fail { throw CoreCallError.failed("no flip") }
                return ProfileResponse(ok: true, profile: profile)
            },
            signOut: { profile in
                profiles.profiles.append("signout:\(profile)")
                if profiles.fail { throw CoreCallError.failed("no signout") }
                return SignOutResponse(ok: true)
            },
            makeVM: { profile in
                AuthViewModel(profile: profile, status: { status(profile) })
            })
        s.hooks = AccountSwitchHooks(
            drainRealtime: { order.events.append("drain") },
            resetForAccount: { order.events.append("reset:\($0.id)") },
            resume: { order.events.append("resume") },
            removeCaches: { order.events.append("caches:\($0.id)") },
            emptied: { order.events.append("emptied") })
        return s
    }

    // MARK: - Adopt + add

    func testAdoptLegacyCreatesDefaultAccount() {
        let d = suite("adopt")
        let s = store(d)
        XCTAssertTrue(s.accounts.isEmpty)
        s.adoptLegacy(displayName: Self.alice, upn: Self.aliceUPN)
        XCTAssertEqual(s.accounts.count, 1)
        XCTAssertEqual(s.accounts[0].id, AccountProfile.defaultID)
        XCTAssertEqual(s.accounts[0].displayName, Self.alice)
        XCTAssertEqual(s.activeID, AccountProfile.defaultID)
        // Second adopt is a no-op (never duplicates).
        s.adoptLegacy(displayName: Self.bob)
        XCTAssertEqual(s.accounts.count, 1)
        XCTAssertEqual(s.accounts[0].displayName, Self.alice)
    }

    func testBeginAddThenCompleteAddActivates() {
        let d = suite("add")
        let profiles = ProfileBox()
        let s = store(d, profiles: profiles)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        XCTAssertTrue(pending.profile.hasPrefix("acct-"))
        XCTAssertTrue(s.accounts.count == 1) // not listed until complete
        XCTAssertTrue(s.completeAdd(
            profile: pending.profile, displayName: Self.bob, upn: Self.bobUPN))
        XCTAssertEqual(s.accounts.count, 2)
        XCTAssertEqual(s.activeID, pending.profile)
        XCTAssertEqual(profiles.profiles, [pending.profile]) // core flipped once
    }

    func testCompleteAddFailureKeepsRecordButNotActive() {
        let d = suite("addfail")
        let profiles = ProfileBox()
        profiles.fail = true
        let s = store(d, profiles: profiles)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        XCTAssertFalse(s.completeAdd(profile: pending.profile, displayName: Self.bob))
        XCTAssertEqual(s.accounts.count, 2) // record kept for retry
        XCTAssertEqual(s.activeID, AccountProfile.defaultID) // active unchanged
    }

    // MARK: - Switch

    func testSwitchRunsOrderedStages() {
        let d = suite("switch")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        profiles.profiles = []
        XCTAssertTrue(s.completeAdd(profile: pending.profile, displayName: Self.bob))
        order.events = []
        profiles.profiles = []
        XCTAssertTrue(s.switchTo(AccountProfile.defaultID))
        XCTAssertEqual(s.activeID, AccountProfile.defaultID)
        XCTAssertEqual(profiles.profiles, [AccountProfile.defaultID])
        XCTAssertEqual(order.events, ["drain", "reset:default", "resume"])
    }

    func testSwitchToActiveOrUnknownIsNoop() {
        let d = suite("noop")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        XCTAssertTrue(s.switchTo(AccountProfile.defaultID)) // already active
        XCTAssertTrue(s.switchTo("no-such-account")) // unknown
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertTrue(order.events.isEmpty)
        XCTAssertEqual(s.activeID, AccountProfile.defaultID)
    }

    func testSwitchFailureKeepsOldAccountAndResumes() {
        let d = suite("switchfail")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        XCTAssertTrue(s.completeAdd(profile: pending.profile, displayName: Self.bob))
        profiles.fail = true
        order.events = []
        XCTAssertFalse(s.switchTo(AccountProfile.defaultID))
        XCTAssertEqual(s.activeID, pending.profile) // old stays active
        XCTAssertEqual(order.events, ["drain", "resume"]) // no reset on failure
    }

    // MARK: - Remove

    func testRemoveInactiveKeepsActiveUntouched() {
        let d = suite("removeinactive")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        XCTAssertTrue(s.completeAdd(profile: pending.profile, displayName: Self.bob))
        XCTAssertTrue(s.switchTo(AccountProfile.defaultID))
        order.events = []
        profiles.profiles = []
        XCTAssertTrue(s.removeAccount(pending.profile))
        XCTAssertEqual(profiles.profiles, ["signout:\(pending.profile)"])
        XCTAssertEqual(order.events, ["caches:\(pending.profile)"])
        XCTAssertEqual(s.accounts.count, 1)
        XCTAssertEqual(s.activeID, AccountProfile.defaultID)
        XCTAssertNil(s.vms[pending.profile]) // VM dropped
    }

    func testRemoveActiveFallsThroughToNext() {
        let d = suite("removeactive")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        let pending = s.beginAdd()
        XCTAssertTrue(s.completeAdd(profile: pending.profile, displayName: Self.bob))
        order.events = []
        profiles.profiles = []
        XCTAssertTrue(s.removeAccount(pending.profile)) // active
        XCTAssertEqual(s.activeID, AccountProfile.defaultID)
        XCTAssertEqual(
            order.events,
            ["drain", "caches:\(pending.profile)", "reset:default", "resume"])
    }

    func testRemoveLastEmptiesAndRestoresDefault() {
        let d = suite("removelast")
        let profiles = ProfileBox()
        let order = OrderBox()
        let s = store(d, profiles: profiles, order: order)
        s.adoptLegacy(displayName: Self.alice)
        order.events = []
        profiles.profiles = []
        XCTAssertTrue(s.removeAccount(AccountProfile.defaultID))
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertNil(s.activeID)
        XCTAssertEqual(profiles.profiles, ["signout:default", "default"])
        XCTAssertEqual(order.events, ["drain", "caches:default", "emptied"])
    }

    func testRemoveUnknownIsNoop() {
        let d = suite("removeunknown")
        let s = store(d)
        s.adoptLegacy(displayName: Self.alice)
        XCTAssertTrue(s.removeAccount("no-such-account"))
        XCTAssertEqual(s.accounts.count, 1)
    }

    // MARK: - Relaunch restore

    func testRelaunchRestoresListAndActive() {
        let d = suite("relaunch")
        let first = store(d)
        first.adoptLegacy(displayName: Self.alice)
        let pending = first.beginAdd()
        XCTAssertTrue(first.completeAdd(profile: pending.profile, displayName: Self.bob))
        XCTAssertTrue(first.switchTo(AccountProfile.defaultID))
        // Fresh store over the same defaults = relaunch.
        let second = store(d)
        XCTAssertEqual(second.accounts.map(\.id), [AccountProfile.defaultID, pending.profile])
        XCTAssertEqual(second.accounts[1].displayName, Self.bob)
        XCTAssertEqual(second.activeID, AccountProfile.defaultID)
    }

    // MARK: - Per-account isolation

    func testExpiredOneAccountLeavesOtherSignedIn() async {
        let d = suite("isolation")
        let s = store(d, status: { profile in
            Self.status(signedIn: profile != "acct-expired")
        })
        s.adoptLegacy(displayName: Self.alice)
        _ = s.vm(for: "acct-expired")
        let good = s.vm(for: AccountProfile.defaultID)
        let bad = s.vm(for: "acct-expired")
        await good.refreshStatus()
        await bad.refreshStatus()
        XCTAssertEqual(good.state, .signedIn)
        XCTAssertEqual(bad.state, .signedOut)
        // And back: the good account still reads signed in.
        await good.refreshStatus()
        XCTAssertEqual(good.state, .signedIn)
    }

    func testTwoVMsCoexistWithProfiles() {
        let a = AuthViewModel(profile: "acct-a", status: { Self.status(signedIn: true) })
        let b = AuthViewModel(profile: "acct-b", status: { Self.status(signedIn: false) })
        XCTAssertEqual(a.profile, "acct-a")
        XCTAssertEqual(b.profile, "acct-b")
    }

    func testRepointResetsStateAndSwapsProfile() async {
        let vm = AuthViewModel(profile: "acct-a", status: { Self.status(signedIn: true) })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedIn)
        vm.repoint(profile: "acct-b", live: false) // keep injected fns
        XCTAssertEqual(vm.profile, "acct-b")
        XCTAssertEqual(vm.state, .unknown) // never a stale sibling state
        XCTAssertNil(vm.status)
    }

    // MARK: - Key namespacing

    func testPerAccountKeysDifferAndDefaultKeepsLegacy() {
        let other = "acct-helen"
        XCTAssertEqual(PinnedMessages.key(for: "default"), PinnedMessages.defaultsKey)
        XCTAssertEqual(
            PinnedMessages.key(for: other), "\(PinnedMessages.defaultsKey).\(other)")
        XCTAssertEqual(UserPinStore.key(for: "default"), UserPinStore.defaultsKey)
        XCTAssertEqual(
            UserPinStore.key(for: other), "\(UserPinStore.defaultsKey).\(other)")
        XCTAssertEqual(ReactionRecents.key(for: "default"), ReactionRecents.defaultsKey)
        XCTAssertEqual(
            ReactionRecents.key(for: other), "\(ReactionRecents.defaultsKey).\(other)")
        XCTAssertEqual(BlockedStore.key(for: "default"), BlockedStore.usersKey)
        XCTAssertEqual(
            BlockedStore.key(for: other), "\(BlockedStore.usersKey).\(other)")
        XCTAssertEqual(CallHistoryStore.key(for: "default"), CallHistoryStore.defaultsKey)
        XCTAssertEqual(
            CallHistoryStore.key(for: other), "\(CallHistoryStore.defaultsKey).\(other)")
        XCTAssertEqual(FolderStore.foldersKey(for: "default"), FolderStore.foldersKey)
        XCTAssertEqual(
            FolderStore.foldersKey(for: other), "\(FolderStore.foldersKey).\(other)")
        // Every namespaced key is distinct from every other.
        let keys = AccountCaches.keys(for: other)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.hasSuffix(".\(other)") })
    }

    func testSanitizedIDsStayFlat() {
        XCTAssertEqual(AccountProfile.sanitized("../../etc"), ".._.._etc")
        XCTAssertFalse(AccountProfile.sanitized("a/b").contains("/"))
        XCTAssertEqual(AccountProfile.sanitized(""), "_")
    }

    func testDirNestingKeepsDefaultFlat() {
        let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
        XCTAssertEqual(AccountProfile.dir(base, for: "default"), base)
        XCTAssertEqual(
            AccountProfile.dir(base, for: "acct-helen"),
            base.appendingPathComponent("acct-helen", isDirectory: true))
    }

    // MARK: - Store isolation per account

    func testReactionRecentsIsolatePerAccount() {
        let d = suite("recents")
        ReactionRecents.record("🔥", defaults: d, accountID: "acct-a")
        XCTAssertEqual(
            ReactionRecents.load(defaults: d, accountID: "acct-a").first, "🔥")
        // Sibling account still sees the seed grid (no leak).
        XCTAssertEqual(
            ReactionRecents.load(defaults: d, accountID: "acct-b"),
            ReactionRecents.seed)
        XCTAssertEqual(ReactionRecents.load(defaults: d), ReactionRecents.seed)
    }

    func testBlockedStoreIsolatesPerAccount() {
        let d = suite("blocked")
        let a = BlockedStore(defaults: d, key: BlockedStore.key(for: "acct-a"))
        a.block(chatID: "19:thread-a", name: "Dave Matthews")
        XCTAssertEqual(a.count, 1)
        let b = BlockedStore(defaults: d, key: BlockedStore.key(for: "acct-b"))
        XCTAssertEqual(b.count, 0)
        let legacy = BlockedStore(defaults: d)
        XCTAssertEqual(legacy.count, 0)
    }

    func testUserPinsIsolatePerAccount() {
        let d = suite("userpins")
        let a = UserPinStore(defaults: d, key: UserPinStore.key(for: "acct-a"))
        a.pin("19:pinned-by-a@thread.v2")
        XCTAssertTrue(a.isPinned("19:pinned-by-a@thread.v2"))
        let b = UserPinStore(defaults: d, key: UserPinStore.key(for: "acct-b"))
        XCTAssertFalse(b.isPinned("19:pinned-by-a@thread.v2"))
    }

    func testFolderStoreIsolatesPerAccount() {
        let d = suite("folders")
        let a = FolderStore(defaults: d, accountID: "acct-a")
        XCTAssertNotNil(a.createFolder(name: "Work"))
        XCTAssertEqual(a.folders.count, 1)
        let b = FolderStore(defaults: d, accountID: "acct-b")
        XCTAssertTrue(b.folders.isEmpty)
        let legacy = FolderStore(defaults: d)
        XCTAssertTrue(legacy.folders.isEmpty)
    }

    func testCallHistoryKeysIsolatePerAccount() {
        let d = suite("callhist")
        let a = CallHistoryStore(defaults: d, key: CallHistoryStore.key(for: "acct-a"))
        let b = CallHistoryStore(defaults: d, key: CallHistoryStore.key(for: "acct-b"))
        XCTAssertTrue(a.isEmpty)
        XCTAssertTrue(b.isEmpty)
        XCTAssertNotEqual(
            CallHistoryStore.key(for: "acct-a"), CallHistoryStore.key(for: "acct-b"))
    }

    func testPinnedMessageKeysIsolatePerAccount() {
        XCTAssertNotEqual(
            PinnedMessages.key(for: "acct-a"), PinnedMessages.key(for: "acct-b"))
        XCTAssertEqual(
            PinnedMessages.key(for: "default"), PinnedMessages.defaultsKey)
    }

    func testAccountCachesRemoveClearsOneNamespace() {
        let d = suite("cachesrm")
        ReactionRecents.record("🔥", defaults: d, accountID: "acct-a")
        ReactionRecents.record("🎉", defaults: d, accountID: "acct-b")
        AccountCaches.remove(accountID: "acct-a", defaults: d)
        // acct-a's recents key is gone (seed loads); acct-b untouched.
        XCTAssertEqual(
            ReactionRecents.load(defaults: d, accountID: "acct-a"),
            ReactionRecents.seed)
        XCTAssertEqual(
            ReactionRecents.load(defaults: d, accountID: "acct-b").first, "🎉")
    }

    // MARK: - Ownership re-stamp on switch (accept #8)

    func testStampOwnershipFollowsActiveAccount() {
        let mk = { (sender: String) in
            ChatMessage(id: "\(sender)-1", sender: sender, timestamp: "t", content: "hi")
        }
        let aliceStamped = ConversationStore.stampOwnership(
            [mk(Self.alice), mk(Self.bob)], ownName: Self.alice)
        XCTAssertEqual(aliceStamped.map(\.isOwn), [true, false])
        // Switch: same bubbles re-stamped for the new identity.
        let bobStamped = ConversationStore.stampOwnership(
            [mk(Self.alice), mk(Self.bob)], ownName: Self.bob)
        XCTAssertEqual(bobStamped.map(\.isOwn), [false, true])
    }

    func testConversationResetForAccountClearsAndRestamps() {
        let conv = ConversationStore()
        conv.resetForAccount(displayName: Self.bob)
        XCTAssertTrue(conv.messages.isEmpty)
        XCTAssertEqual(conv.ownDisplayName, Self.bob)
        XCTAssertNil(conv.chatID)
        XCTAssertFalse(conv.didLoad)
    }

    // MARK: - Quiet reload (zero-refresh switch)

    func testChatListResetThenQuietLoadSkipsSpinner() async {
        let chats = ChatListViewModel(
            fetcher: { _ in
                ChatsResponse(ok: true, chats: [
                    ChatItem(chatId: "19:c1", name: "Eve Torres"),
                ])
            },
            blocked: BlockedStore(defaults: nil))
        await chats.load()
        XCTAssertEqual(chats.state, .loaded)
        chats.resetForAccount()
        XCTAssertTrue(chats.chats.isEmpty)
        XCTAssertEqual(chats.state, .empty) // static, no spinner
        await chats.loadQuietly()
        XCTAssertEqual(chats.state, .loaded)
        XCTAssertEqual(chats.chats.map(\.name), ["Eve Torres"])
    }

    func testTeamsResetThenQuietLoadSkipsSpinner() async {
        let teams = TeamsViewModel(fetcher: {
            TeamsResponse(
                ok: true,
                teams: [TeamItem(teamId: "t1", name: "Frank Group", channels: [])])
        })
        await teams.load()
        XCTAssertEqual(teams.state, .loaded)
        teams.resetForAccount()
        XCTAssertTrue(teams.teams.isEmpty)
        XCTAssertEqual(teams.state, .empty)
        await teams.loadQuietly()
        XCTAssertEqual(teams.state, .loaded)
        XCTAssertEqual(teams.teams.map(\.name), ["Frank Group"])
    }
}
