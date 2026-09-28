// Models.swift — pure Codable for ostmac-core JSON envelopes. No C calls.
import Foundation

/// Generic error envelope: {"ok":false,"error":code,"detail":...}
public struct CoreError: Decodable, Sendable {
    public let error: String
    public let detail: String?

    public var message: String {
        detail.map { "\(error): \($0)" } ?? error
    }
}

public struct TokenSlot: Decodable, Sendable {
    public let present: Bool
    public let expired: Bool
}

public struct TokenSummary: Decodable, Sendable {
    public let aad: TokenSlot
    public let refresh_present: Bool
    public let graph: TokenSlot
    public let ic3: TokenSlot
    public let recorder: TokenSlot
    public let skype: TokenSlot
    public let region_gtms_present: Bool
}

public struct StatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let signed_in: Bool
    public let tokens: TokenSummary
}

/// Active-profile envelope: {"ok":true,"profile":id}.
public struct ProfileResponse: Decodable, Sendable {
    public let ok: Bool
    public let profile: String
}

/// One signed-in Teams account (d1-accounts). `id` is the stable
/// account id (Teams user id from whoami once known, else the pending
/// profile id); the core profile id is derived 1:1 from it.
public struct AccountRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let upn: String?
    /// Teams user id from whoami (identity display); nil until resolved.
    public let userID: String?
    public let addedAt: Double

    public init(
        id: String, displayName: String, upn: String? = nil,
        userID: String? = nil, addedAt: Double = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.upn = upn
        self.userID = userID
        self.addedAt = addedAt
    }
}

public struct DeviceStart: Decodable, Sendable {
    public let ok: Bool
    public let session: String
    public let verification_uri: String
    public let user_code: String
    public let message: String
    public let expires_in: Int
    public let interval: Int
}

public struct DevicePoll: Decodable, Sendable {
    public let ok: Bool
    public let status: String
    public let interval: Int?
    public let tokens: TokenSummary?
}

// MARK: - Auth refresh / sign-out (om-authux lane)

/// Refresh envelope: `refreshed=false` means no refresh token is stored
/// (run the device-code flow); `tokens` is present only when refreshed.
public struct RefreshResponse: Decodable, Sendable {
    public let ok: Bool
    public let refreshed: Bool
    public let tokens: TokenSummary?
}

/// `{ok:true}` after tokens are cleared.
public struct SignOutResponse: Decodable, Sendable {
    public let ok: Bool
}

// MARK: - Browser-capture fallback (om-pwauth lane)

/// Auth-code + PKCE start: load `authorize_url` in the webview; the
/// `redirect_uri` hit carries `?code&state` for `browserComplete`.
public struct AuthCodeStart: Decodable, Sendable {
    public let ok: Bool
    public let session: String
    public let authorize_url: String
    public let redirect_uri: String
    public let expires_in: Int
}

/// Auth-code complete: `status` is "complete" (tokens saved, same shape
/// as the device flow) — anything else arrives as a thrown CoreCallError.
public struct AuthCodeComplete: Decodable, Sendable {
    public let ok: Bool
    public let status: String
    public let tokens: TokenSummary?
}

/// `{ok:true, cancelled}` after dropping a pending browser session.
public struct AuthCodeCancel: Decodable, Sendable {
    public let ok: Bool
    public let cancelled: Bool
}

// MARK: - Identity (om-identity-own lane)

/// Current user from `CoreReads.whoami` (Graph /me, Swift-cached).
/// `display_name` is the `ChatMessage.sender` match key for `isOwn`
/// (same sender==name rule the ost TUI uses).
public struct WhoamiResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let display_name: String
    public let mail: String?
}

public struct ChatItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { chatId }
    public let chatId: String
    public let name: String
    public let is_group: Bool
    public let last_message_time: String?
    public let last_message_sender: String?
    public let last_message_preview: String?

    enum CodingKeys: String, CodingKey {
        case chatId = "id"
        case name, is_group, last_message_time
        case last_message_sender, last_message_preview
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        chatId: String, name: String, is_group: Bool = false,
        last_message_time: String? = nil,
        last_message_sender: String? = nil,
        last_message_preview: String? = nil
    ) {
        self.chatId = chatId
        self.name = name
        self.is_group = is_group
        self.last_message_time = last_message_time
        self.last_message_sender = last_message_sender
        self.last_message_preview = last_message_preview
    }
}

public struct ChatsResponse: Decodable, Sendable {
    public let ok: Bool
    public let chats: [ChatItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, chats: [ChatItem]) {
        self.ok = ok
        self.chats = chats
    }
}

// MARK: - Teams (om-teams lane)

/// One channel inside a team. Wire format from `CoreReads.teams`:
/// `{"id","name","description?","membership_type?","web_url?"}`.
/// The id opens as a conversation through the same messages/send path
/// as chat ids (ost TUI parity). Detail fields are nil on pre-H1
/// payloads and when Graph omits them.
public struct TeamChannel: Decodable, Sendable, Identifiable {
    public var id: String { channelId }
    public let channelId: String
    public let name: String
    public let description: String?
    public let membershipType: String?
    public let webUrl: String?

    enum CodingKeys: String, CodingKey {
        case channelId = "id"
        case name, description
        case membershipType = "membership_type"
        case webUrl = "web_url"
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        channelId: String, name: String,
        description: String? = nil,
        membershipType: String? = nil,
        webUrl: String? = nil
    ) {
        self.channelId = channelId
        self.name = name
        self.description = description
        self.membershipType = membershipType
        self.webUrl = webUrl
    }
}

/// One joined team with its channels.
public struct TeamItem: Decodable, Sendable, Identifiable {
    public var id: String { teamId }
    public let teamId: String
    public let name: String
    public let channels: [TeamChannel]

    enum CodingKeys: String, CodingKey {
        case teamId = "id"
        case name, channels
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(teamId: String, name: String, channels: [TeamChannel]) {
        self.teamId = teamId
        self.name = name
        self.channels = channels
    }
}

public struct TeamsResponse: Decodable, Sendable {
    public let ok: Bool
    public let teams: [TeamItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, teams: [TeamItem]) {
        self.ok = ok
        self.teams = teams
    }
}

/// `{ok,channel}` from `ostmac_channel_create`.
public struct ChannelCreateResponse: Decodable, Sendable {
    public let ok: Bool
    public let channel: TeamChannel

