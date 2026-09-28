// DemoData.swift — om-app-union: ONE canned dataset for `Better Teams --demo`.
// Merges the om-package sidebar rows (stable ids demo/demo-2/demo-3) with
// the om-integrate threads. Single source: chatsResponse()/messages()/name()
// all derive from `chats`; every row's preview/sender/time matches the
// last message of its thread.
import Foundation

public enum DemoData {
    /// Canned Catch Up summary (core-b): demo summaries never reach a
    /// real provider, CLI or on-device model.
    public static let catchUpSummary = """
        SUMMARY: The team agreed to ship the onboarding flow on Thursday.
        POINTS:
        - Ava is finishing the empty-state illustrations.
        - Open question: who reviews the sign-in copy?
        ACTIONS:
        - Tom: send the build notes before Thursday.
        """

    /// Conversation-specific canned summaries (CATCHQA), picked by a
    /// phrase from the conversation's transcript; `catchUpSummary`
    /// otherwise. Same fictional crew, never real content.
    public static let catchUpSummaries: [(marker: String, text: String)] = [
        ("Offsite photos", """
            SUMMARY: Offsite photos are in and Thursday's agenda is locked: roadmap, hiring and the offsite recap.
            POINTS:
            - Megan asked you to share the sunset photo for the offsite-recap deck.
            - The review deck is ready; Tom's const-generics note unblocked his render patch.
            - Build Bot reports main passed all checks.
            ACTIONS:
            - You: send the recap slides tonight.
            - Tom: give the review deck a thumbs up.
            """),
        ("retro moves", """
            SUMMARY: The sidebar is done, the conversation view is in review and the build is green.
            POINTS:
            - Retro moves to Thursday at 2; everyone brings one win and one snag.
            - Packaging is next.
            ACTIONS:
            - You: take the release notes this week.
            """),
    ]

    /// Conversations the demo Catch Up window starts with (mentions of
    /// the owner, the @everyone standup, and Ava's 1:1).
    public static let catchUpChatIDs: Set<String> = mentionedChatIDs.union([standupID, avaID])

    /// Shared demo stamp formatter (om-s6-renderparse): demo builders
    /// stamp every message through this instead of per-call allocs.
    private static let demoISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    public static let demoID = "demo"
    public static let avaID = "demo-2"
    /// Ava's reply to the owner's bubble (the Activity demo reply row).
    public static let avaReplyID = "ava-2r"
    public static let standupID = "demo-3"
    /// Extra 1:1 rows: New Chat's recent contacts (with presence).
    public static let tomID = "demo-tom"
    public static let meganID = "demo-megan"
    public static let richID = "demo-rich"
    public static let mediaID = "demo-media"
    public static let reactionsID = "demo-react"
    public static let repliesID = "demo-replies"
    public static let historyID = "demo-history"
    public static let botpostsID = "demo-botposts"
    public static let docsID = "demo-docs"
    public static let showcaseID = "demo-showcase"
    public static let longChannelID = "demo-chan-long"

    /// Sidebar rows. [0] is "demo" (matches ConversationStore.demo()).
    /// The rich row derives from the rich thread's last message, so its
    /// preview/sender/time track the floating Today timestamps.
    public static let chats: [ChatItem] = [
        ChatItem(
            chatId: "demo", name: "Design Sync", is_group: true,
            last_message_time: "2026-09-22T09:12:05Z",
            last_message_sender: "Megan Harper",
            last_message_preview: "Ship it. I'll take screenshots for the review deck."),
        ChatItem(
            chatId: "demo-2", name: "Ava Lindqvist",
            last_message_time: "2026-09-22T08:47:33Z",
            last_message_sender: "Ava Lindqvist",
            last_message_preview: "Standup moved to 10 — see you there."),
        ChatItem(
            chatId: "demo-3", name: "Platform Standup", is_group: true,
            last_message_time: "2026-09-21T16:20:11Z",
            last_message_sender: "Tom Becker",
            last_message_preview: "Build is green, packaging is next."),
        // Plain 1:1 recent contacts sit with the plain rows; the feature
        // threads follow, ending with the showcase (display order is by
        // recency, not array order).
        ChatItem(
            chatId: tomID, name: "Tom Becker",
            last_message_time: "2026-09-19T15:04:00Z",
            last_message_sender: "Tom Becker",
            last_message_preview: "Sounds good, I'll send the notes after lunch."),
        ChatItem(
            chatId: meganID, name: "Megan Harper",
            last_message_time: "2026-09-18T11:32:00Z",
            last_message_sender: "Me",
            last_message_preview: "Thanks, see you Monday."),
        richChat(),
        mediaChat(),
        reactionsChat(),
        repliesChat(),
        historyChat(),
        botPostsChat(),
        docsChat(),
        showcaseChat(),
    ]

    /// Rich sidebar row: preview/sender/time from the rich thread's tail.
    public static func richChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = ConversationStore.richDemoMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: richID, name: "Q3 Review Deck", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Media sidebar row: preview/sender/time from the media thread's tail.
    public static func mediaChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = mediaMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: mediaID, name: "Offsite Crew", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Reactions sidebar row: preview/sender/time from the reacted tail.
    public static func reactionsChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = reactionsMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: reactionsID, name: "Product Marketing", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Replies sidebar row: preview/sender/time from the replies thread's tail.
    public static func repliesChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = repliesMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: repliesID, name: "Onboarding Review", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// History sidebar row: preview/sender/time from the long tail.
    public static func historyChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = historyMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: historyID, name: "Release Train", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Bot-posts sidebar row: preview/sender/time from the bot thread's tail.
    public static func botPostsChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = botPostsMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: botpostsID, name: "Build Alerts", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// True for canned demo/chat ids (om-demo-select). Single namespace
    /// check: the exact "demo" root plus the "demo-" prefix (rows,
    /// channels, churn rows, reminder/note fixtures), plus the churn
    /// meeting id (a real-shaped 19: thread that only exists in the
    /// --show-sidebarchurn dataset). Live Teams ids never match.
    public static func isDemoID(_ id: String) -> Bool {
        id == demoID || id.hasPrefix("demo-") || id == churnMeetingID
    }

