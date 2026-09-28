// AppState.swift — app composition root: owns every store, wires the
// realtime feed / notifications / accounts / background sweep / search
// index. ui-purge: all view glue + screenshot hooks removed; the new UI
// (docs/design/UI-SPEC.md) binds to the stores exposed here.
import AppKit
import Combine
import Foundation
import UserNotifications

/// f1-composer: one off-screen quick send (the open-target path goes
/// through ConversationStore instead, so its bubble/errors surface
/// there). Demo records locally; live failures land here (no toast —
/// the target timeline isn't open to own one).
public struct QuickSendRecord: Equatable {
    public let targetID: String
    public let targetName: String
    public let text: String
    public let failed: Bool
    public let error: String?
}

@MainActor
public final class AppState: ObservableObject {
    public let isDemo: Bool
    /// Blocked users (om-leave-block): shared by the chat list (row
    /// filter), Settings (Unblock), Diagnostics (count), and the live
    /// feed gate below. Demo runs memory-only (never the real defaults).
    /// Rebuilt per account on switch (d1-accounts).
    @Published public var blocked: BlockedStore
    /// Rebuilt per account on switch (d1-accounts; pins/folders/blocked
    /// are per-account namespaces).
    @Published public var chats: ChatListViewModel
    public let teams: TeamsViewModel
    public let reminders: RemindersViewModel
    public let planner: PlannerViewModel
    public let recordings: RecordingsViewModel
    public let transcripts: TranscriptsViewModel
    /// Unified Files surface (top10-files): chats + channels + drive
    /// recents in one list. Demo seeds canned rows; live loads from
    /// the chats/teams lists in openContentIfAllowed.
    public let unifiedFiles: UnifiedFilesStore
    public let meetings: MeetingsViewModel
    /// Calendar week grid backing the Meetings window (B1 merge).
    public let calWeek: CalendarWeekStore
    /// Shifts week grid backing the sidebar Shifts tab (B1 merge).
    public let shifts: ShiftsStore
    /// Contacts directory + speed dial (om-f2-contacts): the sidebar
    /// Contacts section searches through this store. Demo runs the
    /// offline people index; live hits Graph via core.
    public let contacts: ContactsStore
    public let conv = ConversationStore()
    /// Pop-out registry (e1-popout): visible chat ids + per-chat stores +
    /// draft cache, bound to the main store for send mirroring.
    /// Channels pop through this same registry (channel ids are
    /// conversation ids — gap-g8 entry only, no new store).
    public let popouts = PopOutStore()
    /// gap-g8: per-meeting pop-outs (visible keys + cached chat/roster
    /// stores + names + drafts).
    public let meetingPopouts: MeetingPopOutStore
    /// gap-g8: file-preview pop-outs (visible keys + snapshot cache).
    public let filePopouts = FilePopOutStore()
    /// Message search (om-ja-search): the jump palette's Messages scope
    /// searches through this store. Demo runs substring-over-fixtures
    /// (offline); live hits Graph via core.
    public let messageSearch: MessageSearchStore
    /// Offline message index (gap-g6g7): attached to `messageSearch`
    /// for offline-first merge. Fed by history fetches (`conv`
    /// onHistory) + realtime ingest; persists per-account OMIX.
    public let localSearch = LocalSearchStore()
    /// Settings ▸ Advanced ▸ Rebuild Index pass (progress + cancel).
    public let searchIndexRebuild = SearchIndexRebuild()
    /// Sticky palette search memory (gap-g6g7): scope chip + last
    /// query + 5 recents. Device-scoped (global, like picker flags).
    /// Demo: memory-only (never reads or writes the real recents).
    public let searchRecents: SearchRecentsStore
    /// Indexed doc count (Diagnostics; updated on every index write).
    @Published public var searchIndexDocs = 0
    /// Last index load/save failure (Diagnostics; nil when clear).
    @Published public var searchIndexError: String?
    /// Account whose file backs `localSearch` right now.
    private var searchIndexAccountID = AccountProfile.defaultID
    /// Debounced OMIX save (2s quiet window after each index write).
    private var searchIndexSaveTask: Task<Void, Never>?
    /// File + people search (om-jb-filesearch): the jump palette's
    /// Files/People sections search through this store. Demo runs
    /// substring-over-fixtures (offline); live hits Graph via core.
    public let filePeople: FilePeopleSearchStore
    public let shared = SharedFilesStore()
    /// Uploads + downloads (Files ▸ Downloads, Transfers popover; p3c).
    public let transfers: TransferStore
    public let feed = RealtimeFeed()
    /// gap-g1 2nd feed: REST sweep over inactive accounts (the live
    /// trouter serves the active profile only). Started with the feed in
    /// live mode; the App timer drives it (30s, ungated — it must fire
    /// while minimized, unlike the 2s visible-only tick).
    public let bgPoller = BackgroundAccountPoller()
    /// gap-g1 unified roll-up: background .notify counts per inactive
    /// account, drained into the live UnreadStore on switch.
    private var bgRollup = BackgroundUnreadRollup()
    public let typing = TypingStore()
    public let notifs: MessageNotifications
    /// e2-attention: system Focus sync (quiet source) + presence
    /// schedules (timetable-driven own status). The schedule adopts
    /// set-echoes into `presence` (weak) and pauses on manual picker
    /// sets via `presence.manualSetHook`. Init-assigned.
    public let quietHours: QuietHoursStore
    public let focusSync: FocusSyncStore
    public let presenceSchedule: PresenceScheduleStore
    /// top10-presence: status lock + activity truth + change log +
    /// devices. Init-assigned next to the schedule.
    public let presenceTruth: PresenceTruthStore
    /// d2-send: per-chat snooze expiries + the scheduled-send queue.
    public let snooze: SnoozeStore
    public let scheduled: ScheduledSendStore
    /// e2-canned: user-authored message templates (composer + Settings).
    public let canned: CannedResponsesStore
    // om-mention-alerts: the Mentions row count owns the Dock tile, so
    // unread counts stay sidebar-only here (per-chat badges + Diagnostics).
    public let unread = UnreadStore(dock: NullDockBadge())
    public let mentions = MentionStore()
    /// e1-activity: notification history + mentions-center data.
    public let activity: ActivityStore
    /// Open chat's roster + owner roles (core-a). Demo serves in-memory
    /// members. UI loads it per chat (`chatRoster.load(chatID:)`).
    public let chatRoster: ChatRosterStore
    public let receipts = ReceiptStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published public var pinnedMessages: PinnedMessageStore
    /// Cross-chat saved collection (e2-saved). Rebuilt per account on
    /// switch (d1-accounts) like pins.
    @Published public var savedMessages: SavedMessageStore
    public let auth = AuthViewModel()
    public let presence = PresenceStore()
    /// Ghost mode (f1-ghost): suppresses own read-receipt PUTs and
    /// presence writes while on (injected into receipts/presence/
    /// presenceSchedule below; toggles persist, counters clear out).
    public let ghost: GhostStore
    /// teams-frame FULL lifecycle (registry + pool + keep-alive + kill).
    public let teamsFrame: TeamsFrameStore
    /// Message density (f2-density): Comfortable/Compact preference.
    public let density: DensityStore
    public let call: CallStore
    /// Rebuilt per account on switch (d1-accounts).
    @Published public var history: CallHistoryStore
    public let meeting = MeetingRosterStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published public var meetingChat: MeetingChatStore
    /// Multi-account list + per-account VMs (d1-accounts). The `auth`
    /// VM above is the live gate object, repointed at the active
    /// profile on every switch (stable identity for all observers).
    /// Init-assigned (gap-g2): its profile flips serialize through
    /// `profileGate` below.
    public let accounts: AccountStore
    /// gap-g2: serializes every core-profile flip (switches, restore)
    /// against account-window flip-flop ops; records the active
    /// profile so flip-backs land on the CURRENT active.
    public let profileGate = AccountProfileGate()
    /// gap-g2: side-by-side account windows (visible set + cached
    /// per-account graphs).
    public let accountWindows = AccountWindowRegistry()
    /// gap-g2: last flip-flop gap-close (coalesces resyncs across
    /// rapid window ops — trailing gaps still close, ≤2s stale).
    private var lastWindowResync = Date.distantPast
    /// True between an account switch/add and its quiet reload landing
    /// (keeps the gate open across the `.unknown` repoint beat).
    @Published public var switchingAccount = false
    /// Screen-share owner, created on first A/V use (top10-menubar:
    /// no media objects at launch — the ScreenShareModel init notes
    /// into ColdStart, so the launch log proves zero).
    public lazy var screenShare = ScreenShareModel()
    /// Opt-in login item (top10-menubar: default off; Settings toggle).
    public let loginItems = LoginItemStore()
    public let notes = NotesStore()
    public let catchUp: CatchUpStore
    /// On-device action-items extraction (f1-actions).
    public let actionItems: ActionItemsStore
    @Published public var openChatID: String?
    @Published public var signedIn: Bool?
    @Published public var coreVersion = "?"
    @Published public var initCode: Int32 = -99
    @Published public var feedState: RealtimeFeed.State = .stopped
    @Published public var feedEvents = 0
    @Published public var feedResyncs = 0
    @Published public var feedPolls = 0
    @Published public var feedTyping = 0
    @Published public var feedRoster = 0
    @Published public var feedError: String?
    // om-mention-alerts: breakthrough/suppression counters (Diagnostics only).
    @Published public var mentionBreakthroughs = 0
    @Published public var mentionDNDSuppressions = 0
    @Published public var mentionQuietSuppressions = 0
    /// Rules notify/skip decisions this session + last reason
    /// (om-notif-live; Diagnostics window only).
    @Published public var notifPosted = 0
    @Published public var notifSkipped = 0
    @Published public var notifLastReason = ""
    /// gap-g1 background arrivals handled this session (inactive
    /// accounts; their banners count in notifPosted above).
    @Published public var bgEvents = 0
    /// Last off-screen quick send (demo record + live failure surface).
    @Published public var lastQuickSend: QuickSendRecord?
    /// Last selected chat id (launch restore; om-demo-select).
    private var persistedSelection: String? {
        get { storageDefaults.string(forKey: "selectedChatID") }
        set { storageDefaults.set(newValue, forKey: "selectedChatID") }
    }
    /// Backing defaults for every AppState-built store (core-b demo-leak
    /// sweep): `.standard` live; one in-memory `MemoryDefaults` in
    /// `--demo`, so demo never reads or writes a real key.
    public let storageDefaults: UserDefaults
    /// Scratch file for a demo-only file-backed store (process temp dir,
    /// per pid; never the real ~/.config file).
    nonisolated static func demoTempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterTeams-demo-\(ProcessInfo.processInfo.processIdentifier)-\(name)").path
    }

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    private var cancellables = Set<AnyCancellable>()
    /// Chat-list wiring (rebuilt with `chats` on account switch).
    private var chatsCancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
    /// gap-g1 sweep timer (30s, ungated — background accounts must
    /// banner while minimized, when the 2s tick stands down).
    private var bgTimer: Timer?
    private var started = false
    private var contentOpened = false
    // om-rules: notify/skip rules over the live feed (RulesStore loads
    // rules.json once; Settings mute edits apply live, no relaunch).
    // meetingDedup collapses meeting bursts; ownerMRI is learned async
    // (name backup covers the gap).
    private var meetingDedup = MeetingStartDedup()
    public let rules: RulesStore
    private var ownerMRI: String?

    public init(args: [String]) {
        // core-b demo-leak sweep: demo stores get in-memory defaults,
        // temp-dir files, a memory-only media cache and no keychain.
        let demo = args.contains("--demo")
        let store: UserDefaults = demo ? MemoryDefaults() : .standard
        storageDefaults = store
        transfers = TransferStore(defaults: store)
        if demo { RichMediaCache.memoryOnly = true }
        // Demo never posts through the system center (feed is off in
        // demo; the fake keeps the banner path in memory).
        notifs = MessageNotifications(backend: demo ? FakeNotificationCenter() : nil, defaults: store)
        snooze = SnoozeStore(defaults: store)
        scheduled = demo
            ? ScheduledSendStore(path: Self.demoTempPath("scheduled.json"))
            : ScheduledSendStore()
        canned = CannedResponsesStore(defaults: store)
        activity = ActivityStore(defaults: store)
        ghost = GhostStore(defaults: store)
        teamsFrame = TeamsFrameStore(defaults: store)
        density = DensityStore(defaults: store)
        history = CallHistoryStore(defaults: store)
        rules = demo ? RulesStore(path: Self.demoTempPath("rules.json")) : RulesStore()
        meetingChat = demo ? MeetingChatStore.memoryOnly() : MeetingChatStore()
        meetingPopouts = demo
            ? MeetingPopOutStore(makeChat: { MeetingChatStore.memoryOnly() })
            : MeetingPopOutStore()
        // gap-g2: every AccountStore profile flip serializes through
        // the gate (window flip-flop ops queue behind the same lock);
        // the gate seeds from the restored store (the one truth).
        accounts = AccountStore(defaults: store, profileSet: { [profileGate] id in
            try profileGate.setActive(id) { try RustCore.profileSet($0) }
        })
        profileGate.seed(accounts.activeID ?? AccountProfile.defaultID)
        // e2-attention: attention stores. `let`s without defaults must
        // land before any self use.
        quietHours = QuietHoursStore(defaults: store)
        // Demo never reads the system Focus assertions file.
        focusSync = demo
            ? FocusSyncStore(defaults: store, reader: { false })
            : FocusSyncStore()
        // Schedule adopts set-echoes into presence (weak).
        presenceSchedule = PresenceScheduleStore(defaults: store, presence: presence)
        presenceTruth = PresenceTruthStore(defaults: store, presence: presence)
        // Ghost (f1-ghost): one store gates all three outbound paths
        // (receipt sends, manual presence sets, scheduled sets).
        receipts.ghost = ghost
        presence.ghost = ghost
        presenceSchedule.ghost = ghost
        // top10-presence: truth auto-sets hold under ghost; the schedule
        // holds while a lock owns the status and reports its fires to
        // the truth log; idle logic yields to active schedule windows.
        presenceTruth.ghost = ghost
        presenceSchedule.externalHold = { [weak truth = presenceTruth] in
            truth?.isLocked() ?? false
        }
        presenceSchedule.onApplied = { [weak truth = presenceTruth] status in
            truth?.noteScheduledSet(status)
        }
        presenceTruth.scheduleActive = { [weak schedule = presenceSchedule] in
            schedule?.activeEntry() != nil
        }
        isDemo = demo
        // Demo never reads or writes the real saves or recents.
        savedMessages = isDemo ? SavedMessageStore(defaults: nil) : SavedMessageStore()
        searchRecents = isDemo ? SearchRecentsStore(defaults: nil) : SearchRecentsStore()
        call = CallStore(demo: isDemo)
        chatRoster = ChatRosterStore(demo: isDemo)
        actionItems = ActionItemsStore()
        pinnedMessages = PinnedMessageStore(defaults: store)
        if isDemo {
            // Demo builds: memory key store always, never the real
            // keychain (re-signed demo builds must not prompt); memory
            // config (never the real provider/legacy key, which the load
            // path deletes); canned transports (no network, no CLI).
            let canned = CatchUpCannedTransport(stub: DemoData.catchUpSummary)
            catchUp = CatchUpStore(
                transport: canned, cliTransport: canned, onDeviceTransport: canned,
                defaults: store, keyStore: CatchUpMemoryKeyStore())
        } else {
            catchUp = CatchUpStore()
        }
        if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            preselectID = args[i + 1]
        } else {
            preselectID = nil
        }
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count {
            preselectName = args[i + 1]
        } else {
            preselectName = nil
        }
        if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
            autoSay = args[i + 1]
        } else {
            autoSay = nil
        }
        let initialBlocked = isDemo ? BlockedStore(defaults: nil) : BlockedStore()
        blocked = initialBlocked
        messageSearch = isDemo
            ? MessageSearchStore(searcher: { query, _, _ in
                DemoData.messageSearchResponse(for: query)
            })
            : MessageSearchStore()
        // gap-g6g7: offline-first merge + index writer hooks. Demo
        // attaches too (demo threads index via showDemo; fixtures
        // merge above local extras the same way).
        messageSearch.local = localSearch
        searchIndexAccountID = accounts.activeID ?? AccountProfile.defaultID
        // Demo builds its index in memory from demo threads only: it
        // never reads (or, below, writes) the account's on-disk index.
        if !isDemo {
            do {
                try localSearch.loadDefault(for: searchIndexAccountID)
                searchIndexDocs = localSearch.docCount
            } catch {
                searchIndexError = "index load: \(error)"
            }
        }
        // (conv.onHistory/onDelete wire in wireSearchIndex below —
        // closures capture self, which isn't ready this early.)
        filePeople = isDemo
            ? FilePeopleSearchStore(
                fileSearcher: { query, _ in DemoData.fileSearchResponse(for: query) },
                peopleSearcher: { query, _ in DemoData.peopleSearchResponse(for: query) })
            : FilePeopleSearchStore()
        contacts = isDemo
            ? ContactsStore(peopleSearcher: { query, _ in
                DemoData.peopleSearchResponse(for: query)
            }, defaults: store)
            : ContactsStore()
        contacts.presence = presence
        if isDemo {
            // Speed Dial rows in demo (in-memory defaults, never persisted).
            for person in DemoData.speedDial { contacts.pin(person) }
        }
        let folderStore = FolderStore(defaults: store)
        var seedHistoryDemo = false
        if isDemo {
            let seed = DemoData.chatsResponse()
            chats = ChatListViewModel(
                fetcher: { _ in seed },
                pins: UserPinStore(defaults: store),
                leaver: { LeaveResponse(ok: true, chat_id: $0) },
                blocked: initialBlocked,
                folders: folderStore)
            // P2c: demo joins/creates stay in memory (never core).
            let teamsLedger = DemoTeams.Ledger()
            teams = TeamsViewModel(
                fetcher: { DemoTeams.response(ledger: teamsLedger) },
                creator: { _, name, _ in
                    ChannelCreateResponse(
                        ok: true,
                        channel: TeamChannel(
                            channelId: "demo-channel-\(name)", name: name))
                },
                joiner: { try DemoTeams.join($0, ledger: teamsLedger) },
                teamCreator: { name, _ in DemoTeams.create(name, ledger: teamsLedger) },
                publicSearcher: { DemoTeams.search($0, ledger: teamsLedger) })
            reminders = RemindersViewModel(
                listsFetcher: { DemoData.remindersResponse() },
                tasksFetcher: { DemoData.reminderTasksResponse(for: $0) },
                localEdits: true)
            planner = PlannerViewModel(
                teamsFetcher: { DemoData.teamsResponse() },
                plansFetcher: { PlannerDemo.plansResponse(for: $0) },
                bucketsFetcher: { PlannerDemo.bucketsResponse(for: $0) },
                tasksFetcher: { PlannerDemo.tasksResponse(for: $0) },
                membersFetcher: { DemoTeams.roster(teamID: $0) },
                localEdits: true)
            recordings = RecordingsViewModel(
                listFetcher: { RecordingsDemo.response() },
                searchFetcher: { RecordingsDemo.searchResponse(for: $0) },
                downloadFetcher: { _, _, _ in try DemoClip.url().path })
            transcripts = TranscriptsViewModel(
                listFetcher: { TranscriptsDemo.response() },
                searchFetcher: { TranscriptsDemo.searchResponse(for: $0) },
                downloadFetcher: { _, _, dest in
                    // Demo writes only under the temp dir: Save (dest in
                    // ~/Downloads) lands in temp too, never the real folder.
                    let tmp = FileManager.default.temporaryDirectory.path
                    let out = dest.hasPrefix(tmp) ? dest
                        : (tmp as NSString).appendingPathComponent((dest as NSString).lastPathComponent)
                    try TranscriptsDemo.sampleVTT.write(
                        toFile: out, atomically: true, encoding: .utf8)
                    return out
                },
                recordingLookup: Self.demoRecordingLookup(),
                actionItemsTransport: nil)
            // Unified files seed offline in openContentIfAllowed
            // (showDemo: no fetchers run in demo).
            unifiedFiles = UnifiedFilesStore()
            // Parse stays real (pure core, no network); the join runner
            // echoes an accepted signaling leg so the lobby flow runs.
            meetings = MeetingsViewModel(
                meetingsFetcher: { DemoData.meetingsResponse() },
                joinRunner: { DemoData.demoJoinResult(threadID: $0) },
                // Demo join-by-ID resolves in memory (never Graph).
                meetingIDResolver: { _, _ in DemoData.meetingIDResolution() })
            calWeek = CalendarWeekStore(
                weekFetcher: { _ in Self.calWeekDemoResponse() },
                localEdits: true)
            shifts = ShiftsStore(week: { ShiftsDemo.response(teamID: $0) },
                                 members: { DemoTeams.roster(teamID: $0) })
            presence.adoptOwn(DemoData.ownPresence())
            for (chatID, peer) in DemoData.peerPresence() {
                presence.adoptChatPeer(chatID: chatID, response: peer)
            }
            for peer in DemoData.contactPresence() {
                presence.adoptPeer(peer)
            }
            mentions.adopt(DemoData.mentionedChatIDs)
            activity.seedDemo() // canned feed (in-memory, offline)
            searchRecents.seedDemo(DemoData.searchRecents)
            // Offline search in demo: every demo thread is in the
            // (in-memory) on-device index from launch.
            for c in DemoData.chats {
                localSearch.index(chatID: c.id, messages: DemoData.messages(for: c.id))
            }
            seedHistoryDemo = true // applied after init (two-phase)
        } else {
            chats = ChatListViewModel(blocked: initialBlocked)
            teams = TeamsViewModel()
            reminders = RemindersViewModel()
            planner = PlannerViewModel(membersFetcher: { try RustCore.teamMembers(teamID: $0) })
            let liveRecordings = RecordingsViewModel()
            recordings = liveRecordings
            transcripts = TranscriptsViewModel(recordingLookup: { [weak liveRecordings] stem in
                liveRecordings?.items.first { TranscriptItem.stem(of: $0.name) == stem }
            })
            unifiedFiles = UnifiedFilesStore()
            meetings = MeetingsViewModel()
            calWeek = CalendarWeekStore()
            shifts = ShiftsStore(members: { try RustCore.teamMembers(teamID: $0) })
        }
        if seedHistoryDemo {
            history.seedDemo() // canned recents (in-memory, offline)
        }
        wireChats()
        wireSearchIndex() // gap-g6g7: history + delete → offline index
        // core-b: file search hits name their conversation from the
        // Files index (Graph drive search reports none).
        filePeople.sourceResolver = { [weak files = unifiedFiles] file in
            files?.resolveSource(file) ?? file
        }
        popouts.bind(main: conv) // e1-popout: send mirroring both ways
        // gap-g8: Shared-list changes push into popped file previews
        // (rename/move land in place; the preview never refetches).
        shared.$files
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in
                Task { @MainActor [weak self] in
                    guard let self, let chat = self.shared.chatID else { return }
                    _ = self.filePopouts.refresh(chatID: chat, files: files)
                }
            }
            .store(in: &cancellables)
        // e2-attention: manual picker sets pause the schedule until
        // the next window boundary (contract (i)). top10-presence chains
        // the truth note (echo labeled manual, idle disarmed). Weak.
        presence.manualSetHook = { [weak schedule = presenceSchedule, weak truth = presenceTruth] in
            schedule?.noteManualSet()
            truth?.noteManualSet()
        }
        // F6: shifts Retry with no seeded teams reloads the teams
        // list, then re-seeds when rows land (never strands .idle).
        shifts.reloadTeams = { [weak self] in
            Task { await self?.reloadTeamsForShifts() }
        }
        // Single reaction point for the gate: every auth transition
        // (gate, Settings, Auth window — same model) runs authChanged,
        // which flips the gate via the signedIn/contentOpened flags.
        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                Task { @MainActor [weak self] in self?.authChanged(s) }
            }
            .store(in: &cancellables)
        // om-s7-tickstorm: NO objectWillChange forwards — every surface
        // observes its store directly (Diagnostics sub-rows, call banner
        // incl. the auto-open trigger, sidebar, sheets, Settings), so a
        // store tick re-renders that surface only, never the root.
        // (Was: receipts/call/history/quietHours/chats forwards.)
        wireHistory()
        // e1-activity: reviewing the last mention for a chat clears
        // the MentionStore flag (shared review state, no orphans).
        activity.onMentionFlagsCleared = { [weak self] chatID in
            Task { @MainActor [weak self] in
                self?.mentions.markRead(chatID: chatID)
            }
        }
        call.$call
            .receive(on: DispatchQueue.main)
            .sink { [weak self] c in
                Task { @MainActor [weak self] in
                    self?.history.noteActiveCall(c)
                }
            }
            .store(in: &cancellables)
        // gap-g3: incoming rings bell the OS (live only — demo/shots
        // stay silent and banner-free). The hooks fire on the phase
        // machine's transitions; Notifier owns the banner itself.
        if !isDemo {
            // gap-g4: the ring respects the system output mute (a muted
            // speaker never starts the loop; the banner still posts).
            let ringer = CallRinger()
            ringer.mutedCheck = { SystemAudioMute.isOutputMuted() }
            call.ringer = ringer
            call.onIncomingRing = { info in
                let peer = info.displayPeer
                Notifier.shared.postCall(
                    title: peer.isEmpty ? "Unknown caller" : peer,
                    body: "Incoming call", callID: info.id)
            }
            call.onRingEnded = { id in
                Notifier.shared.withdrawCall(callID: id)
            }
        }
        // om-notif: banner click opens the chat; inline reply sends.
        // gap-g1: background banners carry their owning account — open
        // switches to it first, reply sends on it (never the active one).
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifOpenChat, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String else { return }
            let acct = note.userInfo?["accountID"] as? String
            Task { @MainActor [weak self] in
                self?.openFromNotification(chatID: id, accountID: acct)
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifReply, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String,
                  let text = note.userInfo?["text"] as? String
            else { return }
            let acct = note.userInfo?["accountID"] as? String
            Task { @MainActor [weak self] in
                self?.sendFromNotification(chatID: id, text: text, accountID: acct)
            }
        }
        // gap-g3: call-banner actions (Accept/Decline/click). Decline is
        // end() — CallStore counts an ended incoming ring as a decline.
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifAcceptCall, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.call.accept() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifDeclineCall, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.call.end() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifShowCall, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        }
        // top10-presence: screen lock/sleep feed activity truth (Away
        // while locked is legitimate — and now labeled as such).
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteSleep() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteWake() }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteScreenLock() }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteScreenUnlock() }
        }
        // d1-accounts: ordered switch stages (drain → flip → reset →
        // resume). Demo never switches (single canned identity).
        accounts.hooks = AccountSwitchHooks(
            drainRealtime: { [weak self] in self?.feed.stop() },
            resetForAccount: { [weak self] record in
                self?.resetStoresForAccount(record)
            },
            resume: { [weak self] in self?.repointAuthToActive() },
            removeCaches: { [weak self] record in
                AccountCaches.remove(accountID: record.id)
                // gap-g1: the removed account leaves the background
                // set (snapshot + roll-up stash dropped with it).
                self?.bgPoller.drop(accountID: record.id)
                self?.bgRollup.drop(accountID: record.id)
                // gap-g2: its window graph goes too (a live window
                // renders the removed placeholder).
                self?.accountWindows.drop(accountID: record.id)
            },
            emptied: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.auth.refreshStatus()
                }
            }
        )
        ColdStart.mark("appstate.init") // top10-menubar: launch timeline
    }

    /// Chat-list satellite wiring (local-remove fan-out + selection
    /// sink). Re-run after every `chats` rebuild (account switch).
    private func wireChats() {
        chatsCancellables = Set<AnyCancellable>()
        // om-leave-block: a locally-removed row drops its satellite
        // state (unread, mention flags) — never a list refresh.
        chats.onLocalRemove = { [weak self] id in
            self?.unread.markRead(chatID: id)
            self?.mentions.markRead(chatID: id)
        }
        chats.$selectedChatID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                Task { @MainActor [weak self] in self?.openSelected(id) }
            }
            .store(in: &chatsCancellables)
    }

    /// Offline-index writer wiring (gap-g6g7): fetched history
    /// batches + confirmed deletes flow into `localSearch`. The
    /// closures hop to MainActor (ConversationStore is unisolated).
    private func wireSearchIndex() {
        conv.onHistory = { [weak self] chatID, msgs in
            Task { @MainActor [weak self] in
                self?.indexHistory(chatID: chatID, messages: msgs)
            }
        }
        conv.onDelete = { [weak self] chatID, id in
            Task { @MainActor [weak self] in
                self?.dropIndexed(chatID: chatID, messageID: id)
            }
        }
    }

    /// Call-history redial wiring (re-run after rebuild).
    private func wireHistory() {
        history.onRedial = { [weak self] record in
            Task { @MainActor [weak self] in self?.redial(record) }
        }
        // e1-activity: missed calls land in the feed (re-wired per
        // account alongside redial — the store is rebuilt on switch).
        history.onRecord = { [weak self] record in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activity.noteCallRecord(
                    record,
                    chatName: self.chatNameOrNil(for: record.thread)
                        ?? record.displayName)
            }
        }
    }

    // MARK: - Accounts (d1-accounts)

    /// Live chat list for one account (per-account pins/folders/blocked
    /// namespaces; default keeps the legacy keys).
    private func makeChats(accountID: String, blocked: BlockedStore) -> ChatListViewModel {
        ChatListViewModel(
            blocked: blocked,
            folders: FolderStore(accountID: accountID))
    }

    /// Meeting chat for one account (per-account persistence namespace).
    private func makeMeetingChat(accountID: String) -> MeetingChatStore {
        MeetingChatStore(
            load: { MeetingChatStore.fileLoad(threadID: $0, for: accountID) },
            save: { MeetingChatStore.fileSave(threadID: $0, messages: $1, for: accountID) },
            delete: { MeetingChatStore.fileDelete(threadID: $0, for: accountID) })
    }

    /// Switch stage 3 (runs inside AccountStore.switchTo, after the core
    /// profile flips): rebuild per-account stores + drop every
    /// identity-bound row. Sync; actor-cache resets kick Tasks.
    private func resetStoresForAccount(_ record: AccountRecord) {
        let id = record.id
        openChatID = nil
        ownerMRI = nil
        conv.resetForAccount(displayName: record.displayName)
        chats.resetForAccount()
        let freshBlocked = isDemo
            ? BlockedStore(defaults: nil)
            : BlockedStore(key: BlockedStore.key(for: id))
        blocked = freshBlocked
        chats = makeChats(accountID: id, blocked: freshBlocked)
        wireChats()
        pinnedMessages = PinnedMessageStore(defaults: storageDefaults, key: PinnedMessages.key(for: id))
        savedMessages = isDemo
            ? SavedMessageStore(defaults: nil)
            : SavedMessageStore(key: SavedMessages.key(for: id))
        history = CallHistoryStore(defaults: storageDefaults, key: CallHistoryStore.key(for: id))
        wireHistory()
        meetingChat = makeMeetingChat(accountID: id)
        switchSearchIndex(to: id) // gap-g6g7: per-account offline index
        messageSearch.clear() // gap-g6g7: stale hits never cross accounts
        teams.resetForAccount()
        presence.clear()
        presenceSchedule.clearApplied() // e2-attention: drop applied state
        presenceTruth.clearSession() // top10-presence: drop lock/log/devices
        typing.clear()
        meeting.clear()
        unread.markAllRead()
        // gap-g1 switch handoff: arrivals accrued while this account was
        // inactive land in the live store, so the switch shows unread N.
        unread.ingestBackground(bgRollup.take(accountID: id))
        mentions.markAllRead()
        receipts.clear()
        ghost.clear() // f1-ghost: counters clear, toggles persist
        Task {
            await RichMediaCache.shared.resetForAccount(id)
            await LinkPreviewCache.shared.resetForAccount()
        }
    }

    /// Switch stage 4: rebind the live gate VM to the new active profile
    /// and re-read status (pure read; `.signedIn` lands the quiet
    /// reload via authChanged). Runs for switch + remove-active
    /// fallthrough.
    private func repointAuthToActive() {
        guard let id = accounts.activeID else { return }
        switchingAccount = true
        auth.repoint(profile: id)
        Task { await auth.refreshStatus() }
    }

    /// Switch accounts (switcher menu). No-op in demo, for the active
    /// id, and for unknown ids.
    public func switchAccount(to id: String) {
        guard !isDemo else { return }
        guard id != accounts.activeID else { return }
        guard accounts.accounts.contains(where: { $0.id == id }) else { return }
        accounts.switchTo(id)
    }

    /// Remove one account (Settings). The store runs drain → core
    /// sign-out → cache wipe; active removal falls through to the next
    /// account (or empties, which re-reads status → gate closes).
    public func removeAccount(_ id: String) {
        guard !isDemo else { return }
        accounts.removeAccount(id)
    }

    /// Finish an add-account sheet sign-in: resolve identity on the new
    /// profile, record + activate the account, re-stamp every store,
    /// and rebind the gate VM. Feed restarts via the quiet path.
    public func completePendingAdd(_ vm: AuthViewModel) {
        guard !isDemo else { return }
        Task {
            let profile = vm.profile
            let me = try? await Task.detached {
                try RustCore.whoami(profile: profile)
            }.value
            let name: String
            if let display = me?.display_name, !display.isEmpty {
                name = display
            } else {
                name = "Account \(accounts.accounts.count + 1)"
            }
            feed.stop()
            guard accounts.completeAdd(
                profile: profile, displayName: name,
                upn: me?.mail, userID: me?.id)
            else { return }
            guard let record = accounts.accounts.first(where: { $0.id == profile })
            else { return }
            resetStoresForAccount(record)
            repointAuthToActive()
        }
    }

    /// Adopt the legacy single-account session after upgrade (or a fresh
    /// first sign-in): the default profile becomes the first account.
    private func adoptLegacyAccount() async {
        guard accounts.accounts.isEmpty else { return }
        let me = try? await Task.detached { try RustCore.whoami() }.value
        let name: String
        if let display = me?.display_name, !display.isEmpty {
            name = display
        } else {
            name = "Account 1"
        }
        accounts.adoptLegacy(displayName: name, upn: me?.mail, userID: me?.id)
        accounts.refreshAll()
    }

    /// Post-switch reload without spinners: quiet list fetches (state
    /// only moves when rows land), presence + owner MRI re-resolve,
    /// background tab refreshes, then realtime resumes on the new
    /// profile (feed.start drains stale backlog silently).
    private func quietRefreshAfterSwitch() {
        Task {
            await chats.loadQuietly()
            await teams.loadQuietly()
            await presence.refreshOwn()
            resolveOwnerMRI()
            reminders.refresh()
            planner.refresh()
            recordings.refresh()
            transcripts.refresh()
            unifiedFiles.refresh()
            meetings.refresh()
            calWeek.refresh()
            if shifts.selectedTeamID == nil {
                seedShifts()
            } else {
                shifts.refresh()
            }
            if !isDemo {
                feed.start()
            }
            refreshFeedStatus()
        }
    }

    public func startup() async {
        guard !started else { return }
        started = true
        coreVersion = RustCore.version()
        initCode = RustCore.initialize()
        if isDemo {
            signedIn = true // demo bypasses the gate (offline canned data)
        } else {
            // d1-accounts: relaunch restores the last-active profile
            // BEFORE the status read (gate + whoami follow it).
            // gap-g2: routed through the gate (records + serializes;
            // no window op can exist yet, but the record must be true).
            if let active = accounts.activeID {
                _ = try? profileGate.setActive(active) {
                    try RustCore.profileSet($0)
                }
                auth.repoint(profile: active)
            }
            await auth.refreshStatus()
            signedIn = auth.isSignedIn
            accounts.refreshAll()
        }
        await openContentIfAllowed()
        // top10-menubar: launch timeline close + media-deferral proof.
        ColdStart.mark("startup.done")
        print("[coldstart] \(ColdStart.mediaInitReport())")
        fflush(stdout)
        if CommandLine.arguments.contains("--coldstart-quit") {
            // Proof hook: clean exit once the timeline lands (flushed).
            // Waits for the first chat open (join-ready) up to 30s —
            // the selection sink lands just after startup.done.
            Task {
                for _ in 0..<300 where !ColdStart.hasMarked("chat.first-open") {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                print("[coldstart] \(ColdStart.report().replacingOccurrences(of: "\n", with: " | "))")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    /// Post-gate: chats + restore + feed + autosay. Runs once, only when
    /// demo or signed in. authChanged(.signedIn) retries after the gate
    /// opens, so a gated launch defers everything (no unsigned core calls
    /// beyond the read-only status check).
    private func openContentIfAllowed() async {
        guard !contentOpened, isDemo || auth.state.allowsContent else { return }
        contentOpened = true
        await chats.load()
        await teams.load()
        await reminders.load()
        await planner.load()
        await recordings.load()
        await transcripts.load()
        // top10-files: unified Files surface. Demo seeds canned rows
        // offline; live fans out over recent chats + channels + drive
        // recents (specs capped in UnifiedFilesStore.specsFor).
        if isDemo {
            unifiedFiles.showDemo(
                specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
            transfers.seedDemo(DemoData.transferDemoItems())
        } else {
            let fileSpecs = UnifiedFilesStore.specsFor(chats: chats.chats, teams: teams.teams)
            unifiedFiles.load(
                chats: fileSpecs.filter { $0.kind == .chat }.map { ($0.id, $0.name) },
                channels: fileSpecs.filter { $0.kind == .channel }.map { ($0.id, $0.name) })
        }
        // top10-menubar: the meeting list loads on first Meetings-window
        // open (that scene already refresh()es on appear) — never on the
        // launch path.
        seedShifts() // team picker + first-week grid (demo + live)
        if chats.state == .loaded {
            // Core's signed_in is aad-centric; a loaded list proves
            // working auth regardless.
            signedIn = true
        }
        // Restore (om-demo-select): explicit --chat wins, else the last
        // selection — resolved against the loaded list, never blind. A
        // restored id absent from the list falls back to the first chat
        // (no direct open, no 404); demo threads never load outside the
        // demo flags.
        let action = SelectionRestore.resolve(
            explicit: preselectID, restored: persistedSelection,
            chats: chats.chats, isDemo: isDemo)
        if !isDemo, let stale = persistedSelection, DemoData.isDemoID(stale) {
            persistedSelection = nil // scrub pre-fix demo default
        }
        // A conversation the window already opened (route, Activity or
        // search jump) wins over the restored selection.
        switch action {
        case .select(let id) where openChatID == nil:
            chats.selectedChatID = id // sink opens it
        case .openDirect(let id) where openChatID == nil:
            open(chatID: id, chatName: preselectName)
        default:
            break
        }
        if !isDemo {
            presence.refreshOwnSoon() // own dot; non-critical on failure
            setupNotifier() // om-rules: banners for filtered live events
            resolveOwnerMRI() // async; name backup covers the gap
            feed.subscribe { [weak self] msg in
                Task { @MainActor [weak self] in self?.handleRealtime(msg) }
            }
            feed.onResync { [weak self] in
                Task { @MainActor [weak self] in self?.handleResync() }
            }
            feed.onCall { [weak self] ev in
                Task { @MainActor [weak self] in
                    self?.handleCall(ev)
                    self?.history.noteEvent(ev)
                }
            }
            feed.onTyping { [weak self] ev in
                Task { @MainActor [weak self] in self?.handleTyping(ev) }
            }
            feed.onRoster { [weak self] ev in
                Task { @MainActor [weak self] in self?.handleRoster(ev) }
            }
            // Single shared response delegate (routes both banner
            // families; installed after Notifier.setup so it wins).
            notifs.attach()
            await notifs.requestAuthorization()
            feed.start()
            // gap-g1: background sweep over inactive accounts (first
            // sweep seeds silently — no launch banner storm).
            startBackgroundPoll()
        }
        if let say = autoSay {
            if openChatID == nil, isDemo, let first = chats.chats.first {
                chats.selectedChatID = first.id
                open(chatID: first.id, chatName: first.name)
            }
            if openChatID != nil {
                conv.send(text: say)
            }
        }
        // The 2s tick runs in demo too (d2-send: the scheduled queue and
        // the snooze sweep are client-side in both modes; the tick
        // publishes nothing while idle, so demo stays still). Starts
        // after the open above so launch catch-up delivers into the
        // open chat (own-bubble) instead of racing it.
        refreshFeedStatus()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        ColdStart.mark("content.open") // top10-menubar: launch timeline
    }

    public func shutdown() {
        searchIndexRebuild.cancel()
        stateTimer?.invalidate()
        stateTimer = nil
        bgTimer?.invalidate()
        bgTimer = nil
        feed.stop()
    }

    /// Sidebar selection changed (nil = cleared).
    private func openSelected(_ id: String?) {
        guard let id else {
            openChatID = nil
            conv.close() // never show a dead thread behind the empty detail
            return
        }
        guard id != openChatID else {
            // Already open (direct --chat path): still republish so
            // selection-driven body reads (isGroup) refresh — there is
            // no chats forward anymore. Redundant sets only.
            objectWillChange.send()
            return
        }
        let name = chats.chat(id: id)?.name ?? preselectName
        open(chatID: id, chatName: name)
    }

    /// Teams browser: a channel opens as a conversation through the same
    /// path as chats (channel ids are conversation ids, ost TUI parity).
    public func openChannel(channelID id: String, channelName: String) {
        open(chatID: id, chatName: channelName)
    }

    // MARK: - Quick send (f1-composer)

    /// Post one quick message. Open target → the open ConversationStore
    /// (the optimistic own-bubble lands in the main-window timeline);
    /// off-screen target → direct core send (demo records locally).
    /// Never changes the selection, never refetches — zero-refresh.
    public func quickSend(targetID: String, targetName: String, text: String) {
        let body = CodeBlocks.sendBody(for: text)
        guard !body.isEmpty else { return }
        if QuickComposerRouting.sendThroughOpenStore(
            targetID: targetID, openChatID: conv.chatID)
        {
            conv.send(text: body)
            return
        }
        if isDemo {
            lastQuickSend = QuickSendRecord(
                targetID: targetID, targetName: targetName, text: body,
                failed: false, error: nil)
            return
        }
        Task {
            do {
                let (id, content) = (targetID, body)
                _ = try await Task.detached {
                    try RustCore.send(chatID: id, text: content)
                }.value
                self.lastQuickSend = QuickSendRecord(
                    targetID: targetID, targetName: targetName, text: body,
                    failed: false, error: nil)
            } catch {
                self.lastQuickSend = QuickSendRecord(
                    targetID: targetID, targetName: targetName, text: body,
                    failed: true, error: "\(error)")
            }
        }
    }

    /// Recents redial (om-call-history): re-place on the record's
    /// thread. No-op without a thread (incoming legs carry none) or
    /// while another call is active.
    public func redial(_ record: CallRecord) {
        let thread = record.thread.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return }
        guard !(call.call?.isActive ?? false) else { return }
        call.place(threadID: thread)
    }

    /// Jump palette: chats route through the sidebar selection (keeps the
    /// list highlight in sync); channels/teams open directly by id.
    public func jump(chatID id: String, chatName: String) {
        if chats.chats.contains(where: { $0.id == id }) {
            chats.selectedChatID = id // sink opens it (or already open)
            if openChatID == nil { open(chatID: id, chatName: chatName) }
        } else {
            open(chatID: id, chatName: chatName)
        }
    }

    /// Message-hit jump (om-ja-search): open the hit's conversation, then
    /// land on the bubble. Already-open threads seek in place (no
    /// reload); other threads open with the seek armed (bounded
    /// page-back, then the timeline jumps).
    public func jumpToMessage(_ hit: SearchHit) {
        if hit.chatID == openChatID {
            conv.seek(messageID: hit.messageID)
            return
        }
        pendingSeekMessageID = hit.messageID
        jump(chatID: hit.chatID, chatName: displayName(for: hit.chatID))
    }

    /// Activity-row jump (e1-activity): open the row's chat, land on
    /// the message via the search funnel. Chat-only targets (missed
    /// calls) open without a seek; blank chat ids no-op (never conjure).
    public func jumpToActivity(_ target: ActivityTarget) {
        guard target.canJump else { return }
        guard let messageID = target.messageID else {
            jump(
                chatID: target.chatID,
                chatName: displayName(for: target.chatID))
            return
        }
        jumpToMessage(SearchHit(
            messageID: messageID, chatID: target.chatID,
            sender: "", timestamp: "", preview: ""))
    }

    /// Sidebar + channel name for one conversation id (hit subtitles and
    /// jump headers share it). Unknown ids fall back to the generic label.
    public func displayName(for chatID: String) -> String {
        chatNameOrNil(for: chatID) ?? "Conversation"
    }

    /// Channel context for saves (e2-saved): the team/channel ids
    /// behind one chat id (nil pair for plain chats and unknown ids).
    public func savedContext(for chatID: String) -> (teamID: String?, channelID: String?) {
        for team in teams.teams {
            if team.channels.contains(where: { $0.id == chatID }) {
                return (team.id, chatID)
            }
        }
        return (nil, nil)
    }

    /// Saved-row jump (e2-saved): the standard message-hit funnel
    /// (open the chat + seek the bubble).
    public func jumpToSaved(_ hit: SearchHit) {
        jumpToMessage(hit)
    }

    /// Name for one conversation id, nil when unknown (palette hit
    /// subtitles omit the chat rather than print the generic label).
    public func chatNameOrNil(for chatID: String) -> String? {
        if let name = chats.chat(id: chatID)?.name { return name }
        for team in teams.teams {
            if let ch = team.channels.first(where: { $0.id == chatID }) {
                return "\(team.name) > #\(ch.name)"
            }
        }
        return nil
    }

    /// Pop-out entry (e1-popout): register the chat and return the window
    /// value for `openWindow(value:)` (re-pop refocuses — the registry
    /// enforces one window per id). Nil for blank ids. Popping marks the
    /// chat read (open-chat parity for unread + Mentions).
    public func popOut(chatID: String) -> String? {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        popouts.pop(chatID: id)
        unread.markRead(chatID: id) // open-chat parity: popped is visible
        mentions.markRead(chatID: id)
        return id
    }

    /// Pop-out window name: list/teams name, else the static demo name,
    /// else the id itself (--chat direct-open precedent for chats
    /// missing from the list). The demo fallback matches the main
    /// `open` path and covers windows opened before the list lands.
    public func popoutName(for chatID: String) -> String {
        chatNameOrNil(for: chatID)
            ?? (isDemo ? DemoData.name(for: chatID) : nil)
            ?? chatID
    }

    /// Open (once) a pop-out window's backing store: demo seeds canned
    /// messages, live loads through core. Cached per chat for the
    /// session — re-pop restores with no reload.
    public func openPopout(chatID: String) {
        let s = popouts.store(for: chatID)
        guard s.chatID != chatID else { return }
        if isDemo {
            s.showDemo(
                chatID: chatID, chatName: popoutName(for: chatID),
                messages: DemoData.messages(for: chatID),
                failed: DemoData.failedIDs(for: chatID))
        } else {
            s.open(chatID: chatID, chatName: popoutName(for: chatID))
        }
    }

    // MARK: - Meeting pop-outs (gap-g8)

    /// Pop a meeting: registers the key and returns the window value
    /// (re-pop refocuses — the registry enforces one window per key,
    /// and `openWindow(value:)` focuses the existing typed window).
    /// Nil for blank keys only.
    public func popOutMeeting(key: String, subject: String?) -> MeetingPopoutValue? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        meetingPopouts.pop(key: k, subject: subject)
        return MeetingPopoutValue(key: k)
    }

    /// Pop-out window name: pop-time subject, else the upcoming-row
    /// subject, else the live panel title (same thread), else the key
    /// itself (missing-from-list precedent).
    public func meetingPopoutName(for key: String) -> String {
        let cached = meetingPopouts.name(for: key)
        if cached != key { return cached }
        if let row = meetings.meetings.first(where: { $0.meetingId == key }) {
            return row.subject
        }
        if isDemo,
           let row = DemoData.meetings.first(where: { $0.meetingId == key })
        {
            return row.subject
        }
        if meetingChat.threadID == key { return meetingChat.headerTitle }
        return key
    }

    /// Open (once) a meeting pop-out's backing stores: demo seeds the
    /// canned thread + roster, live opens thread keys through core
    /// (calendar-id keys adopt their thread on first sight). Cached
    /// per key for the session — re-pop restores with no reload.
    public func openMeetingPopout(key: String) {
        let chat = meetingPopouts.chatStore(for: key)
        let roster = meetingPopouts.rosterStore(for: key)
        if roster.meetingID == nil {
            // Attribute roster frames to this key (exact-match
            // fan-out; harmless when core's meeting id differs — the
            // key match still routes).
            roster.adopt([], meetingID: key)
        }
        guard chat.threadID == nil else { return }
        if isDemo {
            chat.showDemo(
                threadID: MeetingSignal.isMeetingThread(key)
                    ? key : MeetingDemo.threadID,
                chatName: meetingPopoutName(for: key),
                messages: MeetingDemo.messages)
            chat.adoptIdentity(displayName: "Me")
            roster.seedDemo()
        } else if MeetingSignal.isMeetingThread(key) {
            chat.open(threadID: key, chatName: meetingPopoutName(for: key))
        }
        // Live calendar-id keys stay unclaimed until the first live
        // meeting-thread event adopts them (registry fan-out).
    }

    // MARK: - File pop-outs (gap-g8)

    /// Pop a file: registers the snapshot and returns the window value
    /// (re-pop refocuses — the registry refuses the dup and the typed
    /// value focuses the existing window). Nil for blank file ids only.
    public func popOutFile(chatID: String, file: SharedFile) -> FilePopoutValue? {
        if let v = filePopouts.pop(chatID: chatID, file: file) { return v }
        let fileID = file.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return nil }
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return FilePopoutValue(key: FilePopOutStore.key(chatID: chat, fileID: fileID))
    }

    /// Pop by composite key: rebuilds the snapshot
    /// from the live list or demo fixtures when the cache misses
    /// (restored windows), then returns the window value. Nil for
    /// blank keys or when no snapshot source resolves.
    public func popOutFileKey(_ key: String) -> FilePopoutValue? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        openFilePopout(key: k)
        guard filePopouts.entry(for: k) != nil else { return nil }
        return FilePopoutValue(key: k)
    }

    /// Open (once) a file pop-out's snapshot: the live Shared list
    /// wins when it shows the same chat, else demo fixtures resolve
    /// it (restored windows), else the pop-time snapshot stands —
    /// the preview never blanks under a refresh.
    public func openFilePopout(key: String) {
        let (chatID, fileID) = FilePopOutStore.split(key)
        guard !fileID.isEmpty else { return }
        if filePopouts.entry(for: key) == nil {
            let fresh: SharedFile?
            if shared.chatID == chatID, !chatID.isEmpty {
                fresh = shared.files.first { $0.id == fileID }
            } else if isDemo {
                fresh = DemoData.sharedFiles(for: chatID).first {
                    $0.id == fileID
                }
            } else {
                fresh = nil
            }
            if let fresh {
                _ = filePopouts.pop(chatID: chatID, file: fresh)
                return
            }
        }
        if shared.chatID == chatID, !chatID.isEmpty {
            _ = filePopouts.refresh(chatID: chatID, files: shared.files)
        } else if isDemo {
            _ = filePopouts.refresh(
                chatID: chatID,
                files: DemoData.sharedFiles(for: chatID))
        }
    }

    // MARK: - Account windows (gap-g2)

    /// Flip-flop runner: one blocking core op under an inactive
    /// account's profile. Pauses the live feed first (no trouter poll
    /// may START mid-flip — a wrong-profile poll would misattribute
    /// events), then gated flip → op → flip-back → resume. The
    /// resume's backlog drain is silent, so `onResumed` closes the
    /// gap (refetch open chat + list). Skips the pause entirely when
    /// the feed is already stopped (signed out).
    private struct AccountWindowRunner: AccountCoreRunner {
        let gate: AccountProfileGate
        let feed: RealtimeFeed
        let onResumed: @Sendable () -> Void

        func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
            let wasLive = feed.currentState != .stopped
            if wasLive { feed.stop() }
            defer {
                if wasLive {
                    feed.start()
                    onResumed()
                }
            }
            return try gate.run(under: accountID, op) {
                try RustCore.profileSet($0)
            }
        }
    }

    /// Build one window graph: per-profile list reads + stamped conv
    /// with the flip-flop runner. Demo runs the memory blocked store
    /// (never the real defaults — main-window reset parity).
    private func makeAccountGraph(for record: AccountRecord) -> AccountWindowGraph {
        let runner = AccountWindowRunner(
            gate: profileGate, feed: feed
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.noteWindowOpResumed() }
        }
        let blocked = isDemo
            ? BlockedStore(defaults: nil)
            : BlockedStore(key: BlockedStore.key(for: record.id))
        let chats = ChatListViewModel(
            fetcher: { [id = record.id] in
                try RustCore.chats(limit: $0, profile: id)
            },
            blocked: blocked,
            folders: FolderStore(accountID: record.id))
        return AccountWindowGraph(
            account: record, chats: chats, runner: runner)
    }

    /// Side-by-side entry (switcher "Open in New Window"): register
    /// the account window and return the window value for
    /// `openWindow(value:)` (re-open refocuses — the registry
    /// enforces one window per id). Nil for blank/unknown ids.
    public func openAccountWindow(accountID: String) -> String? {
        let id = accountID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard let record = accounts.accounts.first(where: { $0.id == id })
        else { return nil }
        accountWindows.open(accountID: id) { makeAccountGraph(for: record) }
        return id
    }

    /// Window closed: the graph's unread merges back into the
    /// background roll-up (a later switch still lands on unread N)
    /// and drains locally (never double-counted); the graph itself
    /// stays cached — re-open restores selection, bubbles, and pins
    /// with no reload.
    public func closeAccountWindow(accountID: String) {
        if let g = accountWindows.graph(for: accountID) {
            bgRollup.ingest(g.unread.counts, for: accountID)
            g.unread.markAllRead()
        }
        accountWindows.close(accountID: accountID)
    }

    /// Flip-flop gap-close (coalesced): the pause's silent drain may
    /// have swallowed live events, so re-fetch the open chat + list.
    /// Leading-edge 2s throttle across rapid window ops.
    private func noteWindowOpResumed() {
        let now = Date()
        guard now.timeIntervalSince(lastWindowResync) > 2 else { return }
        lastWindowResync = now
        handleResync()
    }

    /// Armed message seek (om-ja-search): `jumpToMessage` sets it, `open`
    /// consumes it (even on the guard exits, so a refused open never
    /// leaks a stale seek into the next open).
    private var pendingSeekMessageID: String?

    /// File-hit pick (om-jb-filesearch): open the SharePoint page in
    /// the default browser (https only; hits without a URL no-op).
    public func openSearchFile(_ file: SharedFile) {
        guard let raw = file.web_url, let url = URL(string: raw),
            url.scheme == "https",
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            comps.host != nil
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Person-hit pick (om-lt5-person11): open the 1:1 chat with the
    /// picked person. Demo opens a canned thread; live creates (or
    /// re-opens) via core off-main, then opens. Hits without a user
    /// ref, and failed creates, fall back to the v1 behavior (copy
    /// the work email to the clipboard).
    public func openSearchPerson(_ person: TeamMember) {
        guard let ref = PersonChat.userRef(for: person) else {
            copyEmail(person.email)
            return
        }
        if isDemo {
            jump(
                chatID: PersonChat.demoChatID(for: person),
                chatName: person.displayName)
            return
        }
        let name = person.displayName
        let email = person.email
        Task { @MainActor [weak self] in
            let created: ChatCreateResponse? = try? await Task.detached {
                try RustCore.chatCreateOneToOne(user: ref)
            }.value
            guard let self, let chat = created?.chat else {
                self?.copyEmail(email)
                return
            }
            self.jump(chatID: chat.chatId, chatName: name)
        }
    }

    /// Pinned-channel store for one account key (core-b; local only, see
    /// PinnedChannels.swift). Demo = memory only, never the real key.
    public func pinnedChannelStore(accountKey: String) -> PinnedChannelStore {
        PinnedChannelStore(accountKey: accountKey, defaults: isDemo ? nil : .standard)
    }

    /// Signed-in user's Graph id for id-based owner checks (core-a):
    /// active account id, else the learned owner MRI's object id. Demo
    /// is the canned `demo-u-me`. Nil until known (checks fail closed).
    public var ownUserID: String? {
        if isDemo { return "demo-u-me" }
        if let id = accounts.activeAccount?.userID, !id.isEmpty { return id }
        return resolvedOwnerMRI.flatMap(Mri.oid(from:))
    }

    /// New chat with one or more people (core-a G5). One person and no
    /// topic opens (or re-opens) the 1:1 via `openSearchPerson`; two or
    /// more people, or any topic, create a group chat via core and open
    /// it. Demo opens an in-memory thread (no core, no real data).
    /// Returns false when nothing could be started (no user refs, or
    /// the create failed — `newChatError` carries the reason).
    @discardableResult
    public func openNewChat(people: [TeamMember], topic: String? = nil) async -> Bool {
        let refs = GroupChat.userRefs(for: people)
        let cleanTopic = GroupChat.cleanTopic(topic)
        newChatError = nil
        guard !refs.isEmpty else {
            newChatError = "No one to add."
            return false
        }
        if refs.count == 1, cleanTopic == nil, let person = people.first(where: { PersonChat.userRef(for: $0) != nil }) {
            openSearchPerson(person)
            return true
        }
        let name = cleanTopic ?? GroupChat.defaultName(for: people)
        if isDemo {
            jump(chatID: GroupChat.demoChatID(refs: refs, topic: cleanTopic), chatName: name)
            return true
        }
        do {
            let created = try await Task.detached {
                try RustCore.chatCreateGroup(users: refs, topic: cleanTopic)
            }.value
            jump(chatID: created.chat.chatId, chatName: created.chat.name.isEmpty ? name : created.chat.name)
            return true
        } catch {
            newChatError = "Couldn't start the group chat: \(error)"
            return false
        }
    }

    /// Last `openNewChat` failure (nil after success or a new attempt).
    @Published public private(set) var newChatError: String?

    /// Create-chat-then-call (core-c; New Call with people who have no
    /// chat yet): resolve or create the chat for `people` (one person →
    /// their 1:1, two or more → a new group chat; `CallTargetResolver`),
    /// then place a live call on it (`call.placeLive`, every member
    /// rings). `willPlace` runs on the main actor with the resolved target
    /// just before dialing, so the host can present the call (e.g.
    /// `beginCall(.person(name:thread:))`); returning false aborts without
    /// dialing. Refuses while a call runs. Demo resolves in-memory ids and
    /// dials the demo call slot. Nil on failure (`startCallError`) or abort.
    @discardableResult
    public func startCall(
        with people: [TeamMember],
        willPlace: ((CallTarget) -> Bool)? = nil
    ) async -> CallTarget? {
        startCallError = nil
        if call.call?.isActive == true {
            startCallError = "A call is already in progress."
            return nil
        }
        let target: CallTarget
        do {
            target = try await CallTargetResolver.resolve(people: people, demo: isDemo)
        } catch CallTargetResolver.Failure.noOne {
            startCallError = "No one to call."
            return nil
        } catch {
            startCallError = "Couldn't start the call: \(error)"
            return nil
        }
        // The create may have raced another call start.
        if call.call?.isActive == true {
            startCallError = "A call is already in progress."
            return nil
        }
        if let willPlace, !willPlace(target) { return nil }
        call.placeLive(threadID: target.threadID)
        return target
    }

    /// Last `startCall(with:)` failure (nil after success or a new attempt).
    @Published public private(set) var startCallError: String?

    /// v1 fallback: copy one work email (hits without an email no-op).
    private func copyEmail(_ email: String?) {
        guard let email, !email.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
    }

    private func open(chatID id: String, chatName: String?) {
        let seek = pendingSeekMessageID
        pendingSeekMessageID = nil
        // Demo threads never load outside the demo flags (a stale
        // demo-react default 404d the installed build); demo
        // selections never reach shared defaults either.
        guard isDemo || !DemoData.isDemoID(id) else { return }
        // Blocked threads never open (jump/direct paths fail closed).
        guard !blocked.isBlocked(chatID: id) else { return }
        openChatID = id
        // top10-menubar: join-ready = first chat open (one-shot).
        if !ColdStart.hasMarked("chat.first-open") {
            ColdStart.mark("chat.first-open")
        }
        if SelectionRestore.shouldPersist(chatID: id) {
            persistedSelection = id
        }
        unread.markRead(chatID: id) // om-notifbadge + om-markunread: opening marks read (counts + horizon override)
        mentions.markRead(chatID: id) // om-mentions: opening clears the flag
        activity.markChatReviewed(chatID: id) // e1-activity: opening reviews the feed rows
        if isDemo {
            // om-receipts: demo peers read through the tail (offline Seen).
            if let last = DemoData.messages(for: id).last {
                receipts.adopt(threadID: id, peers: ["demo-peer": last.id])
                receipts.noteSent(chatID: id, messageID: last.id)
            }
            let name = chatName ?? DemoData.name(for: id) ?? "Conversation"
            conv.showDemo(
                chatID: id, chatName: name, messages: DemoData.messages(for: id),
                failed: DemoData.failedIDs(for: id))
            // Message-hit jump (om-ja-search): demo threads load
            // synchronously, so the seek lands in-memory (no paging).
            if let seek { conv.seek(messageID: seek) }
            notes.showDemo()
            shared.showDemo(chatID: id, files: DemoData.sharedFiles(for: id))
        } else {
            conv.open(chatID: id, chatName: chatName, seekMessageID: seek)
            // Notes scope: channels read the team (M365 group) notebook;
            // plain chats read the user's own OneNote (no shared notebook).
            notes.open(groupID: teamID(forChannel: id))
            // om-fix-tabs: prefetch Shared on open (cached rows make the
            // tab switch instant); the store skips when already current.
            if shared.chatID != id {
                shared.open(chatID: id)
            }
            // om-receipts: peer positions for Seen state (no list refresh).
            receipts.refresh(threadID: id)
        }
        // d2-send: opening a chat delivers its past-due queue items into
        // it (own-bubbles); claim-then-send keeps this idempotent with
        // the tick.
        fireScheduled()
    }

    /// Team id owning a channel id, or nil for plain chats/unknown ids.
    public func teamID(forChannel channelID: String) -> String? {
        teams.teams.first(where: { team in
            team.channels.contains(where: { $0.id == channelID })
        })?.teamId
    }

    /// One live event: count it, refresh the list row (all chats),
    /// route the bubble to the open chat only. 1:1 chats also learn
    /// the mate's sender MRI for live presence dots (own messages
    /// and group chats skipped — same sender==name identity rule as
    /// ConversationStore).
    /// One typing event: count it, refresh that sender's per-thread
    /// timeout. Never touches the chat list (no refresh — the timeline
    /// row is the only surface); own typing echoes are skipped.
    private func handleTyping(_ ev: TypingEvent) {
        feedTyping += 1
        if ev.sender != conv.ownDisplayName {
            typing.ingest(ev)
        }
    }

    /// One roster snapshot: count it, upsert the row in place. Never
    /// touches the chat list (no refresh — the roster is the only
    /// surface); own rows are kept (self is a participant too).
    private func handleRoster(_ ev: MeetingRosterEvent) {
        feedRoster += 1
        meeting.ingest(ev)
        // gap-g8: popped meetings take their own roster frames.
        _ = meetingPopouts.ingest(roster: ev)
    }

    /// Call events land in the call slot; a remote end also closes the
    /// meeting (the thread stays persisted, roster speaking clears).
    private func handleCall(_ ev: CallEvent) {
        call.ingest(ev)
        if ev.kind == "end" || ev.kind == "rejected" {
            meetingChat.endMeeting()
            meeting.noteMeetingEnded()
        }
    }

    // MARK: - Offline search index (gap-g6g7)

    /// Index one history batch (conv.onHistory: open/seek/loadMore/demo).
    private func indexHistory(chatID: String, messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        localSearch.index(chatID: chatID, messages: messages)
        searchIndexRebuild.noteIndexed(chatID: chatID, messages: messages)
        searchIndexDocs = localSearch.docCount
        searchIndexError = nil
        scheduleSearchIndexSave()
    }

    /// Drop one doc after a confirmed delete (conv.onDelete).
    private func dropIndexed(chatID: String, messageID: String) {
        localSearch.remove(chatID: chatID, messageID: messageID)
        searchIndexRebuild.noteRemoved(chatID: chatID, messageID: messageID)
        searchIndexDocs = localSearch.docCount
        scheduleSearchIndexSave()
    }

    /// Settings ▸ Advanced ▸ Rebuild Offline Index: re-index every chat
    /// and channel stored on this Mac (the index's own docs; the open
    /// conversation's loaded messages win over their stored copies) in a
    /// background pass, then swap the fresh index in and save it. Search
    /// answers from the old index until then; cancel (quit, account
    /// switch) leaves it untouched. No-op in demo.
    public func rebuildSearchIndex() {
        guard !isDemo else { return }
        var threads = localSearch.cachedThreads()
        if let id = conv.chatID, !conv.messages.isEmpty {
            let open = Set(conv.messages.map(\.id))
            if let i = threads.firstIndex(where: { $0.chatID == id }) {
                threads[i].messages = threads[i].messages.filter { !open.contains($0.id) } + conv.messages
            } else {
                threads.append(.init(chatID: id, messages: conv.messages))
            }
        }
        let accountID = searchIndexAccountID
        searchIndexRebuild.start(threads: threads) { [weak self] fresh in
            guard let self, self.searchIndexAccountID == accountID else { return .cancelled }
            self.searchIndexSaveTask?.cancel()
            self.searchIndexSaveTask = nil
            self.localSearch.adopt(fresh)
            self.searchIndexDocs = self.localSearch.docCount
            do {
                try self.localSearch.saveDefault(for: accountID)
                self.searchIndexError = nil
                return .finished(docs: self.searchIndexDocs)
            } catch {
                self.searchIndexError = "index save: \(error)"
                return .failed("\(error)")
            }
        }
    }

    /// Settings ▸ Advanced ▸ Reset Caches: the media cache (memory and
    /// this account's files). No-op in demo.
    public func resetCaches() async {
        guard !isDemo else { return }
        await RichMediaCache.shared.removeAll()
    }

    /// Debounced OMIX persist (2s quiet window; cancels superseded).
    private func scheduleSearchIndexSave() {
        guard !isDemo else { return }
        searchIndexSaveTask?.cancel()
        let accountID = searchIndexAccountID
        searchIndexSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                try self?.localSearch.saveDefault(for: accountID)
            } catch {
                self?.searchIndexError = "index save: \(error)"
            }
        }
    }

    /// Flush the old account's index, then point the store at the new
    /// account's file (empty when the account never indexed).
    private func switchSearchIndex(to accountID: String) {
        searchIndexRebuild.cancel()
        searchIndexSaveTask?.cancel()
        searchIndexSaveTask = nil
        do {
            try localSearch.saveDefault(for: searchIndexAccountID)
        } catch {
            searchIndexError = "index save: \(error)"
        }
        searchIndexAccountID = accountID
        localSearch.removeAll()
        do {
            try localSearch.loadDefault(for: accountID)
            searchIndexError = nil
        } catch {
            searchIndexError = "index load: \(error)"
        }
        searchIndexDocs = localSearch.docCount
    }

    private func handleRealtime(_ msg: RealtimeMessage) {
        feedEvents += 1
        refreshFeedStatus()
        // om-leave-block: blocked senders skip everything (list, typing,
        // unread, mentions, banners) — counted as a skip in Diagnostics.
        // Unknown threads default to 1:1, so a new thread from a blocked
        // mate still matches by name.
        let threadGroup = chats.chat(id: msg.chatID)?.is_group ?? false
        if blocked.isBlocked(chatID: msg.chatID, senderName: msg.sender, isGroup: threadGroup) {
            notifSkipped += 1
            notifLastReason = "blocked-user"
            return
        }
        typing.noteMessage(
            chatID: msg.chatID, sender: msg.sender, senderID: msg.senderID)
        chats.ingest(realtime: msg)
        // gap-g6g7: realtime → offline index (edits re-index onto the
        // same doc; reaction-only events carry no text — never index
        // an empty body over real content).
        if !msg.text.isEmpty {
            indexHistory(chatID: msg.chatID, messages: [msg.asChatMessage])
        }
        // om-nc-delivery: the rules decision below owns the single banner
        // (maybeNotify); no second post here — one event, one banner max.
        // om-quiet-hours: snapshot quiet ONCE per event; the banner path
        // below obeys it (banners/sounds drop; unread pauses too —
        // quiet-hours skips never accrue). e2-attention: Focus-quiet
        // folds into the same snapshot (identical semantics, same reason).
        let quiet = localQuietNow
        if let mri = msg.senderID,
           msg.sender != conv.ownDisplayName,
           chats.chat(id: msg.chatID)?.is_group == false
        {
            Task { await presence.refreshChatPeerMri(chatID: msg.chatID, mri: mri) }
        }
        // om-rules + om-notifbadge + om-mention-alerts: ONE rules decision
        // per event (presence-DND, then local quiet, then mute-with-
        // breakthrough) drives the banner (all chats, open one included
        // — TN parity), the unread counts (skips and the open chat never
        // accrue), and the alert stats. Quiet ALSO gates the banner path
        // below (defense in depth + suppressed counting).
        let chatName = chats.chat(id: msg.chatID)?.name ?? ""
        let decision = rulesDecision(for: msg, chatName: chatName)
        noteAlertStats(decision: decision)
        switch decision {
        case .notify(let reason):
            notifPosted += 1
            notifLastReason = reason
        case .skip(let reason):
            notifSkipped += 1
            notifLastReason = reason
        }
        // e1-popout: popped chats count as open (no unread/mention
        // accrual while visible); banners below still fire for them.
        let visible = popouts.visibleChatIDs(open: openChatID)
        unread.ingest(
            decision: decision, chatID: msg.chatID, openChatID: openChatID,
            visibleChatIDs: visible)
        mentions.ingest(
            realtime: msg, ownName: conv.ownDisplayName,
            ownerMRI: resolvedOwnerMRI, openChatID: openChatID,
            visibleChatIDs: visible)
        // e1-activity: mentions/replies land in the feed (same gates as
        // the MentionStore flags, plus channel blasts + quote replies).
        activity.ingest(
            realtime: msg, ownName: conv.ownDisplayName,
            ownerMRI: resolvedOwnerMRI, openChatID: openChatID,
            chatName: chatName, visibleChatIDs: visible)
        // e1-activity: reaction totals ride in for the count-delta
        // heuristic. Ownership resolves only for loaded open-chat
        // bubbles (unknown ownership baselines without emitting); the
        // pre-ingest bubble seeds the baseline so the delta is exact.
        if let r = msg.reactions {
            let targetID = msg.isEdit ? (msg.editedID ?? msg.msgId) : msg.msgId
            var own: Bool?
            if msg.isFor(chatID: openChatID),
               let bubble = conv.messages.first(where: { $0.id == targetID })
            {
                activity.seedBaseline(
                    chatID: msg.chatID, messageID: targetID,
                    total: bubble.reactions.reduce(0) { $0 + $1.count })
                own = bubble.isOwn
            }
            activity.noteReaction(
                chatID: msg.chatID, messageID: targetID, reactions: r,
                chatName: chatName, isOwnMessage: own)
        }
        if quiet {
            noteSuppressedIfWarranted(msg, chatName: chatName, decision: decision)
        } else {
            maybeNotify(
                msg, chatName: chatName, decision: decision,
                mutedChatIDs: rules.config.mutedChatIDs)
        }
        // om-meet-chat: meeting-thread events adopt the meeting panel
        // (any meeting thread, not just the open chat). The panel owns
        // its thread; the chat list is untouched by this path.
        meetingChat.ingestIfMeeting(realtime: msg)
        // e1-popout: the main timeline takes its chat; every popped chat
        // takes its own — the main selection never moves for pop-out
        // traffic, and popped threads refresh Seen like open ones.
        let seenWorthy = !msg.isEdit && !msg.text.isEmpty
        if msg.isFor(chatID: openChatID) {
            conv.ingest(realtime: msg)
            // om-receipts: a peer reply implies they read through our tail;
            // refresh Seen state (no list refresh — receipts only).
            if seenWorthy {
                receipts.refresh(threadID: msg.chatID)
            }
        }
        if popouts.ingest(realtime: msg), seenWorthy {
            receipts.refresh(threadID: msg.chatID)
        }
        // gap-g8: every popped meeting takes its own thread — the main
        // panel and the main selection never move for pop-out traffic.
        if meetingPopouts.ingest(realtime: msg), seenWorthy {
            receipts.refresh(threadID: msg.chatID)
        }
        // gap-g2 fan-out (live leg): a window open on the event's
        // account takes it too (live events stamp nil = active; the
        // registry resolves that). Same decision — never re-decided.
        _ = accountWindows.ingest(
            msg, decision: decision, activeID: accounts.activeID)
    }

    /// Owner MRI for live-event matching: configured value wins, else
    /// the Graph-learned one (nil until it lands — the display-name
    /// backup covers the gap). Shared by the rules decision and the
    /// mention tracker so both gates see the same identity.
    private var resolvedOwnerMRI: String? {
        rules.config.owner.mri.isEmpty ? ownerMRI : rules.config.owner.mri
    }

    /// Local quiet snapshot (e2-attention): schedule/DND-quiet OR
    /// Focus-quiet — identical semantics downstream (same snapshot fed
    /// to the banner gate and the rules quiet gate, same reason).
    private var localQuietNow: Bool {
        quietHours.isQuietNow || focusSync.quietNow
    }

    /// One rules decision for a live event (owns the meeting-start
    /// window claim). Owner identity prefers configured/learned MRI with
    /// a live display-name backup. DND reads the own Teams presence;
    /// quiet reads the local snapshot (schedule, manual DND, or Focus —
    /// all suppress mentions too).
    private func rulesDecision(for msg: RealtimeMessage, chatName: String) -> ChatFilter.Decision {
        var cfg = rules.config
        if let own = conv.ownDisplayName, !own.isEmpty { cfg.owner.displayName = own }
        return ChatFilter.decide(
            message: msg, chatDisplayName: chatName, ownerMRI: resolvedOwnerMRI,
            rules: cfg, meetingDedup: &meetingDedup, now: Date(),
            dndActive: MentionAlert.isDND(ownAvailability: presence.own?.availability),
            quietActive: localQuietNow,
            snoozedChatIDs: snooze.activeIDs())
    }

    /// Mention-alert counters (Diagnostics only): breakthroughs through
    /// mute, DND suppressions, quiet-hours suppressions.
    private func noteAlertStats(decision: ChatFilter.Decision) {
        switch decision {
        case .notify(let reason) where reason == MentionAlert.breakthroughReason:
            mentionBreakthroughs += 1
        case .skip(let reason) where reason == MentionAlert.dndReason:
            mentionDNDSuppressions += 1
        case .skip(let reason) where reason == MentionAlert.quietReason:
            mentionQuietSuppressions += 1
        default:
            break
        }
    }

    /// Quiet-held event (om-quiet-hours): count ONE suppression when a
    /// banner would otherwise have posted — rules .notify and/or the
    /// legacy non-open-chat path. Rules already decided above; this only
    /// records that quiet held the banner back (counted once per event).
    private func noteSuppressedIfWarranted(_ msg: RealtimeMessage, chatName: String, decision: ChatFilter.Decision) {
        let rulesNotified: Bool
        if case .notify = decision {
            rulesNotified = true
        } else {
            rulesNotified = false
        }
        // Same pure gate the legacy banner path uses ("" reads as unnamed,
        // exactly like the nil the Task passes when the chat is unknown).
        let legacyWouldPost = MessageNotifications.makeNotification(
            for: msg, chatName: chatName,
            openChatID: openChatID, ownDisplayName: conv.ownDisplayName) != nil
        if QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: notifs.enabled,
            rulesNotified: rulesNotified, legacyWouldPost: legacyWouldPost)
        {
            quietHours.noteSuppressed()
        }
    }

    /// Rules-based banner for one live event (om-nc-delivery: the rules
    /// decision maps to a banner via NcDelivery — skips suppress, meeting
    /// signals synthesize their body, locked screens redact). Posts through
    /// Notifier (thread-grouped, inline Reply). Respects the Settings
    /// banner toggle (om-settings-trim) so OFF is really off, the per-chat
    /// mute set (defense in depth — the rules engine already skips muted
    /// chats), the snooze set (same), and the preview/sound toggles via
    /// the one banner home.
    /// Quiet hours/DND gate the call (never reach here while quiet).
    /// Breakthrough mentions and keyword hits post elevated (OM_MENTION
    /// style + subtitle).
    /// gap-g1: background calls pass the owning account (banner names
    /// it, userInfo routes to it) plus the snapshot owner identity for
    /// the breakthrough subtitle. Live calls omit all four (nil = active
    /// account, live conv identity — unchanged behavior).
    private func maybeNotify(
        _ msg: RealtimeMessage, chatName: String,
        decision: ChatFilter.Decision, mutedChatIDs: Set<String>,
        accountID: String? = nil, accountName: String? = nil,
        ownerDisplayName: String? = nil, ownerMRI: String? = nil
    ) {
        guard notifs.enabled else { return }
        guard !mutedChatIDs.contains(msg.chatID) else { return }
        guard !snooze.isSnoozed(chatID: msg.chatID) else { return }
        guard case .notify(let reason) = decision else { return }
        // d2-alerts: keyword hits elevate like breakthrough mentions
        // (OM_MENTION style family, "Keyword alert" subtitle).
        let keyword = KeywordAlert.elevation(forReason: reason)
        let breakthrough = reason == MentionAlert.breakthroughReason || keyword.isElevated
        var subtitle: String? = keyword.subtitle
        if reason == MentionAlert.breakthroughReason {
            // Same identity the decision used (live name wins, per-chat
            // gates resolve identically — pure, no extra window claim).
            // Background calls pass the snapshot identity instead.
            var cfg = rules.config
            if let own = (ownerDisplayName ?? conv.ownDisplayName), !own.isEmpty {
                cfg.owner.displayName = own
            }
            let eff = cfg.effective(forChat: chatName)
            let mined = msg.mentions
            let ownerHit = Mentions.mentionsOwner(
                mined, ownerMRI: ownerMRI ?? resolvedOwnerMRI,
                ownerDisplayName: eff.ownerDisplayName,
                matchByName: eff.matchByDisplayName)
            subtitle = MentionAlert.subtitle(
                ownerMention: ownerHit,
                channelMention: Mentions.mentionsChannelOrEveryone(mined))
        }
        guard let banner = NcDelivery.makeBanner(
            for: msg, chatName: chatName,
            decision: decision, screenLocked: NcDelivery.isScreenLocked(),
            showPreview: notifs.showPreview, sound: notifs.sound,
            isMention: breakthrough, subtitle: subtitle,
            accountName: accountName)
        else { return }
        Notifier.shared.post(
            title: banner.title, body: banner.body,
            id: banner.id.isEmpty ? nil : banner.id, chatID: banner.chatID,
            sound: banner.sound, isMention: banner.isMention, subtitle: banner.subtitle,
            accountID: accountID)
    }

    /// Wire the notifier: categories + auth for rules-posted banners.
    /// The shared delegate (notifs.attach, installed after this) owns
    /// response routing via .omNotifOpenChat/.omNotifReply; these
    /// closures still carry the real send/jump (and select the
    /// Reply-bearing category) so banners stay actionable if install
    /// order ever flips Notifier's own delegate back on.
    /// Live mode only (demo never starts the feed, so never notifies).
    private func setupNotifier() {
        Notifier.shared.setup()
        Notifier.shared.onOpenChat = { [weak self] chatID, accountID in
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.openFromNotification(chatID: chatID, accountID: accountID)
            }
        }
        // gap-g1: a foreign-account reply switches first (on-main),
        // then sends on the delegate queue (blocking, ex-main) — the
        // profile flip is synchronous, so the send lands on the right
        // account. A failed switch fails the reply (loud system note),
        // never sends from the wrong account.
        Notifier.shared.onReply = { [weak self] chatID, text, accountID in
            let ready = await MainActor.run { [weak self] in
                self?.prepareReplyAccount(accountID) ?? true
            }
            guard ready else {
                return .failure(CoreCallError.failed(
                    "couldn't switch to the message's account"))
            }
            do {
                _ = try RustCore.send(chatID: chatID, text: text)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        // gap-g3: Notifier-delegate fallback for call banners (same
        // accept/end as the shared-delegate notes above; only fires if
        // install order ever flips Notifier's own delegate back on).
        Notifier.shared.onAcceptCall = { [weak self] _ in
            await MainActor.run { [weak self] in self?.call.accept() }
        }
        Notifier.shared.onDeclineCall = { [weak self] _ in
            await MainActor.run { [weak self] in self?.call.end() }
        }
        Task { _ = await Notifier.shared.requestAuthorization() }
    }

    /// Learn the owner MRI (`8:orgid:{oid}`) from Graph /me for
    /// MRI-preferred own/mention matching. Off-main (first call may hit
    /// network); the display-name backup covers messages until it lands.
    private func resolveOwnerMRI() {
        Task.detached { [weak self] in
            guard let me = try? RustCore.whoami(), !me.id.isEmpty else { return }
            let mri = "8:orgid:\(me.id)"
            guard let strongSelf = self else { return }
            await MainActor.run { strongSelf.ownerMRI = mri }
        }
    }

    /// Banner click (gap-g1): a foreign-account banner switches to
    /// its account first, then jumps (jump falls back to direct open
    /// while the post-switch list loads). Unknown foreign accounts are
    /// stale banners — dropped, never opened in the wrong account.
    private func openFromNotification(chatID id: String, accountID: String?) {
        if let acct = accountID, acct != accounts.activeID {
            guard !isDemo, accounts.accounts.contains(where: { $0.id == acct }) else { return }
            switchAccount(to: acct)
        }
        let name = chats.chat(id: id)?.name ?? "Conversation"
        jump(chatID: id, chatName: name)
    }

    /// False unless a reply may send on `accountID`: foreign accounts
    /// switch first (sync profile flip); demo, unknown accounts, and
    /// failed flips refuse (the caller fails loud, never cross-sends).
    private func prepareReplyAccount(_ accountID: String?) -> Bool {
        guard let acct = accountID, acct != accounts.activeID else { return true }
        guard !isDemo, accounts.accounts.contains(where: { $0.id == acct }) else { return false }
        return accounts.switchTo(acct)
    }

    /// Inline reply from a notification: optimistic bubble when the chat
    /// is open, direct core send otherwise (no chat switch). gap-g1: a
    /// foreign-account reply switches to its account first, then sends
    /// (the flip is synchronous, so the detached send lands right); a
    /// refused switch posts a loud failure instead of cross-sending.
    private func sendFromNotification(chatID id: String, text: String, accountID: String? = nil) {
        if let acct = accountID, acct != accounts.activeID {
            guard prepareReplyAccount(acct) else {
                Notifier.shared.postSystem(
                    title: "OstMac: reply failed",
                    body: "Reply failed: couldn't switch to the message's account.")
                return
            }
            Task.detached {
                _ = try? RustCore.send(chatID: id, text: text)
            }
            return
        }
        if openChatID == id {
            conv.send(text: text)
            return
        }
        Task.detached {
            _ = try? RustCore.send(chatID: id, text: text)
        }
    }

    /// Push had a gap: re-fetch the open chat plus the list.
    private func handleResync() {
        feedResyncs += 1
        refreshFeedStatus()
        if let id = openChatID, !isDemo {
            conv.open(chatID: id)
        }
        chats.refresh()
    }

    // MARK: - Background accounts (gap-g1)

    /// Sweep cadence over inactive accounts (accept: banner within 60s
    /// of an arrival — one interval covers worst-case skew).
    private static let bgPollInterval: TimeInterval = 30

    /// Start the background sweep (live only, once): an immediate seed
    /// sweep plus the 30s timer. Ungated — unlike the 2s tick it fires
    /// while minimized, which is the whole point.
    private func startBackgroundPoll() {
        guard !isDemo, bgTimer == nil else { return }
        bgTimer = Timer.scheduledTimer(
            withTimeInterval: Self.bgPollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepBackgroundAccounts() }
        }
        sweepBackgroundAccounts()
    }

    /// One sweep: snapshot the account list on-main, diff off-main
    /// (blocking network), handle arrivals back on-main. Skipped while
    /// a single account is active (nothing to sweep).
    private func sweepBackgroundAccounts() {
        guard !isDemo else { return }
        let snapshot = accounts.accounts
        let active = accounts.activeID
        guard snapshot.contains(where: { $0.id != active }) else { return }
        let poller = bgPoller
        Task.detached { [weak self] in
            let events = poller.pollOnce(accounts: snapshot, activeID: active)
            guard !events.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.handleBackgroundEvents(events)
            }
        }
    }

    private func handleBackgroundEvents(_ events: [BackgroundChatEvent]) {
        for ev in events {
            handleBackgroundEvent(ev)
        }
    }

    /// One inactive-account arrival: the same rules decision as the live
    /// path, but against that account's rules snapshot (its owner
    /// identity, never the active account's). Notifies accrue into the
    /// roll-up stash + post an account-naming banner (counted in the
    /// shared notifPosted/notifSkipped + alert stats); skips stay
    /// silent. Never touches the active account's list, timeline,
    /// receipts, presence, or mentions — those rebind on switch.
    private func handleBackgroundEvent(_ ev: BackgroundChatEvent) {
        bgEvents += 1
        // The account may have been removed mid-sweep — drop the event.
        guard let account = accounts.accounts.first(where: { $0.id == ev.accountID }) else { return }
        let msg = ev.asRealtimeMessage
        // Blocked senders skip everything (device-global list, same
        // gate as the live path; groupness rides the polled row).
        if blocked.isBlocked(chatID: msg.chatID, senderName: msg.sender, isGroup: ev.isGroup) {
            notifSkipped += 1
            notifLastReason = "blocked-user"
            return
        }
        let cfg = BackgroundRules.snapshot(base: rules.config, account: account)
        let decision = ChatFilter.decide(
            message: msg, chatDisplayName: ev.chatName,
            ownerMRI: BackgroundRules.ownerMRI(account: account),
            rules: cfg, meetingDedup: &meetingDedup, now: Date(),
            // Own Teams presence belongs to the ACTIVE account — not a
            // signal for this one. Local quiet (schedule/Focus) is
            // device-global and applies; snoozes key by chat id.
            dndActive: false,
            quietActive: localQuietNow,
            snoozedChatIDs: snooze.activeIDs())
        noteAlertStats(decision: decision)
        switch decision {
        case .notify(let reason):
            notifPosted += 1
            notifLastReason = reason
        case .skip(let reason):
            notifSkipped += 1
            notifLastReason = reason
        }
        guard case .notify = decision else { return }
        // gap-g2 fan-out (background leg): a window open on this
        // account owns the event (list bump + open-conv bubble + its
        // own unread) instead of the switch roll-up; the banner below
        // still posts (the window may be behind).
        if accountWindows.isOpen(accountID: ev.accountID) {
            _ = accountWindows.ingest(
                msg, decision: decision, activeID: accounts.activeID)
        } else {
            bgRollup.note(accountID: ev.accountID, chatID: ev.chatID)
        }
        if localQuietNow {
            noteSuppressedIfWarranted(msg, chatName: ev.chatName, decision: decision)
        } else {
            maybeNotify(
                msg, chatName: ev.chatName, decision: decision,
                mutedChatIDs: rules.config.mutedChatIDs,
                accountID: ev.accountID, accountName: ev.accountName,
                ownerDisplayName: account.displayName,
                ownerMRI: BackgroundRules.ownerMRI(account: account))
        }
    }

    /// 2s status tick. Background sweeps (scheduled sends, snooze +
    /// quiet-hours expiry, Focus, presence truth/schedule, live-call
    /// slot) run regardless of window visibility — a hidden/minimized
    /// window must never stall delivery. Each sweep is a no-op when
    /// nothing is due. Only the presentation refresh (feed status
    /// reads) is gated on visible surfaces; the next visible tick
    /// catches it up (≤2s stale, invisible anyway). Event paths still
    /// call refreshFeedStatus directly (never gated).
    private func tick() {
        let visible = Self.surfacesVisible()
        runBackgroundSweeps(visible: visible)
        guard visible else { return }
        refreshPresentation()
    }

    /// Any app window on screen (not hidden or miniaturized).
    public static func surfacesVisible() -> Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    private func refreshFeedStatus() {
        refreshPresentation()
        runBackgroundSweeps(visible: true)
    }

    /// Presentation-only: mirror feed state into @Published fields.
    private func refreshPresentation() {
        // Assign-on-change only: @Published emits per set, so an idle
        // tick must not publish (else the root re-evals every 2s).
        let freshState = feed.currentState
        if freshState != feedState { feedState = freshState }
        if feed.pollCount != feedPolls { feedPolls = feed.pollCount }
        if feed.lastError != feedError { feedError = feed.lastError }
    }

    /// Visibility-independent sweeps. Cheap when idle: snooze/quiet
    /// sweeps filter in-memory maps, fireScheduled early-outs on no due
    /// items, presence ticks write on transitions only. While hidden,
    /// the call slot FFI re-read runs only with a call in progress
    /// (incoming rings arrive via realtime ingest, not this poll).
    private func runBackgroundSweeps(visible: Bool) {
        quietHours.refresh() // om-quiet-hours: sweep expired DND (2s tick)
        focusSync.refresh() // e2-attention: re-poll Focus (assign-on-change)
        // e2-attention: scheduled presence sets (transitions only;
        // signed-in live only — demo never touches core). top10-presence: the truth tick always runs
        // (sweep + reconcile + rows) but writes only when live.
        presenceTruth.liveWrites = signedIn == true && !isDemo
        presenceTruth.tick()
        if signedIn == true, !isDemo {
            presenceSchedule.tick()
        }
        snooze.refresh() // d2-send: sweep expired snoozes (2s tick)
        fireScheduled() // d2-send: post due queue items (idle = no-op)
        // Re-read slot (place/accept landed?). Hidden + no call = skip FFI.
        if !isDemo, visible || call.call != nil || call.phase != .idle {
            call.refresh()
        }
    }

    /// Post every due scheduled item, oldest first. Claim-then-send lives
    /// in the store (each item fires at most once); delivery reuses the
    /// open chat's send path when it matches (optimistic own-bubble) and
    /// posts directly via core otherwise. Demo mode claims the open
    /// chat's items only (non-open items wait for their chat — offline,
    /// never touches core). Neither path touches the chat list
    /// (zero-refresh).
    private func fireScheduled(now: Date = Date()) {
        let open = openChatID
        let due: [ScheduledItem]
        if isDemo {
            due = scheduled.claimDue(now: now) { $0.chatID == open }
        } else {
            due = scheduled.claimDue(now: now)
        }
        for item in due {
            deliverScheduled(item)
        }
    }

    private func deliverScheduled(_ item: ScheduledItem) {
        if item.chatID == openChatID {
            conv.send(text: item.text)
            return
        }
        if isDemo { return }
        let id = item.chatID, body = item.text
        Task.detached {
            try? RustCore.send(chatID: id, text: body)
        }
    }

    /// Seed the Shifts team picker from the loaded teams and open the
    /// selected (or first) team (B1 merge; demo + live share the path).
    /// Empty teams never early-return: that stranded `.idle`'s infinite
    /// spinner with no retry (F6). Teams-load failures surface as
    /// `.error` with Retry; genuine zero-teams lands `.empty` with
    /// join/retry guidance.
    private func seedShifts() {
        let items = teams.teams.map { ShiftTeam(id: $0.teamId, name: $0.name) }
        guard !items.isEmpty else {
            if case .error(let message) = teams.state {
                shifts.showTeamsError(message)
            } else {
                shifts.showNoTeams()
            }
            return
        }
        shifts.setTeams(items)
        shifts.open(teamID: shifts.selectedTeamID ?? items[0].id)
    }

    /// Shifts Retry with no seeded teams (F6): reload the teams list,
    /// then re-seed when rows land (never strands `.idle`).
    private func reloadTeamsForShifts() async {
        await teams.load()
        if shifts.selectedTeamID == nil {
            seedShifts()
        } else {
            shifts.refresh()
        }
    }

    /// Demo week-grid meetings dated inside the current week (B1 merge).
    /// Nonisolated: runs inside the store's off-main fetch closure.
    private nonisolated static func calWeekDemoResponse() -> CalWeekResponse {
        let monday = CalWeek.startOfWeek(containing: Date())
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func at(dayOffset: Int, hour: Int, minute: Int) -> String {
            let base = cal.date(byAdding: .day, value: dayOffset, to: monday) ?? monday
            let parts = cal.dateComponents([.year, .month, .day], from: base)
            let date = cal.date(from: DateComponents(
                year: parts.year, month: parts.month, day: parts.day,
                hour: hour, minute: minute)) ?? base
            return fmt.string(from: date)
        }
        return CalWeekResponse(
            ok: true,
            weekStart: Int64(monday.timeIntervalSince1970), days: 7,
            meetings: [
                MeetingItem(
                    meetingId: "demo-cal-standup", subject: "Engineering standup",
                    start: at(dayOffset: 0, hour: 9, minute: 0),
                    end: at(dayOffset: 0, hour: 9, minute: 15),
                    joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_standup@thread.v2/0",
                    organizer: "Doe, Jane", isOnline: true),
                MeetingItem(
                    meetingId: "demo-cal-crit", subject: "Design crit (Room 3B)",
                    start: at(dayOffset: 1, hour: 14, minute: 0),
                    end: at(dayOffset: 1, hour: 15, minute: 0),
                    organizer: "Ray, Sam"),
                // Two overlapping online meetings (week-grid lanes).
                MeetingItem(
                    meetingId: "demo-cal-oneonone", subject: "1:1 with Megan",
                    start: at(dayOffset: 2, hour: 10, minute: 0),
                    end: at(dayOffset: 2, hour: 10, minute: 30),
                    joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_oneonone@thread.v2/0",
                    organizer: "Harper, Megan", isOnline: true),
                MeetingItem(
                    meetingId: "demo-cal-roadmap", subject: "Roadmap review",
                    start: at(dayOffset: 2, hour: 10, minute: 15),
                    end: at(dayOffset: 2, hour: 11, minute: 15),
                    joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_roadmap@thread.v2/0",
                    // Organized by the demo owner (Cancel Meeting… by identity).
                    organizer: DemoData.ownerDisplayName,
                    organizerEmail: "jordan.fox@contoso.example",
                    isOrganizer: true, isOnline: true),
                MeetingItem(
                    meetingId: "demo-cal-design", subject: "Design sync",
                    start: at(dayOffset: 3, hour: 13, minute: 0),
                    end: at(dayOffset: 3, hour: 14, minute: 0),
                    joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_design@thread.v2/0",
                    organizer: "Doe, Jane", isOnline: true),
            ])
    }

    /// Demo sibling-recording lookup: demo transcript stems match the
    /// demo recording stems (`Title with Name` ↔ `Title with Name.mp4`).
    private static func demoRecordingLookup() -> TranscriptsViewModel.RecordingLookup {
        let byStem = Dictionary(
            uniqueKeysWithValues: RecordingsDemo.response().recordings.map {
                (TranscriptItem.stem(of: $0.name), $0)
            })
        return { byStem[$0] }
    }

    /// Gate transition (fired from the $state sink for every auth
    /// change, whichever surface drove it): signed in → open deferred
    /// content (or reload the list + restart the feed when already
    /// open); signed out / expired / failed → park the feed and close
    /// the gate (fail closed; stale rows stay until the next sign-in).
    public func authChanged(_ s: AuthState) {
        switch s {
        case .signedIn:
            signedIn = true
            if accounts.accounts.isEmpty, !isDemo {
                Task { await adoptLegacyAccount() }
            }
            if contentOpened {
                if switchingAccount {
                    // d1-accounts: post-switch reload without spinners.
                    switchingAccount = false
                    quietRefreshAfterSwitch()
                    refreshFeedStatus()
                    return
                }
                chats.refresh()
                teams.refresh()
                reminders.refresh()
                planner.refresh()
                recordings.refresh()
                transcripts.refresh()
                unifiedFiles.refresh()
                meetings.refresh()
                calWeek.refresh()
                if shifts.selectedTeamID == nil {
                    seedShifts()
                } else {
                    shifts.refresh()
                }
                if !isDemo {
                    feed.start()
                    presence.refreshOwnSoon()
                }
            } else {
                Task { await openContentIfAllowed() }
            }
            refreshFeedStatus()
        case .signedOut, .signingOut, .expired, .refreshFailed, .error:
            signedIn = false
            switchingAccount = false
            feed.stop()
            presence.clear()
            presenceSchedule.clearApplied() // e2-attention: drop applied state
            presenceTruth.clearSession() // top10-presence: drop lock/log/devices
            typing.clear()
            meeting.clear()
            meetingChat.clear()
            unread.markAllRead() // om-notifbadge: counts clear on sign-out
            mentions.markAllRead() // om-mention-alerts: flags + dock clear on sign-out
            receipts.clear() // om-receipts: positions clear on sign-out
            ghost.clear() // f1-ghost: counters clear, toggles persist
            refreshFeedStatus()
        default:
            break
        }
    }
}