    /// Host-side construction (mocks, previews). Wire decoding is untouched.
    public init(ok: Bool, channel: TeamChannel) {
        self.ok = ok
        self.channel = channel
    }
}

/// `{ok,chat}` from `ostmac_chat_create_one_to_one` (om-lt5-person11).
/// The row reuses the chat-list shape; `name` is empty (Graph sends
/// no 1:1 topic) — callers name the thread after the peer.
public struct ChatCreateResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat: ChatItem

    /// Host-side construction (mocks, previews). Wire decoding is untouched.
    public init(ok: Bool, chat: ChatItem) {
        self.ok = ok
        self.chat = chat
    }
}

/// Join-one-team result from core `ostmac_team_join`: `{"ok","team_id"}`.
public struct TeamJoinResponse: Decodable, Sendable {
    public let ok: Bool
    public let team_id: String

    /// Host-side construction (tests, previews). Wire decoding is untouched.
    public init(ok: Bool, team_id: String) {
        self.ok = ok
        self.team_id = team_id
    }
}

/// One joinable team from core `ostmac_team_search` (core-b). `id` is the
/// team id: join it with `TeamsViewModel.join(publicTeam:)`.
public struct PublicTeam: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    /// Lowercased Graph visibility (always `public` from core).
    public let visibility: String?

    public init(id: String, name: String, description: String? = nil, visibility: String? = "public") {
        self.id = id
        self.name = name
        self.description = description
        self.visibility = visibility
    }
}

/// `{ok,query,source,teams}` from `ostmac_team_search`. `source` is the
/// Graph surface that answered (`groups` word match / `teams` prefix).
public struct PublicTeamsResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let source: String?
    public let teams: [PublicTeam]

    public init(ok: Bool, query: String? = nil, source: String? = nil, teams: [PublicTeam]) {
        self.ok = ok
        self.query = query
        self.source = source
        self.teams = teams
    }
}

/// `{ok,team,polls?,elapsed_ms?}` from `ostmac_team_create`. Telemetry
/// is optional (older cores omit it); the team row always decodes.
public struct TeamCreateResponse: Decodable, Sendable {
    public let ok: Bool
    public let team: TeamItem
    public let polls: Int?
    public let elapsedMs: Int?

    enum CodingKeys: String, CodingKey {
        case ok, team, polls
        case elapsedMs = "elapsed_ms"
    }

    /// Host-side construction (mocks, previews). Wire decoding is untouched.
    public init(ok: Bool, team: TeamItem, polls: Int? = nil, elapsedMs: Int? = nil) {
        self.ok = ok
        self.team = team
        self.polls = polls
        self.elapsedMs = elapsedMs
    }
}

// MARK: - Channel tabs (om-h4-tabs lane)

/// Where one channel tab deep-links. Posts/Files/Notes land in the
/// conversation view's own Chat/Shared/Notes tabs; website tabs open in
/// the browser; unknown tabs with no URL go nowhere (rendered dimmed).
public enum ChannelTabTarget: Equatable, Sendable {
    case chat
    case shared
    case notes
    case web(URL)
    case none
}

/// One pinned channel tab from core `ostmac_tabs` (Graph tabs
/// projection): identity + link-out targets only. No content renderers —
/// `target` maps well-known tabs to host views, the rest to the browser.
public struct ChannelTab: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let appID: String?
    public let contentURL: String?
    public let websiteURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case appID = "app_id"
        case contentURL = "content_url"
        case websiteURL = "website_url"
    }

    /// Teams Files-tab app id (SharePoint file browser).
    public static let filesAppID = "com.microsoft.teamspace.tab.files.sharepoint"
    /// Teams OneNote-tab app id (channel notebook).
    public static let notesAppID = "0d820ecd-def2-4297-a09a-912c7e06f45b"

    /// Host-side construction (demo data, previews, mock fetchers).
    /// Wire decoding is untouched.
    public init(
        id: String, name: String, appID: String? = nil,
        contentURL: String? = nil, websiteURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.appID = appID
        self.contentURL = contentURL
        self.websiteURL = websiteURL
    }

    /// Deep-link target: well-known tabs by app id (name fallback for
    /// tenants that omit it), then content/website URL, else nowhere.
    public var target: ChannelTabTarget {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n == "posts" { return .chat }
        if appID == Self.filesAppID || n == "files" { return .shared }
        if appID == Self.notesAppID || n == "notes" { return .notes }
        if let s = contentURL ?? websiteURL,
           let url = URL(string: s), url.scheme != nil
        {
            return .web(url)
        }
        return .none
    }
}

public struct TabsResponse: Decodable, Sendable {
    public let ok: Bool
    public let channel_id: String?
    public let tabs: [ChannelTab]

    /// Host-side construction (demo data, previews, mock fetchers).
    /// Wire decoding is untouched.
    public init(ok: Bool, channel_id: String? = nil, tabs: [ChannelTab]) {
        self.ok = ok
        self.channel_id = channel_id
        self.tabs = tabs
    }
}

// MARK: - Team roster (om-h5-members lane)

/// One roster entry from core `ostmac_team_members`.
/// `id` is the Graph membership id (the remove target), NOT the user
/// id. `isOwner` mirrors `roles.contains("owner")` (pinned in ost).
public struct TeamMember: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let userId: String?
    public let email: String?
    public let roles: [String]
    public let isOwner: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case userId = "user_id"
        case email, roles
        case isOwner = "is_owner"
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(id: String, displayName: String, userId: String? = nil, email: String? = nil, roles: [String] = [], isOwner: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.userId = userId
        self.email = email
        self.roles = roles
        self.isOwner = isOwner
    }
}

/// One team's roster. Wire format from core `ostmac_team_members`:
/// `{"ok","team_id","members":[...]}`.
public struct TeamMembersResponse: Decodable, Sendable {
    public let ok: Bool
    public let teamId: String
    public let members: [TeamMember]

    enum CodingKeys: String, CodingKey {
        case ok
        case teamId = "team_id"
        case members
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, teamId: String, members: [TeamMember]) {
        self.ok = ok
        self.teamId = teamId
        self.members = members
    }
}

/// Add result from core `ostmac_team_member_add`: `{"ok","member"}`.
public struct TeamMemberAddResponse: Decodable, Sendable {
    public let ok: Bool
    public let member: TeamMember

    /// Host-side construction (mock fetchers).
    public init(ok: Bool, member: TeamMember) {
        self.ok = ok
        self.member = member
    }
}