    /// Inline-docs sidebar row: preview/sender/time from the docs tail.
    public static func docsChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = docsMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: docsID, name: "Launch Checklist", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Showcase sidebar row: preview/sender/time from the showcase tail.
    public static func showcaseChat(now: Date = DemoClock.now) -> ChatItem {
        let msgs = showcaseMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: showcaseID, name: "Product Team", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    public static func chatsResponse() -> ChatsResponse {
        ChatsResponse(ok: true, chats: chats)
    }

    /// Canned teams for `--demo` (om-teams lane). Channel ids route to
    /// `channelMessages` via `messages(for:)` so opening a channel shows
    /// a thread offline.
    public static let teams: [TeamItem] = [
        TeamItem(teamId: "demo-team-eng", name: "Engineering", channels: [
            TeamChannel(channelId: "demo-chan-general", name: "General"),
            TeamChannel(channelId: "demo-chan-shipping", name: "Shipping"),
            TeamChannel(channelId: "demo-chan-long", name: "Release Review"),
        ]),
        TeamItem(teamId: "demo-team-design", name: "Design", channels: [
            TeamChannel(channelId: "demo-chan-crit", name: "Design Critique"),
        ]),
    ]

    public static func teamsResponse() -> TeamsResponse {
        TeamsResponse(ok: true, teams: teams)
    }

    /// Canned To Do lists for `--demo` (om-remind lane).
    public static let reminderLists: [ReminderList] = [
        ReminderList(listId: "demo-list-tasks", name: "Tasks", wellknown: "defaultList"),
        ReminderList(listId: "demo-list-groceries", name: "Groceries"),
    ]

    public static func remindersResponse() -> RemindersResponse {
        RemindersResponse(ok: true, lists: reminderLists)
    }

    /// Canned tasks per demo list. Unknown ids stay empty.
    public static func reminderTasks(for listID: String) -> [ReminderTask] {
        switch listID {
        case "demo-list-tasks": return [
            ReminderTask(
                taskId: "demo-task-1", title: "Review empty-states mock",
                importance: "high", due: "2026-09-23T10:00:00.0000000"),
            ReminderTask(
                taskId: "demo-task-2", title: "Book dentist",
                reminder: "2026-09-24T08:00:00.0000000"),
            ReminderTask(
                taskId: "demo-task-3", title: "Ship review deck",
                status: "completed", completed: true),
        ]
        case "demo-list-groceries": return [
            ReminderTask(taskId: "demo-task-4", title: "Oat milk"),
            ReminderTask(taskId: "demo-task-5", title: "Coffee beans", importance: "high"),
        ]
        default: return []
        }
    }

    public static func reminderTasksResponse(for listID: String) -> ReminderTasksResponse {
        ReminderTasksResponse(ok: true, list_id: listID, tasks: reminderTasks(for: listID))
    }

    /// Canned upcoming meetings for `--demo` (om-meet-join lane): one
    /// joinable online meeting, one in-person event with no link.
    public static let meetings: [MeetingItem] = [
        MeetingItem(
            meetingId: "demo-meet-standup", subject: "Engineering standup",
            start: "2026-09-24T09:00:00.0000000",
            end: "2026-09-24T09:15:00.0000000",
            joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_standup@thread.v2/0",
            organizer: "Doe, Jane", isOnline: true),
        MeetingItem(
            meetingId: "demo-meet-onsite", subject: "Design crit (Room 3B)",
            start: "2026-09-24T14:00:00.0000000",
            end: "2026-09-24T15:00:00.0000000",
            organizer: "Ray, Sam"),
    ]

    public static func meetingsResponse() -> MeetingsResponse {
        MeetingsResponse(ok: true, meetings: meetings)
    }

    /// Demo join-by-ID (core-c): any well-formed ID resolves to the
    /// joinable demo meeting, in memory.
    public static func meetingIDResolution() -> MeetingIDResolution {
        guard let m = meetings.first(where: { $0.isJoinable }), let url = m.joinURL else {
            return .notFound
        }
        return .found(joinURL: url, subject: m.subject)
    }

    /// Canned accepted join result for `--demo` (signaling-only echo).
    public static func demoJoinResult(threadID: String) -> CallResult {
        CallResult(
            ok: true, placed: true, accepted: true,
            call: CallInfo(
                id: "demo-meet-call", dir: "out", peer: threadID,
                peerName: "Engineering standup", thread: threadID,
                state: "connected", startedAt: 1,
                detail: "demo join · signaling only"))
    }

    /// Canned own presence for --demo (Available, offline adopted).
    public static func ownPresence() -> PresenceResponse {
        PresenceResponse(ok: true, availability: "Available", activity: "Available")
    }

    /// Canned chatmate pins for --demo: chatID → presence, one per 1:1
    /// row (same person, same presence as their directory hit); groups
    /// carry no dots.
    public static func peerPresence() -> [String: UserPresenceResponse] {
        [avaID: UserPresenceResponse(
            ok: true, id: "ava-demo", availability: "Busy", activity: "InACall"),
         tomID: UserPresenceResponse(
            ok: true, id: "demo-u-tom", availability: "Available", activity: "Available"),
         meganID: UserPresenceResponse(
            ok: true, id: "demo-u-megan", availability: "Away", activity: "Away")]
    }

    /// Canned directory-hit dots for --demo (om-f2-contacts lane): one
    /// response per `searchPeople` row (ids match `userId`).
    public static func contactPresence() -> [UserPresenceResponse] {
        [
            // Same as her 1:1 chat pin (one person, one presence).
            UserPresenceResponse(
                ok: true, id: "demo-u-ava", availability: "Busy",
                activity: "InACall"),
            UserPresenceResponse(
                ok: true, id: "demo-u-tom", availability: "Available",
                activity: "Available"),
            UserPresenceResponse(
                ok: true, id: "demo-u-megan", availability: "Away",
                activity: "Away"),
        ]
    }

    public static func messages(for chatID: String) -> [ChatMessage] {
        switch chatID {
        case demoID: return ConversationStore.demoMessages
        case avaID: return avaMessages
        case standupID: return standupMessages
        case tomID: return tomMessages
        case meganID: return meganMessages
        case richID: return ConversationStore.richDemoMessages()
        case mediaID: return mediaMessages()
        case reactionsID: return reactionsMessages()
        case repliesID: return repliesMessages()
        case churnMeetingID: return churnMeetingMessages
        case churnSyncID: return churnSyncMessages
        case churnPollyID: return churnPollyMessages
        case churnStandupID: return churnStandupMessages
        case historyID: return historyMessages()
        case botpostsID: return botPostsMessages()
        case docsID: return docsMessages()
        case showcaseID: return showcaseMessages()
        case longChannelID: return longChannelMessages()
        case DemoTeams.threadedChannelID: return DemoTeams.threadedPosts
        default: break
        }
        if chatID.hasPrefix("demo-chan-") { return channelMessages }
        return []
    }

    /// Pre-failed bubble ids per demo chat (rich thread's failed own send).
    public static func failedIDs(for chatID: String) -> Set<String> {
        chatID == richID ? ["rich-fail"] : []
    }

    /// Canned message-search index for `--demo` (om-ja-search lane):
    /// literal rows (no date formatting, safe to run off-main) over the
    /// static threads. Substring match on sender + preview; blank
    /// returns every row. Ids mirror the real demo bubbles, so
    /// jump-to-message lands in-memory (no paging) in demo.
    public static func messageSearchResponse(for query: String) -> SearchResponse {
        let rows: [SearchHit] = [
            SearchHit(
                messageID: "ava-1", chatID: avaID, sender: "Ava Lindqvist",
                timestamp: "2026-09-22T08:41:02Z",
                preview: "Morning! Can you review the empty-states mock when you get a chance?"),
            SearchHit(
                messageID: "ava-3", chatID: avaID, sender: "Ava Lindqvist",
                timestamp: "2026-09-22T08:47:33Z",
                preview: "Standup moved to 10 — see you there."),
            SearchHit(
                messageID: "standup-2", chatID: standupID, sender: "Tom Becker",
                timestamp: "2026-09-21T16:20:11Z",
                preview: "Build is green, packaging is next."),
            SearchHit(
                messageID: "rep-2", chatID: repliesID, sender: "Tom Becker",
                timestamp: "2026-09-22T09:05:00Z",
                preview: "First one: is the empty-state illustration final, or still placeholder?"),
            SearchHit(
                messageID: "chan-m2", chatID: "demo-chan-general",
                teamID: "demo-team-eng", channelID: "demo-chan-general",
                sender: "Tom Becker", timestamp: "2026-09-22T09:10:44Z",
                preview: "Build is green, packaging is next."),
        ]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hits = q.isEmpty
            ? rows
            : rows.filter {
                $0.preview.lowercased().contains(q) || $0.sender.lowercased().contains(q)
            }
        return SearchResponse(
            ok: true, query: query, from: 0, size: hits.count,
            total: hits.count, more: false, next_from: nil, hits: hits)
    }

    /// Demo threads flagging an owner mention (om-mentions): the rich
    /// thread's edited bubble mines the owner (`@Jordan Fox`) from its `<at>` tag, and the
    /// showcase kickoff does the same. Adopted by the app's MentionStore
    /// at demo launch (offline, no feed).
    public static let mentionedChatIDs: Set<String> = [richID, showcaseID]

    /// The demo owner's display name, as Teams writes it in a mention of
    /// them (`<at>`): bubbles show the name, never a placeholder.
    public static let ownerDisplayName = "Jordan Fox"

    /// Canned shared files for `--demo` (om-shared lane). Design Sync has
    /// three (pdf + image + sheet, one with a sender); Ava has one; the
    /// rich thread and channels share the design set; standup is empty.
    public static func sharedFiles(for chatID: String) -> [SharedFile] {
        switch chatID {
        case demoID, richID, docsID, showcaseID: return designFiles
        case avaID: return [avaFile]
        case standupID: return []
        default:
            if chatID.hasPrefix("demo-chan-") { return designFiles }
            return []
        }
    }

    /// Canned Move To… / Copy To… folders for `--demo` (the demo lists
    /// hold no folder rows): three at the drive root, two inside
    /// Documents, none deeper.
    public static func fileFolders(driveID: String, parentID: String = "root") -> [SharedFolderCrumb] {
        let names: [String]
        switch parentID {
        case "root": names = ["Documents", "Design Reviews", "Archive"]
        case "demo-folder-1": names = ["Contracts", "Reports"]
        default: names = []
        }
        let prefix = parentID == "root" ? "demo-folder" : parentID
        return names.enumerated().map { i, name in
            SharedFolderCrumb(driveID: driveID, itemID: "\(prefix)-\(i + 1)", name: name)
        }
    }

    private static let designFiles: [SharedFile] = [
        SharedFile(
            id: "demo-f1", name: "onboarding-mocks.pdf", size: 48211,
            mime: "application/pdf",
            web_url: "https://example.sharepoint.com/onboarding-mocks.pdf",
            download_url: "https://example.sharepoint.com/download/onboarding-mocks.pdf",
            drive_id: "demo-drive-1",
            created: "2026-09-21T10:02:11Z", sender: "Tom Becker",
            attachment_id: "doc-attach-1"),
        SharedFile(
            id: "demo-f2", name: "empty-states.png", size: 184320,
            mime: "image/png",
            web_url: "https://example.sharepoint.com/empty-states.png",
            download_url: "https://example.sharepoint.com/download/empty-states.png",
            drive_id: "demo-drive-1",
            created: "2026-09-22T08:41:02Z", sender: "Ava Lindqvist",
            attachment_id: "doc-attach-2"),
        SharedFile(
            id: "demo-f3", name: "launch-checklist.xlsx", size: 9216,
            mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            web_url: "https://example.sharepoint.com/launch-checklist.xlsx",
            drive_id: "demo-drive-1",
            created: "2026-09-20T16:20:11Z", sender: "Megan Harper",
            attachment_id: "doc-attach-3"),
    ]

    private static let avaFile = SharedFile(
        id: "demo-f-ava1", name: "standup-notes.md", size: 2048,
        mime: "text/markdown",
        web_url: "https://example.sharepoint.com/standup-notes.md",
        download_url: "https://example.sharepoint.com/download/standup-notes.md",
        drive_id: "demo-drive-2",
        created: "2026-09-22T08:47:33Z", sender: "Ava Lindqvist")

    /// Canned file-search index for `--demo` (om-jb-filesearch lane):
    /// the Shared-tab fixtures plus one plan row. Substring match on
    /// name; blank returns every row. Off-main safe (literals only).
    public static func fileSearchResponse(for query: String) -> FileSearchResponse {
        // Search rows name the conversation each file was shared in.
        let rows = designFiles.map { $0.withSource(name: "Design Sync", id: "demo") }
            + [avaFile.withSource(name: "Ava Lindqvist", id: "demo-2"),
               planFile.withSource(name: "Engineering > #General", id: "demo-chan-general"),
               specFile.withSource(name: "Design Sync", id: "demo")]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = q.isEmpty ? rows : rows.filter { $0.name.lowercased().contains(q) }
        return FileSearchResponse(ok: true, query: query, files: files)
    }

    /// Search-only spec document (the Files-scope "spec" query).
    private static let specFile = SharedFile(
        id: "demo-f-spec1", name: "search-results-spec.pdf", size: 126_976,
        mime: "application/pdf",
        web_url: "https://example.sharepoint.com/search-results-spec.pdf",
        drive_id: "demo-drive-1",
        created: "2026-09-23T14:30:00Z", sender: "Megan Harper")

    /// Canned recent searches (demo recents store is memory-only).
    public static let searchRecents = ["empty states", "standup", "launch checklist"]

    private static let planFile = SharedFile(
        id: "demo-f-plan1", name: "q3-plan.md", size: 4096,
        mime: "text/markdown",
        web_url: "https://example.sharepoint.com/q3-plan.md",
        drive_id: "demo-drive-2",
        created: "2026-09-22T09:10:44Z", sender: "Tom Becker")

    /// Canned unified Files surface for `--show-files` (top10-files
    /// lane): two conversation legs (chat + channel) plus drive recents.
    public static let unifiedDemoSpecs: [UnifiedSourceSpec] = [
        UnifiedSourceSpec(kind: .chat, id: demoID, name: "Design Sync"),
        UnifiedSourceSpec(
            kind: .channel, id: "demo-chan-general",
            name: "Engineering > #General"),
    ]

    /// Canned merged rows: a chat pdf, a channel sheet, a second chat
    /// image, and a drive-only Q&A export (no conversation list shows
    /// it — the recents leg's reason to exist). Modified dates pin the
    /// recents order (drive csv newest, chat pdf oldest).
    public static func unifiedDemoRows() -> [UnifiedFileRow] {
        [
            UnifiedFileRow(
                file: SharedFile(
                    id: "demo-u-chat1", name: "onboarding-mocks.pdf", size: 48211,
                    mime: "application/pdf",
                    web_url: "https://example.sharepoint.com/onboarding-mocks.pdf",
                    download_url: "https://example.sharepoint.com/download/onboarding-mocks.pdf",
                    drive_id: "demo-drive-1",
                    created: "2026-09-21T10:02:11Z",
                    modified: "2026-09-21T10:02:11Z", sender: "Tom Becker"),
                source: .chat, sourceName: "Design Sync", sourceID: demoID),
            UnifiedFileRow(
                file: SharedFile(
                    id: "demo-u-chat2", name: "empty-states.png", size: 184320,
                    mime: "image/png",
                    web_url: "https://example.sharepoint.com/empty-states.png",
                    download_url: "https://example.sharepoint.com/download/empty-states.png",
                    drive_id: "demo-drive-1",
                    created: "2026-09-22T08:41:02Z",
                    modified: "2026-09-22T08:41:02Z", sender: "Ava Lindqvist"),
                source: .chat, sourceName: "Design Sync", sourceID: demoID),
            UnifiedFileRow(
                file: SharedFile(
                    id: "demo-u-chan1", name: "launch-checklist.xlsx", size: 9216,
                    mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    web_url: "https://example.sharepoint.com/launch-checklist.xlsx",
                    drive_id: "demo-drive-3",
                    created: "2026-09-20T16:20:11Z",
                    modified: "2026-09-24T14:11:00Z", sender: "Megan Harper"),
                source: .channel, sourceName: "Engineering > #General", sourceID: "demo-chan-general"),
            UnifiedFileRow(
                file: SharedFile(
                    id: "demo-u-drive1", name: "qna-export-sept.csv", size: 12288,
                    mime: "text/csv",
                    web_url: "https://example.sharepoint.com/qna-export-sept.csv",
                    drive_id: "demo-drive-9",
                    created: "2026-09-25T09:58:00Z",
                    modified: "2026-09-25T09:58:00Z", sender: ownerDisplayName),
                source: .drive, sourceName: "OneDrive"),
        ] + unifiedDemoLibrary()
    }

    /// The rest of the demo Recent list: Office documents, PDFs and
    /// images across chats, channels and OneDrive (older than the four
    /// rows above, so those keep the top of the recents order).
    private static func unifiedDemoLibrary() -> [UnifiedFileRow] {
        let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        let pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        let general = ("Engineering > #General", "demo-chan-general")
        let shipping = ("Engineering > #Shipping", DemoTeams.threadedChannelID)
        let mkt = ("Marketing > #Launch Plan", "demo-chan-mkt-launch")
        func row(_ id: String, _ name: String, _ size: UInt64, _ mime: String, _ modified: String,
                 by: String, chat: (String, String)? = nil, channel: (String, String)? = nil) -> UnifiedFileRow {
            let file = SharedFile(
                id: id, name: name, size: size, mime: mime,
                web_url: "https://example.sharepoint.com/\(name)",
                download_url: "https://example.sharepoint.com/download/\(name)",
                drive_id: channel != nil ? "demo-drive-3" : chat != nil ? "demo-drive-1" : "demo-drive-9",
                created: modified, modified: modified, sender: by)
            if let chat { return UnifiedFileRow(file: file, source: .chat, sourceName: chat.0, sourceID: chat.1) }
            if let channel {
                return UnifiedFileRow(file: file, source: .channel, sourceName: channel.0, sourceID: channel.1)
            }
            return UnifiedFileRow(file: file, source: .drive, sourceName: "OneDrive")
        }
        let design = ("Design Sync", demoID)
        let product = ("Product Team", showcaseID)
        return [
            row("demo-u-l01", "Q3 Business Review.pptx", 4_812_544, pptx, "2026-09-24T16:42:00Z",
                by: "Megan Harper", chat: ("Q3 Review Deck", richID)),
            row("demo-u-l02", "Release Notes 3.2.docx", 86_016, docx, "2026-09-24T11:05:00Z",
                by: "Luis Ortega", channel: shipping),
            row("demo-u-l03", "Onboarding Flow v4.pdf", 2_359_296, "application/pdf", "2026-09-23T15:20:00Z",
                by: "Ava Lindqvist", chat: design),
            row("demo-u-l04", "Budget FY27 Draft.xlsx", 312_320, xlsx, "2026-09-23T09:48:00Z",
                by: ownerDisplayName),
            row("demo-u-l05", "App Store Screenshots.png", 1_468_006, "image/png", "2026-09-22T17:31:00Z",
                by: "Ava Lindqvist", channel: shipping),
            row("demo-u-l06", "Launch Plan.docx", 142_336, docx, "2026-09-22T13:02:00Z",
                by: "Paula Norris", channel: mkt),
            row("demo-u-l07", "Customer Interviews Summary.docx", 64_512, docx, "2026-09-21T10:15:00Z",
                by: "Megan Harper", chat: product),
            row("demo-u-l08", "Hiring Pipeline.xlsx", 48_128, xlsx, "2026-09-19T15:44:00Z",
                by: "Paula Norris"),
            row("demo-u-l09", "Offsite Agenda.pdf", 204_800, "application/pdf", "2026-09-18T12:10:00Z",
                by: "Tom Becker", chat: ("Offsite Crew", mediaID)),
            row("demo-u-l10", "Architecture Overview.pptx", 3_145_728, pptx, "2026-09-17T09:30:00Z",
                by: "Tom Becker", channel: general),
            row("demo-u-l11", "Brand Guidelines 2026.pdf", 7_864_320, "application/pdf", "2026-09-16T14:25:00Z",
                by: "Ava Lindqvist", channel: mkt),
            row("demo-u-l12", "Sprint 12 Burndown.xlsx", 27_648, xlsx, "2026-09-15T17:05:00Z",
                by: ownerDisplayName, channel: general),
            row("demo-u-l13", "Icon Set Export.png", 655_360, "image/png", "2026-09-12T11:40:00Z",
                by: "Ava Lindqvist", chat: design),
            row("demo-u-l14", "Security Review Checklist.docx", 39_936, docx, "2026-09-10T08:55:00Z",
                by: "Luis Ortega", channel: general),
        ]
    }

    /// Canned transfers for `--demo` (p3c): finished downloads from a
    /// pinned web app, a chat attachment and the Files list (Files ▸
    /// Downloads), one download and one upload in flight (Transfers
    /// popover, determinate progress). Paths sit in the demo tmp dir
    /// (never ~/Downloads); the UI writes placeholder bytes on demand.
    /// Fixed dates keep the order deterministic.
    @MainActor
    public static func transferDemoItems() -> [FileTransfer] {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_790_413_200) // 2026-09-26 09:00 UTC
        func path(_ name: String) -> String { UnifiedFilesStore.demoSaveDestination(filename: name) }
        return [
            FileTransfer(id: "demo-t-up", name: "sprint-review-notes.md", direction: .upload,
                         origin: "Design Sync", originID: demoID, size: 6144,
                         date: base.addingTimeInterval(day + 3_600), progress: 0.7),
            FileTransfer(id: "demo-t-run", name: "roadmap-q4.csv", direction: .download,
                         origin: "OneDrive", size: 20480,
                         date: base.addingTimeInterval(day + 3_000), progress: 0.42),
            FileTransfer(id: "demo-d-web", name: "planner-export.csv", direction: .download,
                         origin: "Planner", path: path("planner-export.csv"), size: 3072,
                         date: base.addingTimeInterval(day), progress: 1, status: .done),
            FileTransfer(id: "demo-d-chat", name: "retro-notes.txt", direction: .download,
                         origin: "Design Sync", originID: demoID, path: path("retro-notes.txt"),
                         size: 1843, date: base.addingTimeInterval(7_200), progress: 1, status: .done),
            FileTransfer(id: "demo-d-chan", name: "release-plan.md", direction: .download,
                         origin: "Engineering > #General", originID: "demo-chan-general",
                         path: path("release-plan.md"), size: 5120, date: base, progress: 1, status: .done),
        ]
    }