/// Remove result from core `ostmac_team_member_remove`:
/// `{"ok","team_id","member_id"}`.
public struct TeamMemberRemoveResponse: Decodable, Sendable {
    public let ok: Bool
    public let teamId: String
    public let memberId: String

    enum CodingKeys: String, CodingKey {
        case ok
        case teamId = "team_id"
        case memberId = "member_id"
    }

    /// Host-side construction (mock fetchers).
    public init(ok: Bool, teamId: String, memberId: String) {
        self.ok = ok
        self.teamId = teamId
        self.memberId = memberId
    }
}

public struct TrouterPoll: Decodable, Sendable {
    public let ok: Bool
    public let events: [AnyJSON]
}

// MARK: - Reminders (om-remind lane: Microsoft To Do via Graph /me/todo)

/// One To Do list from core `ostmac_reminders`: `{"id","name","wellknown?"}`.
public struct ReminderList: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { listId }
    public let listId: String
    public let name: String
    public let wellknown: String?

    enum CodingKeys: String, CodingKey {
        case listId = "id"
        case name, wellknown
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(listId: String, name: String, wellknown: String? = nil) {
        self.listId = listId
        self.name = name
        self.wellknown = wellknown
    }
}

public struct RemindersResponse: Decodable, Sendable {
    public let ok: Bool
    public let lists: [ReminderList]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, lists: [ReminderList]) {
        self.ok = ok
        self.lists = lists
    }
}

/// One To Do task from core `ostmac_reminder_tasks`: `{"id","title",
/// "status","importance","due?","reminder?","completed"}`.
public struct ReminderTask: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { taskId }
    public let taskId: String
    public let title: String
    public let status: String
    public let importance: String
    public let due: String?
    public let reminder: String?
    public let completed: Bool

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case title, status, importance, due, reminder, completed
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        taskId: String, title: String, status: String = "notStarted",
        importance: String = "normal", due: String? = nil,
        reminder: String? = nil, completed: Bool = false
    ) {
        self.taskId = taskId
        self.title = title
        self.status = status
        self.importance = importance
        self.due = due
        self.reminder = reminder
        self.completed = completed
    }

    /// No-offset stamp read as UTC, shifted to local (ChatMessage rules).
    public var displayDue: String? {
        due.map { ChatMessage.shortTime($0) }
    }
}

public struct ReminderTasksResponse: Decodable, Sendable {
    public let ok: Bool
    public let list_id: String?
    public let tasks: [ReminderTask]
}

/// `{ok,task}` from `ostmac_reminder_add` / `ostmac_reminder_done`.
public struct ReminderTaskResult: Decodable, Sendable {
    public let ok: Bool
    public let task: ReminderTask
}

// MARK: - Meetings (om-meet-join lane: upcoming via Graph calendarView)

/// One upcoming meeting from `CoreReads.meetings`: `{"id","subject",
/// "start?","end?","join_url?","organizer?","is_online"}`.
public struct MeetingItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { meetingId }
    public let meetingId: String
    public let subject: String
    public let start: String?
    public let end: String?
    public let joinURL: String?
    public let organizer: String?
    /// Organizer SMTP address (Graph `organizer.emailAddress.address`).
    public let organizerEmail: String?
    /// Graph `isOrganizer`: the signed-in user organizes this meeting.
    /// Identity-based; use this (not `organizer` name matching) to gate
    /// organizer-only actions such as Cancel Meeting. False when absent.
    public let isOrganizer: Bool
    public let isOnline: Bool
    /// Graph `categories` (Outlook color categories); empty when absent.
    public let categories: [String]

    enum CodingKeys: String, CodingKey {
        case meetingId = "id"
        case subject, start, end, organizer, categories
        case organizerEmail = "organizer_email"
        case isOrganizer = "is_organizer"
        case joinURL = "join_url"
        case isOnline = "is_online"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingId = try c.decode(String.self, forKey: .meetingId)
        subject = try c.decode(String.self, forKey: .subject)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        joinURL = try c.decodeIfPresent(String.self, forKey: .joinURL)
        organizer = try c.decodeIfPresent(String.self, forKey: .organizer)
        organizerEmail = try c.decodeIfPresent(String.self, forKey: .organizerEmail)
        isOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
        isOnline = try c.decode(Bool.self, forKey: .isOnline)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
    }

    /// Host-side construction (demo data, previews).
    public init(
        meetingId: String, subject: String, start: String? = nil,
        end: String? = nil, joinURL: String? = nil,
        organizer: String? = nil, organizerEmail: String? = nil,
        isOrganizer: Bool = false, isOnline: Bool = false,
        categories: [String] = []
    ) {
        self.categories = categories
        self.meetingId = meetingId
        self.subject = subject
        self.start = start
        self.end = end
        self.joinURL = joinURL
        self.organizer = organizer
        self.organizerEmail = organizerEmail
        self.isOrganizer = isOrganizer
        self.isOnline = isOnline
    }

    /// True when the row has something Join can use.
    public var isJoinable: Bool {
        guard let u = joinURL?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !u.isEmpty
    }

    /// No-offset stamp read as UTC, shifted to local (ChatMessage rules).
    public var displayStart: String? {
        start.map { ChatMessage.shortTime($0) }
    }
}

public struct MeetingsResponse: Decodable, Sendable {
    public let ok: Bool
    public let meetings: [MeetingItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, meetings: [MeetingItem]) {
        self.ok = ok
        self.meetings = meetings
    }
}

/// Join-target classification from Swift `JoinParse` (was core FFI):
/// `{"kind","thread_id?","meeting_id?","url"}`. `kind` is
/// thread|meeting-id|url|unknown.
public struct JoinTarget: Decodable, Sendable, Equatable {
    public let kind: String
    public let threadID: String?
    public let meetingID: String?
    public let url: String

    enum CodingKeys: String, CodingKey {
        case kind, url
        case threadID = "thread_id"
        case meetingID = "meeting_id"
    }

    public init(kind: String, threadID: String? = nil, meetingID: String? = nil, url: String) {
        self.kind = kind
        self.threadID = threadID
        self.meetingID = meetingID
        self.url = url
    }

    /// True for the two kinds the Join button can act on without leaving
    /// the app flow (thread legs dial signaling; meeting-id/url open the
    /// link; unknown shows a hint and never dials).
    public var canJoinInApp: Bool { kind == "thread" }