    /// Canned people-search index for `--demo` (om-jb-filesearch lane):
    /// literal roster rows (roles empty, like directory hits). Substring
    /// match on display name + email; blank returns every row.
    public static func peopleSearchResponse(for query: String) -> PeopleSearchResponse {
        let rows = searchPeople
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let people = q.isEmpty
            ? rows
            : rows.filter {
                $0.displayName.lowercased().contains(q)
                    || ($0.email ?? "").lowercased().contains(q)
            }
        return PeopleSearchResponse(ok: true, query: query, people: people)
    }

    /// Demo Calls ▸ Speed Dial pins (§6.5): two directory people.
    public static var speedDial: [TeamMember] { Array(searchPeople.prefix(2)) }

    private static let searchPeople: [TeamMember] = [
        TeamMember(id: "demo-u-ava", displayName: "Ava Lindqvist", userId: "demo-u-ava", email: "ava@example.com"),
        TeamMember(id: "demo-u-tom", displayName: "Tom Becker", userId: "demo-u-tom", email: "tom@example.com"),
        TeamMember(id: "demo-u-megan", displayName: "Megan Harper", userId: "demo-u-megan", email: "megan@example.com"),
    ]

    /// Canned version history for `--demo` file pop-outs (gap-g8).
    /// Unknown ids stay empty (the preview shows "no history").
    public static func fileVersions(for fileID: String) -> [FileVersion] {
        switch fileID {
        case "demo-f1": return [
            FileVersion(
                id: "3", size: 48211,
                modified: "2026-09-22T08:41:02Z",
                modified_by: "Ava Lindqvist"),
            FileVersion(
                id: "2", size: 47102,
                modified: "2026-09-21T14:12:44Z",
                modified_by: "Tom Becker"),
            FileVersion(
                id: "1", size: 44001,
                modified: "2026-09-21T10:02:11Z",
                modified_by: "Tom Becker"),
        ]
        default: return []
        }
    }