    public var canOpenExternally: Bool { kind == "meeting-id" || kind == "url" }
}

/// `{ok,target}` from Swift `JoinParse` (was core FFI).
public struct JoinParseResponse: Decodable, Sendable {
    public let ok: Bool
    public let target: JoinTarget
}

// MARK: - Conversation (om-conv lane)

/// One chat message. Wire format from core `ostmac_messages`:
/// `{"id","sender","timestamp","content"}`.
/// `isOwn` is host-side only (core never sends it; defaults false) and
/// drives bubble alignment. The realtime lane feeds this same model into
/// `ConversationStore.ingest(_:)`; matching `id` => in-place edit update.
/// One grouped reaction count: picker emoji + number of reactors.
/// Wire format from core: `{"emoji","count","reactors"?}`. Absent on
/// old payloads. `reactors` (core-a who-reacted) may be shorter than
/// `count` — entries the wire does not name still count.
public struct ReactionCount: Codable, Sendable, Equatable {
    public let emoji: String
    public let count: Int
    /// Who reacted, when the wire names them (empty on old payloads).
    public let reactors: [Reactor]

    public init(emoji: String, count: Int, reactors: [Reactor] = []) {
        self.emoji = emoji
        self.count = count
        self.reactors = reactors
    }

    enum CodingKeys: String, CodingKey { case emoji, count, reactors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try c.decode(String.self, forKey: .emoji)
        count = try c.decode(Int.self, forKey: .count)
        reactors = try c.decodeIfPresent([Reactor].self, forKey: .reactors) ?? []
    }

    /// Reactor display names in wire order: the wire name, else the
    /// `resolve` lookup (roster by MRI / user id), else dropped — ids
    /// are never shown as names. Pure so the tooltip and tests share it.
    public func reactorNames(resolve: (String) -> String? = { _ in nil }) -> [String] {
        reactors.compactMap { r in
            let wire = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !wire.isEmpty { return wire }
            let looked = resolve(r.id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return looked.isEmpty ? nil : looked
        }
    }
}

/// One reactor (core-a). `id` is an MRI (`8:orgid:<guid>`, native
/// chat service) or a Graph user id; `name` is "" when the wire has
/// none (resolve through `ChatRosterStore.displayName(forID:)`).
public struct Reactor: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String = "") {
        self.id = id
        self.name = name
    }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sender: String
    public let timestamp: String
    public var content: String
    public var isOwn: Bool
    /// Unstripped server HTML (om-convrich): mention/code mining source.
    /// Absent on old payloads, realtime ingests, and local echoes.
    public var raw: String?
    /// Host-side: set when a realtime edit rewrites `content`.
    public var edited: Bool
    /// Grouped reaction counts (om-reactions). Empty on old payloads,
    /// realtime ingests without counts, and local echoes.
    public var reactions: [ReactionCount]
    /// Parent message id for quote replies (om-replies): mined by core
    /// from the `<quote guid>` block; absent on old payloads and
    /// non-reply bubbles.
    public var reply_to: String?
    /// Deleted tombstone (fid-msgs D12): Teams keeps a gray italic
    /// "This message has been deleted." bubble instead of removing the
    /// row. Host-side only (never decoded — the wire drops deletes).
    public var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, sender, timestamp, content, raw, reactions, reply_to
    }

    public init(
        id: String, sender: String, timestamp: String,
        content: String, isOwn: Bool = false,
        raw: String? = nil, edited: Bool = false,
        reactions: [ReactionCount] = [],
        reply_to: String? = nil, deleted: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.content = content
        self.isOwn = isOwn
        self.raw = raw
        self.edited = edited
        self.reactions = reactions
        self.reply_to = reply_to
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        content = try c.decode(String.self, forKey: .content)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        reactions = try c.decodeIfPresent([ReactionCount].self, forKey: .reactions) ?? []
        reply_to = try c.decodeIfPresent(String.self, forKey: .reply_to)
        isOwn = false
        edited = false
        deleted = false
    }

    /// "2026-09-22T12:53:06.9690000Z" -> local clock today ("12:53 PM"
    /// en_US) or "12:53 PM 22 Sep" older. Falls back to the raw prefix
    /// when the timestamp is missing/odd.
    public var displayTime: String {
        Self.shortTime(timestamp)
    }

    /// Server stamp -> local display clock (fid-time D8/D9): parsed to
    /// a Date, rendered in `timeZone` with the locale short style.
    public static func shortTime(
        _ iso: String, now: Date = Date(),
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 16 else {
            return trimmed.isEmpty ? "?" : trimmed
        }
        if let date = TeamsTime.parseISO(trimmed) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let clock = TeamsTime.clock(date, timeZone: timeZone, locale: locale)
            if cal.isDate(date, inSameDayAs: now) { return clock }
            return "\(clock) \(TeamsTime.dayMonth(date, timeZone: timeZone))"
        }
        // Garbage >= 16 chars: legacy fixed-offset slice (unchanged
        // shape; unparseable stamps never gain a shifted day).
        let datePart = String(trimmed.prefix(10))
        let clockPart: String = {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: 11)
            let end = trimmed.index(idx, offsetBy: 5, limitedBy: trimmed.endIndex)
            return end.map { String(trimmed[idx ..< $0]) } ?? String(trimmed.dropFirst(11).prefix(5))
        }()
        let today: String = TeamsTime.dayKey(now, timeZone: timeZone)
        if datePart == today { return clockPart }
        let monthDay: String = {
            let parts = datePart.split(separator: "-")
            guard parts.count == 3 else { return datePart }
            let months = [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ]
            let m = Int(parts[1]).flatMap { (1 ... 12).contains($0) ? months[$0 - 1] : nil } ?? String(parts[1])
            return "\(Int(parts[2]) ?? 0) \(m)"
        }()
        return "\(clockPart) \(monthDay)"
    }
}

/// O(n) id indexes over one thread (om-s6-renderparse). The timeline
/// builds one per body-eval and shares it across its quote, receipt,
/// and strip lookups instead of scanning per bubble. First id wins,
/// matching `first(where:)` / `firstIndex(where:)` on duplicate ids.
public struct MessageIndex: Sendable {
    public let byID: [String: ChatMessage]
    public let position: [String: Int]

    public init(_ messages: [ChatMessage]) {
        var by: [String: ChatMessage] = [:]
        var pos: [String: Int] = [:]
        by.reserveCapacity(messages.count)
        pos.reserveCapacity(messages.count)
        for (i, m) in messages.enumerated() {
            if by[m.id] == nil {
                by[m.id] = m
                pos[m.id] = i
            }
        }
        self.byID = by
        self.position = pos
    }
}

public struct MessagesResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let messages: [ChatMessage]
    /// Opaque cursor for the next older page; nil when history is exhausted.
    /// Absent (nil) on old core builds — treat as end of history.
    public let page_token: String?

    /// Host-side construction (demo data, MCP mocks). Wire decoding is untouched.
    public init(ok: Bool, chat_id: String?, messages: [ChatMessage], page_token: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.messages = messages
        self.page_token = page_token
    }
}

public struct SendResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?

    /// Host-side construction (MCP mocks). Wire decoding is untouched.
    public init(ok: Bool, chat_id: String?) {
        self.ok = ok
        self.chat_id = chat_id
    }
}

/// `{ok,chat_id,message_id}` from `ostmac_edit`.
public struct EditResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

/// `{ok,chat_id,message_id}` from `ostmac_delete`.
public struct DeleteResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

// MARK: - Leave chat (om-leave-block lane)

/// `{ok,chat_id}` from `ostmac_leave` (self removed from the thread roster).
public struct LeaveResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?

    public init(ok: Bool, chat_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
    }
}

// MARK: - Read receipts (om-receipts lane)

/// `{ok,chat_id,message_id}` from `ostmac_mark_read`.
public struct MarkReadResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

/// One peer read position from core `ostmac_receipts`.
/// `user` is the peer key (MRI/id, "" when unknown); `message_id` is the
/// last-read frontier; `horizon` is the raw server value.
public struct ReadReceipt: Decodable, Sendable, Equatable {
    public let user: String
    public let message_id: String
    public let horizon: String?

    public init(user: String, message_id: String, horizon: String? = nil) {
        self.user = user
        self.message_id = message_id
        self.horizon = horizon
    }
}

public struct ReceiptsResponse: Decodable, Sendable {
    public let ok: Bool
    public let thread_id: String?
    public let receipts: [ReadReceipt]

    public init(ok: Bool, thread_id: String? = nil, receipts: [ReadReceipt] = []) {
        self.ok = ok
        self.thread_id = thread_id
        self.receipts = receipts
    }
}

// MARK: - Message search (om-ja-search lane: Graph /search/query)

/// One message hit from core `ostmac_search`. `chatID` is the conversation
/// to open (the chat thread, or the channel id for channel hits, which
/// carry no chat id). `id` composites both so rows stay unique when two
/// chats share a message id.
public struct SearchHit: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { "\(chatID):\(messageID)" }
    public let messageID: String
    public let chatID: String
    public let teamID: String?
    public let channelID: String?
    public let sender: String
    public let timestamp: String
    public let preview: String
    public let subject: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case chatID = "chat_id"
        case teamID = "team_id"
        case channelID = "channel_id"
        case sender, timestamp, preview, subject
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        messageID: String, chatID: String,
        teamID: String? = nil, channelID: String? = nil,
        sender: String, timestamp: String,
        preview: String, subject: String? = nil
    ) {
        self.messageID = messageID
        self.chatID = chatID
        self.teamID = teamID
        self.channelID = channelID
        self.sender = sender
        self.timestamp = timestamp
        self.preview = preview
        self.subject = subject
    }

    /// Server stamp shifted to local (ChatMessage rules; "9:12 AM 22 Sep" en_US/UTC).
    public var displayTime: String {
        ChatMessage.shortTime(timestamp)
    }
}

/// One `from`/`size` window from core `ostmac_search`. `next_from` (nil
/// when exhausted) chains the next window via `from`.
public struct SearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let from: Int?
    public let size: Int?
    public let total: Int?
    public let more: Bool
    public let next_from: Int?
    public let hits: [SearchHit]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        ok: Bool, query: String? = nil, from: Int? = nil, size: Int? = nil,
        total: Int? = nil, more: Bool, next_from: Int? = nil, hits: [SearchHit]
    ) {
        self.ok = ok
        self.query = query
        self.from = from
        self.size = size
        self.total = total
        self.more = more
        self.next_from = next_from
        self.hits = hits
    }
}

// MARK: - Rich media (om-richmedia lane)

/// One fetched inline image: base64 bytes + the server's content type.
public struct MediaResponse: Decodable, Sendable {
    public let ok: Bool
    public let data_base64: String
    public let content_type: String?

    /// Host-side construction (tests, mock fetchers). Wire decoding untouched.
    public init(ok: Bool, data_base64: String, content_type: String? = nil) {
        self.ok = ok
        self.data_base64 = data_base64
        self.content_type = content_type
    }
}

// MARK: - Shared files (om-shared lane)