    public static func name(for chatID: String) -> String? {
        if let chat = chats.first(where: { $0.id == chatID }) { return chat.name }
        for team in teams {
            if let ch = team.channels.first(where: { $0.id == chatID }) {
                return "\(team.name) > #\(ch.name)"
            }
        }
        return nil
    }

    /// Rich-media thread (om-richmedia): unicode emoji, `(code)`
    /// shortcodes, a captioned photo, an image-only bubble, a broken-image
    /// failure, and an emoticon-sized reply. Fully offline (`demo://`
    /// fixtures). Timestamps float off now (Today).
    public static func mediaMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "media-1", sender: "Megan Harper",
                timestamp: iso(at(h: 9, m: 2)),
                content: "Ship day! 🚀 (party) the build is green",
                raw: "<p>Ship day! 🚀 (party) the build is green</p>"),
            ChatMessage(
                id: "media-2", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 5)),
                content: "Sunset from the offsite 🌅",
                raw: #"<p>Sunset from the offsite 🌅</p><p><img src="demo://photo-1" alt="offsite sunset"></p>"#),
            ChatMessage(
                id: "media-3", sender: "Megan Harper",
                timestamp: iso(at(h: 9, m: 7)),
                content: "",
                raw: #"<p><img src="demo://photo-2" alt="lake dawn"></p>"#),
            ChatMessage(
                id: "media-4", sender: "Me",
                timestamp: iso(at(h: 9, m: 9)),
                content: "(thumbsup) Gorgeous (clap)",
                isOwn: true),
            ChatMessage(
                id: "media-5", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 11)),
                content: "This upload never landed",
                raw: #"<p>This upload never landed</p><p><img src="demo://missing" alt="broken upload"></p>"#),
            ChatMessage(
                id: "media-6", sender: "Me",
                timestamp: iso(at(h: 9, m: 12)),
                content: "Resending the vibe instead",
                isOwn: true,
                raw: #"<p>Resending the vibe instead <img src="demo://photo-1" width="20" height="20" alt="(smile)"></p>"#),
            ChatMessage(
                id: "media-7", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 13)),
                content: "Friday mood",
                raw: #"<p>Friday mood</p><p><img src="demo://gif-1" alt="celebration gif"></p>"#),
        ]
    }

    /// Reactions thread (om-reactions): reacted bubbles (single + multi
    /// counts), one bare bubble for the picker shot. Fully offline.
    /// Timestamps float off now (Today).
    public static func reactionsMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "react-1", sender: "Megan Harper",
                timestamp: iso(at(h: 10, m: 2)),
                content: "Review deck is ready — link in the channel. Thumbs up when you've seen it?",
                reactions: [
                    // core-a who-reacted: canned demo reactors (wire
                    // names, MRI ids — the live native shape + names).
                    ReactionCount(emoji: "👍", count: 3, reactors: [
                        Reactor(id: "8:orgid:demo-u-tom", name: "Tom Becker"),
                        Reactor(id: "8:orgid:demo-u-ava", name: "Ava Lindqvist"),
                        Reactor(id: "8:orgid:demo-u-me", name: "Me"),
                    ]),
                    ReactionCount(emoji: "❤️", count: 1, reactors: [
                        Reactor(id: "8:orgid:demo-u-ava", name: "Ava Lindqvist"),
                    ]),
                ]),
            ChatMessage(
                id: "react-2", sender: "Tom Becker",
                timestamp: iso(at(h: 10, m: 4)),
                content: "Seen — the empty-states slide made me laugh out loud.",
                reactions: [ReactionCount(emoji: "😂", count: 2, reactors: [
                    Reactor(id: "8:orgid:demo-u-megan", name: "Megan Harper"),
                    Reactor(id: "8:orgid:demo-u-me", name: "Me"),
                ])]),
            ChatMessage(
                id: "react-3", sender: "Me",
                timestamp: iso(at(h: 10, m: 6)),
                content: "Glad it landed. Right-click any bubble to try the picker — counts update live.",
                isOwn: true),
        ]
    }

    /// Replies thread (om-replies): a question answered inline, a nested
    /// reply-to-reply, one own reply, and one reply whose parent aged out
    /// of history (evicted-parent fallback). Fully offline. Timestamps
    /// float off now (Today). `raw` mirrors the core quote-block format.
    public static func repliesMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "rep-1", sender: "Megan Harper",
                timestamp: iso(at(h: 9, m: 2)),
                content: "Review thread is open — drop questions on the onboarding mock here and I'll answer inline."),
            ChatMessage(
                id: "rep-2", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 5)),
                content: "First one: is the empty-state illustration final, or still placeholder?",
                raw: #"<quote author="Megan Harper" guid="rep-1">Review thread is open — drop questions on the onboarding mock here and I'll answer inline.</quote><p>First one: is the empty-state illustration final, or still placeholder?</p>"#,
                reply_to: "rep-1"),
            ChatMessage(
                id: "rep-3", sender: "Megan Harper",
                timestamp: iso(at(h: 9, m: 8)),
                content: "Final — approved in yesterday's crit. The copy around it is still TBD though, so flag anything that reads odd.",
                raw: #"<quote author="Tom Becker" guid="rep-2">First one: is the empty-state illustration final, or still placeholder?</quote><p>Final — approved in yesterday's crit. The copy around it is still TBD though, so flag anything that reads odd.</p>"#,
                reply_to: "rep-2"),
            ChatMessage(
                id: "rep-4", sender: "Me",
                timestamp: iso(at(h: 9, m: 11)),
                content: "I'll take the copy pass — replying inline as I go.",
                isOwn: true),
            ChatMessage(
                id: "rep-5", sender: "Me",
                timestamp: iso(at(h: 9, m: 13)),
                content: "One more: do we keep the progress dots on step 1?",
                isOwn: true,
                raw: #"<quote author="Megan Harper" guid="rep-1">Review thread is open — drop questions on the onboarding mock here and I'll answer inline.</quote><p>One more: do we keep the progress dots on step 1?</p>"#,
                reply_to: "rep-1"),
            ChatMessage(
                id: "rep-6", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 15)),
                content: "Following up on last week's thread — build is green now.",
                reply_to: "rep-0-evicted"),
        ]
    }

    /// History thread (om-history): a 3-day release-review conversation
    /// (38 bubbles) exercising the few-days window + day separators at every
    /// scroll state. Fully offline. Timestamps float off now so the
    /// separators always read <date>/Yesterday/Today.
    public static func historyMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(dayOffset: Int, h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        // (dayOffset, hour, minute, sender, text, isOwn)
        let script: [(Int, Int, Int, String, String, Bool)] = [
            (-2, 9, 2, "Megan Harper", "Kicking off the release review thread — three days of notes live here.", false),
            (-2, 9, 5, "Tom Becker", "Agenda: window load, day paging, then the blank-state fixes.", false),
            (-2, 9, 9, "Megan Harper", "First up: opening a long thread should show the last day, not everything.", false),
            (-2, 9, 14, "Me", "Agreed — a few-days window keeps the initial load fast.", true),
            (-2, 9, 21, "Tom Becker", "And older days load lazily from the top of the scroll.", false),
            (-2, 10, 3, "Megan Harper", "What about threads that went quiet for a week?", false),
            (-2, 10, 11, "Me", "Then the newest page still shows — the window never blanks the view.", true),
            (-2, 11, 26, "Tom Becker", "Right: bound the fetch, not the display.", false),
            (-2, 13, 2, "Megan Harper", "Lunch break. Back with the paging sketches.", false),
            (-2, 14, 40, "Megan Harper", "Sketches are up: one tap loads one more day back.", false),
            (-2, 14, 47, "Tom Becker", "Love it. No more auto-chaining the whole history.", false),
            (-2, 15, 12, "Me", "That auto-loading was why the thread kept jumping around.", true),
            (-2, 16, 5, "Tom Becker", "Explicit taps only from now on.", false),
            (-2, 16, 58, "Megan Harper", "Day one notes done. Tomorrow: error states.", false),
            (-1, 9, 1, "Megan Harper", "Day two: what does a failed history fetch look like?", false),
            (-1, 9, 6, "Tom Becker", "A banner over the messages we already have — never a blank pane.", false),
            (-1, 9, 13, "Me", "And when nothing loaded at all, an empty state with retry.", true),
            (-1, 9, 29, "Megan Harper", "Retry re-runs the open, right? Not just the failed page?", false),
            (-1, 9, 34, "Me", "Exactly — Try Again re-opens the chat.", true),
            (-1, 10, 15, "Tom Becker", "Mid-chain failures keep partial pages too.", false),
            (-1, 10, 22, "Megan Harper", "Good. Partial progress plus a visible error.", false),
            (-1, 11, 48, "Tom Becker", "Switching chats mid-load drops the stale work?", false),
            (-1, 11, 55, "Me", "Yes — generation guard on every page, open and day-load alike.", true),
            (-1, 13, 20, "Megan Harper", "Edge case: a page that arrives empty but points further back.", false),
            (-1, 13, 31, "Tom Becker", "Keep paging — blank pages don't cover the window.", false),
            (-1, 15, 2, "Megan Harper", "And garbage timestamps stop the window after the current page.", false),
            (-1, 15, 19, "Me", "Right, we can't window what we can't parse.", true),
            (-1, 16, 44, "Tom Becker", "Day two notes done. Tomorrow we ship it.", false),
            (0, 9, 0, "Megan Harper", "Ship day. Final pass over the scroll states.", false),
            (0, 9, 4, "Tom Becker", "Top of thread: oldest day separator plus the load-more button.", false),
            (0, 9, 9, "Me", "Middle: day separators between the three days.", true),
            (0, 9, 15, "Megan Harper", "Bottom: the tail of the last 24 hours.", false),
            (0, 9, 28, "Tom Becker", "Screenshots at every state, all viewed.", false),
            (0, 9, 41, "Megan Harper", "One more check: the error state with its Try Again.", false),
            (0, 9, 52, "Me", "Covered — it shows when you're offline, too.", true),
            (0, 10, 4, "Tom Becker", "Then we're good to go. Shipping it.", false),
            (0, 10, 12, "Megan Harper", "Release review complete. Great thread, everyone.", false),
            (0, 10, 18, "Me", "Archiving these notes — see you at the next review.", true),
        ]
        return script.enumerated().map { i, line in
            ChatMessage(
                id: "hist-\(i + 1)", sender: line.3,
                timestamp: iso(at(dayOffset: line.0, h: line.1, m: line.2)),
                content: line.4, isOwn: line.5)
        }
    }

    /// Bot-posts thread (om-botposts): an RSS digest (prose + two
    /// title+link rows), a build card (marked JSON → row, blob
    /// suppressed), an unparseable card (server-held attachment →
    /// placeholder), and a mixed deploy note (prose + one row). Fully
    /// offline. Timestamps float off now (Today). `content` mirrors
    /// core strip semantics (tags removed, no spaces added).
    public static func botPostsMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "bot-1", sender: "Tech News RSS",
                timestamp: iso(at(h: 8, m: 2)),
                content: "Tech news digest — 2 new stories:"
                    + "Accessible color palettes, explainedA practical guide to contrast in product design."
                    + "Faster builds with smarter cachingLessons from teams that cut CI time in half.",
                raw: "<p>Tech news digest — 2 new stories:</p>"
                    + #"<attachment><p><a href="https://example.com/accessible-color">Accessible color palettes, explained</a></p>"#
                    + "<p>A practical guide to contrast in product design.</p></attachment>"
                    + #"<attachment><p><a href="https://example.com/build-caching">Faster builds with smarter caching</a></p>"#
                    + "<p>Lessons from teams that cut CI time in half.</p></attachment>"),
            ChatMessage(
                id: "bot-2", sender: "Build Bot",
                timestamp: iso(at(h: 8, m: 5)),
                content: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#,
                raw: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#),
            ChatMessage(
                id: "bot-3", sender: "RSS Bot",
                timestamp: iso(at(h: 8, m: 7)),
                content: "",
                raw: #"<attachment id="abc123"></attachment>"#),
            ChatMessage(
                id: "bot-4", sender: "Deploy Bot",
                timestamp: iso(at(h: 8, m: 9)),
                content: "Deploy finished: release 42 notes",
                raw: #"<p>Deploy finished: </p><attachment><a href="https://example.com/deploys/42">release 42 notes</a></attachment>"#),
        ]
    }

    /// Inline-docs thread (om-inline-docs): a file-only PDF bubble (row
    /// only, placeholder suppressed), a captioned bubble with two refs
    /// (image + sheet rows under the text), and an own reply. Attachment
    /// ids match `designFiles` (the Shared tab for this chat), so rows
    /// resolve fully offline. Timestamps float off now (Today). `content`
    /// mirrors core strip semantics (attachment tags remove cleanly).
    public static func docsMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "doc-1", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 2)),
                content: "",
                raw: #"<attachment id="doc-attach-1"></attachment>"#),
            ChatMessage(
                id: "doc-2", sender: "Megan Harper",
                timestamp: iso(at(h: 9, m: 5)),
                content: "Mocks and the launch checklist — feedback by noon?",
                raw: "<p>Mocks and the launch checklist — feedback by noon?</p>"
                    + #"<attachment id="doc-attach-2"></attachment>"#
                    + #"<attachment id="doc-attach-3"></attachment>"#),
            ChatMessage(
                id: "doc-3", sender: "Me",
                timestamp: iso(at(h: 9, m: 9)),
                content: "Got them — reviewing now.",
                isOwn: true),
        ]
    }

    /// Showcase thread (om-demo-showcase): ONE conversation exercising
    /// every rich feature — mentions (`<at>` tags), reactions (counts),
    /// replies (quote blocks + nesting), pins (first two bubbles are the
    /// seeded strip targets), cards/bot posts (MessageCard JSON + digest
    /// rows), images (offline `demo://` fixtures), receipts (own tail →
    /// Seen via the demo adopt), and day separators (Yesterday/Today).
    /// Fully offline. Timestamps float off now. Zero real data: the same
    /// fictional crew as every other demo thread.
    public static func showcaseMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(dayOffset: Int, h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        return [
            ChatMessage(
                id: "sc-1", sender: "Megan Harper",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 2)),
                content: "Offsite photos are in — @Jordan Fox can you share the sunset one?",
                raw: "<p>Offsite photos are in — <at id=\"8:me\">@Jordan Fox</at> can you share the sunset one?</p>",
                // Reactors carry ids only: names come from the chat roster.
                reactions: [
                    ReactionCount(emoji: "👍", count: 3, reactors: [Reactor(id: "8:orgid:demo-u-tom"), Reactor(id: "8:orgid:demo-u-ava"), Reactor(id: "8:orgid:demo-u-me")]),
                    ReactionCount(emoji: "❤️", count: 1, reactors: [Reactor(id: "8:orgid:demo-u-tom")]),
                ]),
            ChatMessage(
                id: "sc-2", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 5)),
                content: "Yes please. The best ones go in the `offsite-recap` deck.",
                raw: #"<quote author="Megan Harper" guid="sc-1">Offsite photos are in — @Jordan Fox can you share the sunset one?</quote><p>Yes please. The best ones go in the `offsite-recap` deck.</p>"#,
                reply_to: "sc-1"),
            ChatMessage(
                id: "sc-3", sender: "Me",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 9)),
                content: "Sunset from the offsite 🌅",
                isOwn: true,
                raw: #"<p>Sunset from the offsite 🌅</p><p><img src="demo://photo-1" alt="offsite sunset"></p>"#,
                reactions: [
                    ReactionCount(emoji: "❤️", count: 2, reactors: [Reactor(id: "8:orgid:demo-u-megan"), Reactor(id: "8:orgid:demo-u-tom")]),
                    ReactionCount(emoji: "👍", count: 1, reactors: [Reactor(id: "8:orgid:demo-u-ava")]),
                ]),
            ChatMessage(
                id: "sc-4", sender: "Tech News RSS",
                timestamp: iso(at(dayOffset: 0, h: 8, m: 2)),
                content: "Morning digest — 2 new stories:"
                    + "Accessible color palettes, explainedA practical guide to contrast in product design."
                    + "Faster builds with smarter cachingLessons from teams that cut CI time in half.",
                raw: "<p>Morning digest — 2 new stories:</p>"
                    + #"<attachment><p><a href="https://example.com/accessible-color">Accessible color palettes, explained</a></p>"#
                    + "<p>A practical guide to contrast in product design.</p></attachment>"
                    + #"<attachment><p><a href="https://example.com/build-caching">Faster builds with smarter caching</a></p>"#
                    + "<p>Lessons from teams that cut CI time in half.</p></attachment>"),
            ChatMessage(
                id: "sc-5", sender: "Build Bot",
                timestamp: iso(at(dayOffset: 0, h: 8, m: 5)),
                content: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#,
                raw: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#),
            ChatMessage(
                id: "sc-6", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: 0, h: 8, m: 8)),
                content: "The const-generics note unblocked my render patch.",
                raw: #"<quote author="Tech News RSS" guid="sc-4">Morning digest — 2 new stories</quote><p>The const-generics note unblocked my render patch.</p>"#,
                reactions: [ReactionCount(emoji: "😂", count: 2, reactors: [Reactor(id: "8:orgid:demo-u-megan"), Reactor(id: "8:orgid:demo-u-me")])],
                reply_to: "sc-4"),
            ChatMessage(
                id: "sc-7", sender: "Megan Harper",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 1)),
                content: "Nice. @Tom Becker (party) the review deck is ready — thumbs up when you've seen it?",
                raw: "<p>Nice. <at id=\"8:t\">@Tom Becker</at> (party) the review deck is ready — thumbs up when you've seen it?</p>"),
            ChatMessage(
                id: "sc-8", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 4)),
                content: "Seen — the empty-states slide made me laugh out loud.",
                isOwn: true,
                raw: #"<quote author="Megan Harper" guid="sc-7">Nice. @Tom Becker (party) the review deck is ready — thumbs up when you've seen it?</quote><p>Seen — the empty-states slide made me laugh out loud.</p>"#,
                reply_to: "sc-7"),
            ChatMessage(
                id: "sc-9", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 6)),
                content: "",
                raw: #"<p><img src="demo://photo-2" alt="lake dawn"></p>"#),
            ChatMessage(
                id: "sc-10", sender: "Megan Harper",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 9)),
                content: "Locking Thursday's agenda: roadmap, hiring, and the offsite recap.",
                edited: true),
            ChatMessage(
                id: "sc-11", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 12)),
                content: "Sounds good — I'll send the recap slides tonight 🚀",
                isOwn: true),
        ]
    }

    /// Long-channel thread (om-hu-fixture): 300 bubbles over 10 days
    /// (30/day) for scroll/cap shots. Deterministic: rotating fictional
    /// crew, ascending stamps floating off now, own tail, sequence
    /// numbers in the text so shots show their position. Fully offline.
    /// Bigger than every initial-load cap (open 3×50, day-load 4×50,
    /// 72h window), so window math always has older pages waiting.
    public static func longChannelMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String { demoISO.string(from: d) }
        func at(dayOffset: Int, minutes: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            let morning = cal.date(
                bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
            return cal.date(byAdding: .minute, value: minutes, to: morning) ?? morning
        }
        let crew = ["Megan Harper", "Tom Becker", "Ava Lindqvist", "Me"]
        let lines = [
            "Release review notes — paging through the long channel.",
            "Window load first: newest slice lands, older pages wait.",
            "Day separators should split every scroll state cleanly.",
            "Top of thread: oldest day plus the load-more button.",
            "Middle: keep the anchor row pinned on prepend.",
            "Bottom: tail of the last 24 hours, jump control hidden.",
            "Failed page keeps partial progress with a retry.",
            "Empty page chains on — blank never covers the window.",
            "Garbage stamps stop the window after the current page.",
            "Switching channels mid-load drops the stale chain.",
            "Cap check: open slice plus day-loads stay under the total.",
            "Screenshots at top, middle, and tail — all viewed.",
        ]
        return (0 ..< 300).map { i in
            let sender = crew[i % crew.count]
            return ChatMessage(
                id: "lchan-\(i + 1)", sender: sender,
                timestamp: iso(at(dayOffset: i / 30 - 9, minutes: (i % 30) * 19)),
                content: "\(lines[i % lines.count]) (#\(i + 1)/300)",
                isOwn: sender == "Me")
        }
    }

    /// Shared offline thread shown when a demo channel opens.
    private static let channelMessages: [ChatMessage] = [
        ChatMessage(
            id: "chan-m1", sender: "Megan Harper",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Kickoff notes are pinned — goals, dates, owners."),
        ChatMessage(
            id: "chan-m2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:10:44Z",
            content: "Build is green, packaging is next."),
    ]

    private static let avaMessages: [ChatMessage] = [
        ChatMessage(
            id: "ava-1", sender: "Ava Lindqvist",
            timestamp: "2026-09-22T08:41:02Z",
            content: "Morning! Can you review the empty-states mock when you get a chance?"),
        ChatMessage(
            id: "ava-2", sender: "Me",
            timestamp: "2026-09-22T08:44:51Z",
            content: "Sure — looking now. The illustration is great.", isOwn: true),
        ChatMessage(
            id: avaReplyID, sender: "Ava Lindqvist",
            timestamp: "2026-09-22T08:45:40Z",
            content: "Thanks! The copy under it is still a draft, so flag anything that reads odd.",
            raw: #"<quote author="Me" guid="ava-2">Sure — looking now. The illustration is great.</quote><p>Thanks! The copy under it is still a draft, so flag anything that reads odd.</p>"#,
            reply_to: "ava-2"),
        ChatMessage(
            id: "ava-3", sender: "Ava Lindqvist",
            timestamp: "2026-09-22T08:47:33Z",
            content: "Standup moved to 10 — see you there."),
    ]

    private static let standupMessages: [ChatMessage] = [
        // Catch Up evidence (CATCHQA): one @everyone and one mention of
        // the owner, both before the row's last message (preview stays).
        ChatMessage(
            id: "standup-e", sender: "Megan Harper",
            timestamp: "2026-09-21T16:04:40Z",
            content: "@Everyone retro moves to Thursday at 2. Bring one win and one snag.",
            raw: "<p><at id=\"0\">Everyone</at> retro moves to Thursday at 2. Bring one win and one snag.</p>"),
        ChatMessage(
            id: "standup-m", sender: "Ava Lindqvist",
            timestamp: "2026-09-21T16:11:25Z",
            content: "@Jordan Fox can you take the release notes this week?",
            raw: "<p><at id=\"1\">Jordan Fox</at> can you take the release notes this week?</p>"),
        ChatMessage(
            id: "standup-1", sender: "Tom Becker",
            timestamp: "2026-09-21T16:18:02Z",
            content: "Update: sidebar done, conversation view in review."),
        ChatMessage(
            id: "standup-2", sender: "Tom Becker",
            timestamp: "2026-09-21T16:20:11Z",
            content: "Build is green, packaging is next."),
    ]

    private static let tomMessages: [ChatMessage] = [
        ChatMessage(
            id: "tom-1", sender: "Me",
            timestamp: "2026-09-19T14:58:00Z",
            content: "Can you share the notes from the planning call?", isOwn: true),
        ChatMessage(
            id: "tom-2", sender: "Tom Becker",
            timestamp: "2026-09-19T15:04:00Z",
            content: "Sounds good, I'll send the notes after lunch."),
    ]

    private static let meganMessages: [ChatMessage] = [
        ChatMessage(
            id: "megan-1", sender: "Megan Harper",
            timestamp: "2026-09-18T11:30:00Z",
            content: "I moved our review to Monday at 10."),
        ChatMessage(
            id: "megan-2", sender: "Me",
            timestamp: "2026-09-18T11:32:00Z",
            content: "Thanks, see you Monday.", isOwn: true),
    ]

    // MARK: - Notes (om-notes lane: canned OneNote for --demo)

    public static let notebooks: [NotebookItem] = [
        NotebookItem(notebookId: "demo-nb-work", name: "Design Sync Notes"),
        NotebookItem(notebookId: "demo-nb-team", name: "Team Wiki"),
    ]

    public static func notebooksResponse() -> NotebooksResponse {
        NotebooksResponse(ok: true, notebooks: notebooks)
    }

    public static func noteSections(for notebookID: String) -> [NoteSectionItem] {
        switch notebookID {
        case "demo-nb-work":
            return [
                NoteSectionItem(sectionId: "demo-sec-sync", name: "Syncs", pages: [
                    NotePageItem(
                        pageId: "demo-page-kickoff", title: "Kickoff Notes",
                        updated: "2026-09-22T09:12:05Z"),
                    NotePageItem(
                        pageId: "demo-page-empty", title: "Empty States Review",
                        updated: "2026-09-21T16:20:11Z"),
                ]),
                NoteSectionItem(sectionId: "demo-sec-ideas", name: "Ideas", pages: [
                    NotePageItem(pageId: "demo-page-roadmap", title: "Roadmap Draft"),
                ]),
            ]
        case "demo-nb-team":
            return [
                NoteSectionItem(sectionId: "demo-sec-wiki", name: "General", pages: [
                    NotePageItem(pageId: "demo-page-onboard", title: "Onboarding"),
                ]),
            ]
        default:
            return []
        }
    }

    private static let demoPageBodies: [String: (title: String, html: String)] = [
        "demo-page-kickoff": ("Kickoff Notes",
            "<html><head><title>Kickoff Notes</title></head><body>" +
                "<p>Onboarding refresh \u{00B7} kickoff held Monday with design, engineering and support.</p>" +
                "<h2>Goals</h2>" +
                "<ul><li>Cut time to first message from 4 minutes to under 90 seconds.</li>" +
                "<li>Replace the six-step setup with three screens and a skip option.</li>" +
                "<li>Ship to 10% of new sign-ups before the October release.</li></ul>" +
                "<h2>Milestones</h2>" +
                "<table><tr><th>Milestone</th><th>Owner</th><th>Date</th></tr>" +
                "<tr><td>Final mocks approved</td><td>Ava Lindqvist</td><td>Oct 2</td></tr>" +
                "<tr><td>Sign-in error states</td><td>Tom Becker</td><td>Oct 7</td></tr>" +
                "<tr><td>Localized copy</td><td>Hannah Moore</td><td>Oct 9</td></tr>" +
                "<tr><td>10% rollout</td><td>Megan Harper</td><td>Oct 14</td></tr></table>" +
                "<h2>Decisions</h2>" +
                "<ul><li>Keep the progress dots on every step.</li>" +
                "<li>Support gets a preview build a week before rollout.</li></ul>" +
                "<h2>Action items</h2>" +
                "<p data-tag=\"to-do:completed\">Share the kickoff deck with the wider team</p>" +
                "<p data-tag=\"to-do\">Book usability sessions with five new customers</p>" +
                "<p data-tag=\"to-do\">Draft help-center article for the new setup flow</p>" +
                "<p data-tag=\"to-do\">Confirm analytics events with the data team</p>" +
                "</body></html>"),
        "demo-page-empty": ("Empty States Review",
            "<html><head><title>Empty States Review</title></head><body>" +
                                "<p>Illustration approved. Copy still TBD.</p>" +
                "</body></html>"),
        "demo-page-roadmap": ("Roadmap Draft",
            "<html><head><title>Roadmap Draft</title></head><body>" +
                                "<p>Q4: notes, search, polish.</p>" +
                "</body></html>"),
        "demo-page-onboard": ("Onboarding",
            "<html><head><title>Onboarding</title></head><body>" +
                                "<p>Welcome! Start with the Design Sync notebook.</p>" +
                "</body></html>"),
    ]

    /// Paragraphs appended in this demo session (pageID → bodies).
    private static var demoAppended: [String: [String]] = [:]

    public static func notePage(for pageID: String) -> NotePageResponse? {
        guard let base = demoPageBodies[pageID] else { return nil }
        var html = base.html
        for para in demoAppended[pageID] ?? [] {
            let escaped = para
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            html = html.replacingOccurrences(
                of: "</body></html>", with: "<p>\(escaped)</p></body></html>")
        }
        return NotePageResponse(ok: true, id: pageID, title: base.title, html: html)
    }

    /// Offline append (demo Notes tab): records the paragraph locally.
    public static func appendDemo(pageID: String, text: String) {
        demoAppended[pageID, default: []].append(text)
    }

    /// Reset demo appends (tests).
    public static func resetDemoAppends() {
        demoAppended = [:]
    }

    // MARK: - Sidebar churn demo (om-sidebarchurn: --show-sidebarchurn)

    /// Churn-demo rows (NOT part of `chats`: the shot hook swaps the
    /// whole fetcher so the standard demo + its count assertions stay
    /// untouched). Initial order: meeting on top; the burst moves ONLY
    /// the user-active chat above it.
    public static let churnMeetingID = "19:meeting_churn123@thread.v2"
    public static let churnSyncID = "demo-churn-sync"
    public static let churnPollyID = "demo-churn-polly"
    public static let churnStandupID = "demo-churn-standup"

    public static func churnChatsResponse() -> ChatsResponse {
        ChatsResponse(ok: true, chats: [
            ChatItem(
                chatId: churnMeetingID, name: "Sprint Planning", is_group: true,
                last_message_time: "2026-09-23T09:00:00Z",
                last_message_sender: "Megan Harper",
                last_message_preview: "Running 5 late, start without me"),
            ChatItem(
                chatId: churnPollyID, name: "Polly",
                last_message_time: "2026-09-23T08:50:00Z",
                last_message_sender: "Polly",
                last_message_preview: "Yesterday's poll is closed"),
            ChatItem(
                chatId: churnStandupID, name: "Platform Standup", is_group: true,
                last_message_time: "2026-09-23T08:40:00Z",
                last_message_sender: "Tom Becker",
                last_message_preview: "Build is green"),
            ChatItem(
                chatId: churnSyncID, name: "Design Sync", is_group: true,
                last_message_time: "2026-09-23T08:30:00Z",
                last_message_sender: "Tom Becker",
                last_message_preview: "Mocks are up for review"),
        ])
    }

    /// The burst the shot hook folds after load: a meeting beacon storm
    /// (skipped), a reaction-only patch (skipped), a media card
    /// (skipped), a mixed card (its human lines refresh the meeting
    /// preview in place), a bot poll note + a system notice (in place),
    /// a user message (bubbles) + its edit (in place). Final order:
    /// Sync, Meeting, Polly, Standup.
    public static func churnBurst() -> [RealtimeMessage] {
        [
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b1", sender: "?",
                text: "Sprint PlanningPlay", time: "2026-09-23T09:01:00Z",
                isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b2", sender: "?",
                text: #"{"scopeId":"s","storageId":"t","meetingTenantId":"m"}"#,
                time: "2026-09-23T09:02:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b3", sender: "Facilitator",
                text: "Hi! I'm here to help with the meeting — ask me for a recap.",
                time: "2026-09-23T09:03:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b4", sender: "Tom Becker",
                text: "", time: "2026-09-23T09:04:00Z", isEdit: false,
                reactions: [ReactionCount(emoji: "👍", count: 2)],
                messageType: "RichText/Html"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b5", sender: "?",
                text: "Q3 Review recording", time: "2026-09-23T09:05:00Z",
                isEdit: false, messageType: "RichText/Media_Card"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b6", sender: "?",
                text: "{\n\"scopeId\": \"s\",\n\"storageId\": \"t\"\n}\nStandup notes are posted in the thread",
                time: "2026-09-23T09:06:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b7", sender: "Tom Becker",
                text: "Recording is up — link in the thread",
                time: "2026-09-23T09:07:00Z", isEdit: false,
                messageType: "RichText/Html"),
            RealtimeMessage(
                chatID: churnPollyID, msgId: "ch-b8", sender: "Polly",
                senderID: "28:00001111-2222-3333-4444-555566667777",
                text: "Megan voted: Thursday works best",
                time: "2026-09-23T09:08:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnStandupID, msgId: "ch-b9", sender: "?",
                text: "Tom Becker added Megan Harper to the chat",
                time: "2026-09-23T09:09:00Z", isEdit: false,
                messageType: "ThreadActivity/AddMember"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b10", sender: "Tom Becker",
                text: "Recording is up — link in the thread (fixed)",
                time: "2026-09-23T09:10:00Z", isEdit: true, editedID: "ch-b7",
                messageType: "RichText/Html"),
        ]
    }

    private static let churnMeetingMessages: [ChatMessage] = [
        ChatMessage(
            id: "chm-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:55:00Z",
            content: "Agenda: sprint review, then retro. Starting in 5."),
        ChatMessage(
            id: "chm-2", sender: "Megan Harper",
            timestamp: "2026-09-23T09:00:00Z",
            content: "Running 5 late, start without me"),
    ]

    private static let churnSyncMessages: [ChatMessage] = [
        ChatMessage(
            id: "chs-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:30:00Z",
            content: "Mocks are up for review"),
    ]

    private static let churnPollyMessages: [ChatMessage] = [
        ChatMessage(
            id: "chp-1", sender: "Polly",
            timestamp: "2026-09-23T08:50:00Z",
            content: "Yesterday's poll is closed"),
    ]

    private static let churnStandupMessages: [ChatMessage] = [
        ChatMessage(
            id: "chh-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:40:00Z",
            content: "Build is green"),
    ]
}