/// One shared file from core `ostmac_files` (Graph driveItem projection).
/// `download_url` is a pre-authenticated short-lived URL: Swift downloads
/// directly (no bearer). `drive_id`+`id` drive `ostmac_files_download`
/// when the pre-signed URL expired.
public struct SharedFile: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let mime: String?
    public let web_url: String?
    public let download_url: String?
    public let drive_id: String?
    public let created: String?
    public let modified: String?
    public let sender: String?
    /// File-attachment GUID from the driveItem eTag (om-inline-docs): the
    /// bubble-match key for `<attachment id>` refs. Nil on old core builds
    /// and for items whose eTag carries no GUID.
    public let attachment_id: String?
    /// Folder flag from core `is_folder` (om-i5-folders). Nil on old core
    /// payloads (no key) — decode with `isFolder`, never force-unwrap.
    public let is_folder: Bool?
    /// Sharing link from createLink (om-i1-links). Nil at list time: core
    /// never fills it; the store caches the created link per file id.
    /// Optional so old core payloads (no key) still decode.
    public let share_url: String?
    /// Conversation the file was shared in ("Design Sync",
    /// "Team > #General"): stamped by the Files list per leg and by file
    /// search from the Files index (core-b). Nil when unknown (drive-only
    /// files, search hits outside the indexed conversations).
    public let source_name: String?
    /// Chat/channel id of `source_name` (jump target). Nil when unknown.
    public let source_id: String?

    public init(
        id: String, name: String, size: UInt64 = 0,
        mime: String? = nil, web_url: String? = nil,
        download_url: String? = nil, drive_id: String? = nil,
        created: String? = nil, modified: String? = nil,
        sender: String? = nil, attachment_id: String? = nil,
        is_folder: Bool? = nil, share_url: String? = nil,
        source_name: String? = nil, source_id: String? = nil
    ) {
        self.source_name = source_name
        self.source_id = source_id
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
        self.web_url = web_url
        self.download_url = download_url
        self.drive_id = drive_id
        self.created = created
        self.modified = modified
        self.sender = sender
        self.attachment_id = attachment_id
        self.is_folder = is_folder
        self.share_url = share_url
    }

    /// Copy with a sharing link attached (store caches createLink results).
    public func withShareURL(_ url: String) -> SharedFile {
        SharedFile(
            id: id, name: name, size: size, mime: mime,
            web_url: web_url, download_url: download_url,
            drive_id: drive_id, created: created, modified: modified,
            sender: sender, attachment_id: attachment_id,
            is_folder: is_folder, share_url: url, source_name: source_name,
            source_id: source_id
        )
    }

    /// Copy naming the conversation it was shared in.
    public func withSourceName(_ source: String) -> SharedFile {
        SharedFile(
            id: id, name: name, size: size, mime: mime,
            web_url: web_url, download_url: download_url,
            drive_id: drive_id, created: created, modified: modified,
            sender: sender, attachment_id: attachment_id,
            is_folder: is_folder, share_url: share_url, source_name: source,
            source_id: source_id
        )
    }

    /// Copy naming the conversation it was shared in, with its id.
    public func withSource(name: String?, id: String?) -> SharedFile {
        SharedFile(
            id: self.id, name: self.name, size: size, mime: mime,
            web_url: web_url, download_url: download_url,
            drive_id: drive_id, created: created, modified: modified,
            sender: sender, attachment_id: attachment_id,
            is_folder: is_folder, share_url: share_url, source_name: name,
            source_id: id
        )
    }

    /// True when core marked this item a folder. Missing key (old core)
    /// reads as file.
    public var isFolder: Bool { is_folder == true }

    /// "48211" -> "48 KB": Finder's file-size wording
    /// (`ByteCountFormatter`, `.file` count style, localized).
    public var sizeLabel: String {
        Self.sizeLabel(size)
    }

    public static func sizeLabel(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: Int64(clamping: bytes))
    }

    /// SF Symbol for the mime/extension (doc, image, film, music, archive).
    public var iconName: String {
        Self.iconName(mime: mime, filename: name)
    }

    public static func iconName(mime: String?, filename: String) -> String {
        let m = (mime ?? "").lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("audio/") { return "music.note" }
        if m == "application/pdf" { return "doc.richtext" }
        if m.contains("zip") || m.contains("tar") || m.contains("gzip") { return "archivebox" }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        case "doc", "docx", "pages", "txt", "md": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }
}

public struct SharedFilesResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let files: [SharedFile]

    public init(ok: Bool, chat_id: String? = nil, files: [SharedFile]) {
        self.ok = ok
        self.chat_id = chat_id
        self.files = files
    }
}

public struct SharedFileUploadResponse: Decodable, Sendable {
    public let ok: Bool
    public let file: SharedFile
}

public struct SharedFileDownloadResponse: Decodable, Sendable {
    public let ok: Bool
    public let path: String
    public let bytes: UInt64
}

/// One folder's children from core `ostmac_files_children`
/// (om-i5-folders): files AND subfolders, unfiltered. Folders drill in
/// via `sharedChildren(driveID:itemID:)` with their own `drive_id`+`id`.
public struct SharedFileChildrenResponse: Decodable, Sendable {
    public let ok: Bool
    public let drive_id: String?
    public let item_id: String?
    public let files: [SharedFile]

    public init(ok: Bool, drive_id: String? = nil, item_id: String? = nil, files: [SharedFile]) {
        self.ok = ok
        self.drive_id = drive_id
        self.item_id = item_id
        self.files = files
    }
}

/// Sharing-link result from core `ostmac_files_link` (om-i1-links):
/// view-only link for one driveItem. `scope` echoes the applied scope
/// (organization|anonymous).
public struct SharedFileLinkResponse: Decodable, Sendable {
    public let ok: Bool
    public let link: String
    public let scope: String?

    public init(ok: Bool, link: String, scope: String? = nil) {
        self.ok = ok
        self.link = link
        self.scope = scope
    }
}

// MARK: - Drive recents (top10-files lane)

/// One drive-recents window from core `ostmac_files_recents`:
/// `{"ok","files":[...]}`. Rows reuse ``SharedFile`` (the Shared tab
/// shape), files only, sender None — the unified Files surface's
/// OneDrive/SharePoint leg.
public struct DriveRecentsResponse: Decodable, Sendable {
    public let ok: Bool
    public let files: [SharedFile]

    /// Host-side construction (demo data, mock fetchers).
    public init(ok: Bool, files: [SharedFile]) {
        self.ok = ok
        self.files = files
    }
}

// MARK: - File + people search (om-jb-filesearch lane)

/// One OneDrive search window from core `ostmac_file_search`:
/// `{"ok","query","files":[...]}`. Rows reuse ``SharedFile`` (the
/// Shared tab shape), so palette rows render with `iconName`/`sizeLabel`.
public struct FileSearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let files: [SharedFile]

    /// Host-side construction (demo data, mock searchers).
    public init(ok: Bool, query: String? = nil, files: [SharedFile]) {
        self.ok = ok
        self.query = query
        self.files = files
    }
}

/// One directory search window from core `ostmac_people_search`:
/// `{"ok","query","people":[...]}`. Rows reuse ``TeamMember`` (the
/// roster shape) with empty roles — directory hits carry no team role.
public struct PeopleSearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let people: [TeamMember]

    /// Host-side construction (demo data, mock searchers).
    public init(ok: Bool, query: String? = nil, people: [TeamMember]) {
        self.ok = ok
        self.query = query
        self.people = people
    }
}

// MARK: - File versions (om-i2-versions lane)

/// One file version from core `ostmac_file_versions` (Graph
/// driveItemVersion projection, newest first). `modified_by` is the
/// last-modifier display name; both optionals are nil on sparse items.
public struct FileVersion: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let size: UInt64
    public let modified: String?
    public let modified_by: String?

    public init(
        id: String, size: UInt64 = 0,
        modified: String? = nil, modified_by: String? = nil
    ) {
        self.id = id
        self.size = size
        self.modified = modified
        self.modified_by = modified_by
    }

    /// "48211" -> "47.1 KB" (shared files scale).
    public var sizeLabel: String {
        SharedFile.sizeLabel(size)
    }

    /// "v3.0 · Megan Harper · 10:00 AM 20 Sep" (known parts
    /// only; the stamp renders in the chat-timestamp style, smoke
    /// F8 — never raw ISO).
    public var subtitle: String {
        var parts = ["v\(id)"]
        if let by = modified_by, !by.isEmpty { parts.append(by) }
        if let m = modified, !m.isEmpty {
            parts.append(ChatMessage.shortTime(m))
        }
        return parts.joined(separator: " · ")
    }
}

public struct FileVersionsResponse: Decodable, Sendable {
    public let ok: Bool
    public let drive_id: String?
    public let item_id: String?
    public let versions: [FileVersion]

    public init(
        ok: Bool, drive_id: String? = nil, item_id: String? = nil,
        versions: [FileVersion]
    ) {
        self.ok = ok
        self.drive_id = drive_id
        self.item_id = item_id
        self.versions = versions
    }
}

public struct FileVersionRestoreResponse: Decodable, Sendable {
    public let ok: Bool
    public let drive_id: String?
    public let item_id: String?
    public let version_id: String?

    public init(
        ok: Bool, drive_id: String? = nil, item_id: String? = nil,
        version_id: String? = nil
    ) {
        self.ok = ok
        self.drive_id = drive_id
        self.item_id = item_id
        self.version_id = version_id
    }
}

/// Rename/move result from core (updated driveItem projection).
public struct SharedFileManageResponse: Decodable, Sendable {
    public let ok: Bool
    public let file: SharedFile

    public init(ok: Bool, file: SharedFile) {
        self.ok = ok
        self.file = file
    }
}

/// Copy result from core: Graph copies async, `monitor` is the 202
/// Location URL ("" when the server omits it).
public struct SharedFileCopyResponse: Decodable, Sendable {
    public let ok: Bool
    public let monitor: String

    public init(ok: Bool, monitor: String) {
        self.ok = ok
        self.monitor = monitor
    }
}

/// Delete result from core (echoes the removed item id).
public struct SharedFileDeleteResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String

    public init(ok: Bool, id: String) {
        self.ok = ok
        self.id = id
    }
}

/// Upload-progress gauge from core `ostmac_files_upload_progress`
/// (om-i4-bigup): pure read, polled while an upload spinner runs.
/// `active` is true only while a core upload is in flight.
public struct UploadProgressResponse: Decodable, Sendable {
    public let ok: Bool
    public let uploaded: UInt64
    public let total: UInt64
    public let percent: UInt64
    public let active: Bool

    /// Host-side construction (mock progress fetchers).
    public init(ok: Bool, uploaded: UInt64, total: UInt64, percent: UInt64, active: Bool) {
        self.ok = ok
        self.uploaded = uploaded
        self.total = total
        self.percent = percent
        self.active = active
    }
}

// MARK: - Presence (om-presence lane)

/// Own presence from `CoreReads.presence` / `ostmac_presence_set`
/// (Graph /me/presence): availability ∈ Available, Busy, DoNotDisturb,
/// Away, Offline, PresenceUnknown (+ future server values, passed through).
public struct PresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, availability: String, activity: String) {
        self.ok = ok
        self.availability = availability
        self.activity = activity
    }
}

/// One other user's presence from core `ostmac_presence_user`
/// (Graph /users/{id}/presence). Same shape as own, plus the echoed id.
public struct UserPresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String, availability: String, activity: String) {
        self.ok = ok
        self.id = id
        self.availability = availability
        self.activity = activity
    }
}

// MARK: - MRI resolution (om-steal-ids lane)

/// Graph user behind a Teams MRI, from core `ostmac_resolve_mri`
/// (Graph /users/{aad-oid}). `email` is nil for guests (no mail).
public struct ResolveMriResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let email: String?
    public let display_name: String

    /// Host-side construction (mock fetchers, caches).
    public init(ok: Bool, id: String, email: String?, display_name: String) {
        self.ok = ok
        self.id = id
        self.email = email
        self.display_name = display_name
    }
}

// MARK: - Token health (om-steal-ids lane)

/// One timed probe in a health report (port of teams-access
/// `HealthProbeResult`: name/ok/status/detail/durationMs).
public struct HealthProbe: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let status: Int?
    public let detail: String
    public let durationMs: Int

    public init(name: String, ok: Bool, status: Int? = nil, detail: String, durationMs: Int) {
        self.name = name
        self.ok = ok
        self.status = status
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Overall health verdict (teams-access `overall`, verbatim).
public enum HealthOverall: String, Sendable {
    case ok, degraded, broken
}

/// One audience token slot in a health report (offline, from status).
public struct HealthToken: Sendable, Equatable {
    public let audience: String
    public let present: Bool
    public let expired: Bool

    public init(audience: String, present: Bool, expired: Bool) {
        self.audience = audience
        self.present = present
        self.expired = expired
    }

    public var state: String {
        !present ? "missing" : expired ? "expired" : "fresh"
    }
}

/// Full diagnostics report: offline per-audience token slots + live
/// probe results + verdict. Built host-side (no core envelope).
public struct HealthReport: Sendable {
    public let overall: HealthOverall
    public let tokens: [HealthToken]
    public let probes: [HealthProbe]
    public let accountUPN: String?

    public init(overall: HealthOverall, tokens: [HealthToken], probes: [HealthProbe], accountUPN: String? = nil) {
        self.overall = overall
        self.tokens = tokens
        self.probes = probes
        self.accountUPN = accountUPN
    }
}

// MARK: - Notes (om-notes lane: OneNote read + paragraph append)

/// One OneNote notebook. Wire format from core `ostmac_notes`:
/// `{"id","name"}`.
public struct NotebookItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { notebookId }
    public let notebookId: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case notebookId = "id"
        case name
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(notebookId: String, name: String) {
        self.notebookId = notebookId
        self.name = name
    }
}

public struct NotebooksResponse: Decodable, Sendable {
    public let ok: Bool
    public let notebooks: [NotebookItem]

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, notebooks: [NotebookItem]) {
        self.ok = ok
        self.notebooks = notebooks
    }
}

/// One OneNote page (metadata; content arrives via `ostmac_note_page`).
public struct NotePageItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { pageId }
    public let pageId: String
    public let title: String
    public let updated: String?

    enum CodingKeys: String, CodingKey {
        case pageId = "id"
        case title, updated
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(pageId: String, title: String, updated: String? = nil) {
        self.pageId = pageId
        self.title = title
        self.updated = updated
    }
}

/// One OneNote section with its pages (nested by core to save round trips).
public struct NoteSectionItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { sectionId }
    public let sectionId: String
    public let name: String
    public let pages: [NotePageItem]

    enum CodingKeys: String, CodingKey {
        case sectionId = "id"
        case name, pages
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(sectionId: String, name: String, pages: [NotePageItem]) {
        self.sectionId = sectionId
        self.name = name
        self.pages = pages
    }
}

public struct NoteSectionsResponse: Decodable, Sendable {
    public let ok: Bool
    public let sections: [NoteSectionItem]

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, sections: [NoteSectionItem]) {
        self.ok = ok
        self.sections = sections
    }
}

/// One page's content. `title` is empty when the page ships no `<title>`.
public struct NotePageResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let title: String
    public let html: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String, title: String, html: String) {
        self.ok = ok
        self.id = id
        self.title = title
        self.html = html
    }
}

/// `{ok,id}` after a paragraph append.
public struct NoteAppendResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String) {
        self.ok = ok
        self.id = id
    }
}

// MARK: - Calls (om-signal lane: signaling only, no audio/video)

/// One call record from core `ostmac_call_*`. `state` is
/// placing|ringing|connected|ended|failed; `dir` is in|out.
public struct CallInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let dir: String
    public let peer: String
    public let peerName: String
    public let thread: String
    public let state: String
    public let controller: String?
    public let startedAt: UInt64
    public let detail: String?
    /// True once the live media engine (ICE/SRTP/RTP) is attached.
    public let liveMedia: Bool?
    /// Unix seconds the call reached `connected` (core-stamped at accept /
    /// callee answer). The call-duration origin; `startedAt` is ring or
    /// placement time. Nil until connected.
    public let connectedAt: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, dir, peer, thread, state, controller, detail
        case peerName = "peer_name"
        case startedAt = "started_at"
        case liveMedia = "live_media"
        case connectedAt = "connected_at"
    }

    /// Duration origin: `connectedAt` as a Date (nil until connected).
    public var connectedDate: Date? {
        connectedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var isActive: Bool {
        state == "placing" || state == "ringing" || state == "connected"
    }

    public var displayPeer: String {
        peerName.isEmpty ? (peer.isEmpty ? thread : peer) : peerName
    }

    public init(
        id: String, dir: String, peer: String, peerName: String = "",
        thread: String = "", state: String, controller: String? = nil,
        startedAt: UInt64 = 0, detail: String? = nil, liveMedia: Bool? = nil,
        connectedAt: UInt64? = nil
    ) {
        self.id = id
        self.dir = dir
        self.peer = peer
        self.peerName = peerName
        self.thread = thread
        self.state = state
        self.controller = controller
        self.startedAt = startedAt
        self.detail = detail
        self.liveMedia = liveMedia
        self.connectedAt = connectedAt
    }
}

/// `{ok, call?}` from `ostmac_call_status`.
public struct CallStatus: Decodable, Sendable {
    public let ok: Bool
    public let call: CallInfo?
}

/// Place/accept/end envelope. Only the keys the action sets are read;
/// the rest stay nil (one shape for all call actions).
public struct CallResult: Decodable, Sendable {
    public let ok: Bool
    public let placed: Bool?
    public let accepted: Bool?
    public let ended: Bool?
    public let injected: Bool?
    public let mediaAnswered: Bool?
    public let liveMedia: Bool?
    public let rejection: String?
    public let responseBytes: Int?
    public let call: CallInfo?

    enum CodingKeys: String, CodingKey {
        case ok, placed, accepted, ended, injected, rejection, call
        case mediaAnswered = "media_answered"
        case liveMedia = "live_media"
        case responseBytes = "response_bytes"
    }

    /// Host-side construction (demo joins, mock runners). Wire decoding is untouched.
    public init(
        ok: Bool, placed: Bool? = nil, accepted: Bool? = nil,
        ended: Bool? = nil, injected: Bool? = nil,
        mediaAnswered: Bool? = nil, liveMedia: Bool? = nil,
        rejection: String? = nil, responseBytes: Int? = nil,
        call: CallInfo? = nil
    ) {
        self.ok = ok
        self.placed = placed
        self.accepted = accepted
        self.ended = ended
        self.injected = injected
        self.mediaAnswered = mediaAnswered
        self.liveMedia = liveMedia
        self.rejection = rejection
        self.responseBytes = responseBytes
        self.call = call
    }
}

/// One typed call event from the feed (`calls[]` in the typed poll).
/// `kind` is incoming|end|rejected.
public struct CallEvent: Decodable, Sendable, Equatable {
    public let kind: String
    public let callID: String
    public let peer: String
    public let peerName: String
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case kind, peer, detail
        case callID = "call_id"
        case peerName = "peer_name"
    }

    public init(kind: String, callID: String, peer: String = "", peerName: String = "", detail: String? = nil) {
        self.kind = kind
        self.callID = callID
        self.peer = peer
        self.peerName = peerName
        self.detail = detail
    }
}

/// Minimal Any-Decodable for opaque Trouter event payloads.
public struct AnyJSON: Decodable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let n = try? c.decode(Int.self) { value = String(n); return }
        if let b = try? c.decode(Bool.self) { value = String(b); return }
        if let a = try? c.decode([AnyJSON].self) {
            value = "[" + a.map(\.value).joined(separator: ",") + "]"; return
        }
        if let o = try? c.decode([String: AnyJSON].self) {
            value = "{" + o.map { "\($0):\($1.value)" }.joined(separator: ",") + "}"
            return
        }
        if c.decodeNil() { value = "null"; return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON")
    }
}

/// Decode success `T` or throw the envelope error.
public func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if let err = try? JSONDecoder().decode(CoreError.self, from: data),
       (try? JSONDecoder().decode(OkFlag.self, from: data))?.ok == false
    {
        throw CoreCallError.failed(err.message)
    }
    return try JSONDecoder().decode(type, from: data)
}

struct OkFlag: Decodable { let ok: Bool }

public enum CoreCallError: Error, Sendable {
    case failed(String)
    case badUTF8
}
