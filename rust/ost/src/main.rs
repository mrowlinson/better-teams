//! Teams CLI - Lightweight Microsoft Teams client
//!
//! A terminal-based Teams client for Linux.

mod api;
mod auth;
mod calling;
mod config;
mod event_hub;
mod models;
mod trouter;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Parser)]
#[command(name = "teams-cli")]
#[command(about = "Lightweight CLI client for Microsoft Teams", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Enable verbose logging
    #[arg(short, long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Authenticate with Microsoft Teams
    Login {
        /// Force interactive login even if cached token exists
        #[arg(short, long)]
        force: bool,
    },

    /// Log out and clear cached credentials
    Logout,

    /// Show current authentication status
    Status,

    /// List recent chats
    Chats {
        /// Maximum number of chats to show
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },

    /// Read messages from a chat
    Read {
        /// Chat thread ID (from `chats` output)
        chat_id: String,

        /// Maximum number of messages to show
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },

    /// Search Teams messages (Graph /search/query, first window)
    Search {
        /// Free-text query (KQL scope terms like from: allowed)
        query: String,

        /// Maximum hits to show (Graph caps at 25)
        #[arg(short, long, default_value = "25")]
        limit: usize,
    },

    /// Send a message
    Send {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Message content
        message: String,

        /// Reply to this message id (quote reply; parent resolved
        /// from the newest history page for attribution)
        #[arg(long)]
        reply_to: Option<String>,
    },

    /// Send a local PNG file as a sticker (AMS upload + sticker message)
    SendSticker {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Local PNG file to send as a sticker
        #[arg(short, long)]
        file: String,

        /// Sticker label (alt text; blank = "Sticker")
        #[arg(short, long, default_value = "")]
        label: String,
    },

    /// Add an emoji reaction to a message (one of 👍 ❤️ 😂 😮 😢 😠)
    React {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Server message id (from `read` JSON via library)
        #[arg(long)]
        message_id: String,

        /// Picker emoji (e.g. 👍)
        emoji: String,

        /// Remove instead of add
        #[arg(long)]
        remove: bool,
    },

    /// Edit one own message
    Edit {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Server message id (from `read -v` output)
        #[arg(long)]
        message_id: String,

        /// Replacement text
        message: String,
    },

    /// Delete one own message
    Delete {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Server message id (from `read -v` output)
        #[arg(long)]
        message_id: String,
    },

    /// Mark one conversation read up to a message
    MarkRead {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,

        /// Server message id (from `read -v` output; the read frontier)
        #[arg(long)]
        message_id: String,
    },

    /// Leave a group chat (remove self from the thread roster)
    Leave {
        /// Chat thread ID (from `chats` output)
        #[arg(short, long)]
        to: String,
    },

    /// List joined teams and their channels
    Teams,

    /// Create a team (private standard) via the Teams middle tier
    TeamsCreate {
        /// Team display name
        #[arg(long)]
        name: String,

        /// Team description (blank when omitted)
        #[arg(long)]
        description: Option<String>,
    },

    /// List a channel's pinned tabs (read-only)
    Tabs {
        /// Channel ID (from `teams` output)
        channel_id: String,
    },

    /// Dump every joined channel's tabs (one auth, read-only)
    TabsAll,

    /// Add a channel tab (website tab by default; --app for Planner/Forms).
    /// With --chat, adds to a chat instead (positional id is the chat id).
    TabsAdd {
        /// Channel id (from `teams` output), or chat id with --chat
        target: String,

        /// Tab display name
        #[arg(long)]
        name: String,

        /// Tab page URL (website tabs; seeds content + website addresses)
        #[arg(long)]
        url: Option<String>,

        /// Teams app id (default: built-in website app)
        #[arg(long)]
        app: Option<String>,

        /// Target is a chat id, not a channel id
        #[arg(long)]
        chat: bool,
    },

    /// Rename a channel tab (configure). With --chat, a chat tab.
    TabsRename {
        /// Channel id (from `teams` output), or chat id with --chat
        target: String,

        /// Tab id (from `tabs` output)
        #[arg(long)]
        tab: String,

        /// New display name
        #[arg(long)]
        name: String,

        /// Target is a chat id, not a channel id
        #[arg(long)]
        chat: bool,
    },

    /// Remove a channel tab. With --chat, a chat tab.
    TabsRemove {
        /// Channel id (from `teams` output), or chat id with --chat
        target: String,

        /// Tab id (from `tabs` output)
        #[arg(long)]
        tab: String,

        /// Target is a chat id, not a channel id
        #[arg(long)]
        chat: bool,
    },

    /// List my whiteboards (legacy Azure boards)
    WbList,

    /// Create one whiteboard (prints the created board)
    WbCreate {
        /// Board title (blank when omitted)
        #[arg(long)]
        title: Option<String>,
    },

    /// Open one whiteboard (prints the board)
    WbShow {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Rename one whiteboard (prints the updated board)
    WbRename {
        /// Board id (from `wb-list` output)
        board_id: String,

        /// New board title
        #[arg(long)]
        title: String,
    },

    /// Delete one whiteboard
    WbDelete {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Mint a share link on one whiteboard (prints the link)
    WbShare {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Fetch one whiteboard's share link (prints the link)
    WbShareShow {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Revoke one whiteboard's share link
    WbUnshare {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// List one whiteboard's collaborators
    WbCollaborators {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Read my permissions on one whiteboard
    WbMyPerms {
        /// Board id (from `wb-list` output)
        board_id: String,
    },

    /// Redeem a legacy whiteboard share token
    WbRedeem {
        /// Share token (from `wb-share` output)
        token: String,
    },

    /// Read one whiteboard content page (ink-sync read path)
    WbContent {
        /// Board id (from `wb-list` output)
        board_id: String,

        /// Next-page cursor (from a previous `wb-content` run)
        #[arg(long)]
        cursor: Option<String>,
    },

    /// Join one board file's delta session (ink-sync channel open)
    WbJoin {
        /// SharePoint site URL (from the drive locator)
        #[arg(long)]
        site: String,

        /// Drive id
        #[arg(long)]
        drive: String,

        /// Board file item id
        #[arg(long)]
        item: String,

        /// Full Authorization header value for the join body
        #[arg(long)]
        auth: String,
    },

    /// Print a board's Teams tab-config URLs (no network)
    WbTabUrl {
        /// Azure board id (with --token)
        #[arg(long)]
        board: Option<String>,

        /// Azure share token (with --board)
        #[arg(long)]
        token: Option<String>,

        /// Fluid board file web URL
        #[arg(long)]
        web_url: Option<String>,
    },

    /// Print a board's meeting participant URL (no network)
    WbMeetingUrl {
        /// Fluid board file web URL
        #[arg(long)]
        web_url: String,

        /// Participant may edit (else view-only)
        #[arg(long)]
        can_edit: bool,

        /// Proof token (ad-hoc access)
        #[arg(long)]
        proof_token: Option<String>,

        /// Fluid file id
        #[arg(long)]
        fluid_file_id: Option<String>,

        /// Annotation board
        #[arg(long)]
        annotation: bool,
    },

    /// Team roster (Graph /teams/{id}/members).
    /// Bare: list members + owners. --owners: owners only.
    /// --add <user-id-or-upn> [--owner]: add. --remove <membership-id>: remove.
    Members {
        /// Team id (from `teams` output)
        #[arg(long)]
        team: String,

        /// Show owners only (list mode)
        #[arg(long)]
        owners: bool,

        /// Add this user id or UPN to the team
        #[arg(long)]
        add: Option<String>,

        /// Grant the owner role with --add
        #[arg(long)]
        owner: bool,

        /// Remove this membership id (from list output) from the team
        #[arg(long)]
        remove: Option<String>,
    },

    /// Channel moderation (Graph beta read, chat-service thread-property
    /// write; standard channels only — General is service-restricted).
    /// Bare: show who can post/reply. With flags: set, then read back.
    /// --posts everyone|everyoneExceptGuests|moderators.
    /// --replies everyone|authorAndModerators.
    ChannelModeration {
        /// Team id (from `teams` output)
        #[arg(long)]
        team: String,

        /// Channel id (from `teams` output)
        #[arg(long)]
        channel: String,

        /// Who can start new posts
        #[arg(long)]
        posts: Option<String>,

        /// Who can reply to posts
        #[arg(long)]
        replies: Option<String>,
    },

    /// Team privacy switch (backing M365 group visibility).
    /// Bare: show Private/Public. --set private|public: flip, then read back.
    TeamVisibility {
        /// Team id (from `teams` output)
        #[arg(long)]
        team: String,

        /// Flip to `private` (invite-only) or `public`
        #[arg(long)]
        set: Option<String>,
    },

    /// Team lifecycle (team-admin): rename/re-describe, picture,
    /// archive/restore, delete. At least one action flag is required;
    /// --delete is irreversible (confirm first).
    Team {
        /// Team id (from `teams` output)
        #[arg(long)]
        team: String,

        /// Rename the team (PATCH /groups/{id} displayName)
        #[arg(long)]
        rename: Option<String>,

        /// Re-describe the team (PATCH /groups/{id} description)
        #[arg(long)]
        description: Option<String>,

        /// Set the team picture from an image file (PUT photo/$value)
        #[arg(long, value_name = "PATH")]
        photo: Option<String>,

        /// Archive the team (async server-side; re-list to confirm)
        #[arg(long)]
        archive: bool,

        /// Restore an archived team
        #[arg(long)]
        unarchive: bool,

        /// Delete the team (irreversible)
        #[arg(long)]
        delete: bool,
    },

    /// Private/shared channel management (Graph /teams/{id}/channels).
    /// --create NAME: create (needs --type + --owner for private/shared;
    /// --type defaults to standard). Otherwise the command targets the
    /// channel in --channel: bare lists members (+ --owners filters),
    /// --add adds, --remove removes a membership id, --archive archives,
    /// --unarchive restores.
    Channels {
        /// Team id (from `teams` output)
        #[arg(long)]
        team: String,

        /// Channel id (from `teams` output; member/archive ops)
        #[arg(long)]
        channel: Option<String>,

        /// Create a channel with this name
        #[arg(long)]
        create: Option<String>,

        /// Channel type for --create: standard, private or shared
        #[arg(long = "type", value_name = "TYPE")]
        ctype: Option<String>,

        /// Owner user id or UPN for --create (repeatable; private/shared
        /// need at least one; shared takes exactly one)
        #[arg(long, value_name = "USER")]
        owner: Vec<String>,

        /// Description for --create
        #[arg(long)]
        description: Option<String>,

        /// Show owners only (list mode)
        #[arg(long)]
        owners: bool,

        /// Add this user id or UPN to the channel
        #[arg(long)]
        add: Option<String>,

        /// Grant the owner role with --add
        #[arg(long)]
        owner_flag: bool,

        /// Remove this membership id (from list output) from the channel
        #[arg(long)]
        remove: Option<String>,

        /// Archive the channel (async server-side; re-read to confirm)
        #[arg(long)]
        archive: bool,

        /// Restore an archived channel
        #[arg(long)]
        unarchive: bool,
    },

    /// List shared files in a chat or channel
    Files {
        /// Chat or channel ID (from `chats` / `teams` output)
        chat_id: String,

        /// Maximum number of files to show
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },

    /// Download a shared file by drive+item id
    FilesDownload {
        /// Drive ID (from `files` JSON via library; shown in verbose logs)
        drive_id: String,

        /// DriveItem ID
        item_id: String,

        /// Destination file path
        out: String,
    },

    /// Upload a local file to a chat or channel (large files use a resumable session)
    FilesUpload {
        /// Chat or channel ID (from `chats` / `teams` output)
        #[arg(short, long)]
        to: String,

        /// Local file path
        path: String,
    },

    /// Create a view-only sharing link for a shared file
    FilesLink {
        /// Drive ID (from `files` list output)
        drive_id: String,

        /// DriveItem ID
        item_id: String,

        /// Link scope: organization (org-only, default) or anonymous
        #[arg(long, default_value = "organization")]
        scope: String,
    },

    /// Search OneDrive files by name/content (om-jb-filesearch)
    FileSearch {
        /// Free-text query
        query: String,

        /// Maximum number of files to show
        #[arg(short, long, default_value = "25")]
        limit: usize,
    },

    /// Search the directory for people (om-jb-filesearch)
    PeopleSearch {
        /// Free-text query (matches display name)
        query: String,

        /// Maximum number of people to show
        #[arg(short, long, default_value = "25")]
        limit: usize,
    },

    /// OneNote notebooks, sections, pages (read; --append edits)
    Notes {
        /// M365 group (team) id: read the team notebook instead of the user's
        #[arg(long)]
        group: Option<String>,

        /// Notebook id: list its sections and pages
        #[arg(long)]
        notebook: Option<String>,

        /// Page id: print page content (text)
        #[arg(long)]
        page: Option<String>,

        /// Append this paragraph to --page (requires --page)
        #[arg(long)]
        append: Option<String>,
    },

    /// Show current user info (verify auth works)
    Whoami,

    /// Connect to Trouter WebSocket push service
    Trouter,

    /// Get/set presence status
    Presence {
        /// New status: available, busy, dnd, away, offline
        #[arg(short, long)]
        set: Option<String>,
    },

    /// Microsoft To Do lists and tasks (Graph /me/todo).
    /// Bare: show lists. --list <id>: tasks in that list.
    /// --add <title> --to <id>: create. --done <task> --to <id>: complete.
    Todo {
        /// Show tasks for this list id (default: show lists)
        #[arg(long)]
        list: Option<String>,

        /// Maximum tasks to show
        #[arg(short, long, default_value = "50")]
        limit: usize,

        /// Create a task with this title (requires --to)
        #[arg(long)]
        add: Option<String>,

        /// Target list id for --add / --done
        #[arg(long)]
        to: Option<String>,

        /// Complete this task id (requires --to)
        #[arg(long)]
        done: Option<String>,
    },

    /// Upcoming Teams meetings (Graph calendarView, next 7 days).
    /// --parse <url-or-id> classifies a join string without network.
    Meetings {
        /// Maximum meetings to show
        #[arg(short, long, default_value = "20")]
        limit: usize,

        /// Classify a pasted join link / thread id (no network)
        #[arg(long)]
        parse: Option<String>,
    },

    /// Read one online meeting's attendance report (Graph, read-only)
    MeetingAttendance {
        /// Online meeting id (from the join URL or Graph)
        meeting_id: String,
    },

    /// Read one online meeting's server capture toggles (Graph, read-only)
    MeetingCapture {
        /// Online meeting id (from the join URL or Graph)
        meeting_id: String,
    },

    /// List a meeting's breakout rooms (MiddleTier, read-only)
    BreakoutRooms {
        /// Meeting coords JSON (tenant_id, organizer_id, thread_id,
        /// message_id, additional_message_id?)
        coords: String,
    },

    /// Create a meeting's breakout rooms (MiddleTier)
    BreakoutCreate {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Room count (1..=50)
        #[arg(short, long, default_value = "4")]
        count: usize,

        /// Preconfiguration JSON array (participants + room keys)
        #[arg(long)]
        preconfig: Option<String>,

        /// Settings JSON (room_duration, allow_* flags, managers)
        #[arg(long)]
        settings: Option<String>,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Add one breakout room (MiddleTier)
    BreakoutAdd {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// New room name
        #[arg(short, long)]
        name: String,

        /// Participants JSON array
        #[arg(short, long, default_value = "[]")]
        participants: String,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Read one breakout room (MiddleTier, read-only)
    BreakoutGet {
        /// Room coords JSON (see breakout-rooms)
        coords: String,
    },

    /// Update one breakout room: rename + assign/move roster (MiddleTier)
    BreakoutUpdate {
        /// Room coords JSON (see breakout-rooms)
        coords: String,

        /// Room name
        #[arg(short, long)]
        name: String,

        /// Participants JSON array (the room's full new roster)
        #[arg(short, long, default_value = "[]")]
        participants: String,

        /// Restrict chat access in the room
        #[arg(long)]
        restrict_chat_access: bool,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Delete one breakout room (MiddleTier)
    BreakoutDelete {
        /// Room coords JSON (see breakout-rooms)
        coords: String,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Delete all breakout rooms (MiddleTier)
    BreakoutDeleteAll {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Rooms-references JSON body (omit for a bodyless delete)
        #[arg(long)]
        rooms_refs: Option<String>,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Bulk assign/move participants across rooms (MiddleTier)
    BreakoutAssign {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Rooms JSON array (coordinates, roomName, participants,
        /// restrictChatAccess each)
        #[arg(short, long)]
        rooms: String,

        /// Total participant count (switches to the v2 shape)
        #[arg(long)]
        total_participants: Option<u64>,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Open 1..n breakout rooms (MiddleTier)
    BreakoutOpen {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Room coordinates JSON array
        #[arg(short, long)]
        rooms: String,

        /// Use the new timer flow
        #[arg(long)]
        new_timer_flow: bool,

        /// Total participant count
        #[arg(long)]
        total_participants: Option<u64>,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Close 1..n breakout rooms (MiddleTier)
    BreakoutClose {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Room coordinates JSON array
        #[arg(short, long)]
        rooms: String,

        /// Total participant count
        #[arg(long)]
        total_participants: Option<u64>,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Read a meeting's breakout settings (MiddleTier, read-only)
    BreakoutSettings {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,
    },

    /// Write a meeting's breakout settings (MiddleTier)
    BreakoutSettingsSet {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Settings JSON (allow_users_to_select_breakout_room,
        /// room_duration, managers, allow_join_back_to_main_meeting,
        /// allow_move_participants_automatically)
        #[arg(short, long)]
        settings: String,

        /// MT requestVersion (capture pin; omit when unknown)
        #[arg(long)]
        version: Option<String>,
    },

    /// Read a meeting's assignable breakout users (MiddleTier, read-only)
    BreakoutAssignees {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Calendar event id filter
        #[arg(long)]
        calendar_event_id: Option<String>,

        /// iCal UID filter
        #[arg(long)]
        ical_uid: Option<String>,

        /// Event type filter
        #[arg(long)]
        event_type: Option<String>,

        /// Team id filter
        #[arg(long)]
        team_id: Option<String>,

        /// Max nest level
        #[arg(long)]
        max_nest_level: Option<String>,

        /// User threshold
        #[arg(long)]
        user_threshold: Option<String>,
    },

    /// Announce a message into breakout rooms (MiddleTier)
    BreakoutAnnounce {
        /// Meeting coords JSON (see breakout-rooms)
        coords: String,

        /// Room thread ids, comma-separated
        #[arg(short, long)]
        rooms: String,

        /// Message text
        #[arg(short, long)]
        message: String,
    },

    /// Place a test call to yourself (self-call)
    CallTest {
        /// Duration in seconds to keep the call active
        #[arg(short, long, default_value = "15")]
        duration: u64,

        /// Enable call recording via recorder bot injection
        #[arg(long)]
        record: bool,

        /// Call the Echo / Call Quality Tester bot instead of channel meeting
        #[arg(long)]
        echo: bool,

        /// 1:1 chat thread ID to call (e.g., 19:guid1_guid2@unq.gbl.spaces)
        #[arg(long)]
        thread: Option<String>,

        /// Enable camera capture (V4L2) for video send (requires video-capture feature)
        #[arg(long)]
        camera: bool,

        /// Enable video display window for received video (requires video-capture feature)
        #[arg(long)]
        display: bool,

        /// Use 1kHz test tone instead of real microphone (debug mode)
        #[arg(long)]
        tone: bool,
    },

    /// Copilot chat probe (ChatHub transport, free tier first).
    /// `--print-frames`/`--replay` are offline; `--chat`/`--license-status`
    /// need tenant recovery (phase-2 P0/P4) and are never run blind.
    Copilot {
        /// Print the built handshake/ping/invocation frames for PROMPT (offline)
        #[arg(long)]
        print_frames: Option<String>,

        /// Parse one recorded server record and print the event (offline)
        #[arg(long)]
        replay: Option<String>,

        /// Run one live chat turn (phase 2 only)
        #[arg(long)]
        chat: Option<String>,

        /// Fetch the Taiger licence status (phase 2 only)
        #[arg(long)]
        license_status: bool,

        /// Token family: sydney (mapped) or substrate (P4 probe)
        #[arg(long, default_value = "sydney")]
        token_family: String,

        /// Model selector tone (capture-pin; default Magic = Auto)
        #[arg(long, default_value = "Magic")]
        tone: String,

        /// Extra optionsSets flags, repeatable (default: none = free tier)
        #[arg(long)]
        option_set: Vec<String>,

        /// Hub env: default, prod, sdf, msit, gcch, dod, teams2024
        #[arg(long, default_value = "default")]
        hub: String,
    },

    /// Test microphone capture: record 3 seconds then play back
    #[cfg(feature = "audio")]
    MicTest,

    /// Test camera capture: record 3 seconds then play back in SDL2 window
    #[cfg(feature = "video-capture")]
    CamTest,

    /// Loop/Fluid components (RE-mapped private surface, §126)
    Loop {
        #[command(subcommand)]
        action: LoopCommands,
    },
}

/// Loop sub-verbs: create (C1), page (C4), send (E1), read (S1/S2/S3),
/// sync (S4). Every verb takes --dry-run (prints the exact request,
/// no network, no auth) — the offline verification vehicle.
#[derive(Subcommand)]
enum LoopCommands {
    /// Create a Fluid file + container (C1)
    Create {
        /// SharePoint/OneDrive site origin (file's host)
        #[arg(long)]
        site: String,
        /// Drive id
        #[arg(long)]
        drive: String,
        /// Folder path in the drive
        #[arg(long, default_value = "Loop")]
        folder: String,
        /// File name (*.loop)
        #[arg(long)]
        file: String,
        /// Detached-container summary string (P2 captures the chat template)
        #[arg(long)]
        body: String,
        /// Single-request share-link params (createLinkScope/Role query)
        #[arg(long)]
        share: Option<String>,
        /// Print the request without sending it
        #[arg(long)]
        dry_run: bool,
    },

    /// Create a Loop page (C4 storage API)
    Page {
        /// Site URL for the storage id
        #[arg(long)]
        site: String,
        /// Drive id for the storage id
        #[arg(long)]
        drive: String,
        /// Page title
        #[arg(long)]
        title: String,
        /// Content type (e.g. html)
        #[arg(long)]
        content_type: String,
        /// Content value
        #[arg(long)]
        content: String,
        /// Page path
        #[arg(long, default_value = "/")]
        path: String,
        /// Print the request without sending it
        #[arg(long)]
        dry_run: bool,
    },

    /// Send a message carrying a Loop card (E1, cards-first)
    Send {
        /// Chat thread id
        #[arg(long)]
        to: String,
        /// Component URL from C3
        #[arg(long)]
        component_url: String,
        /// Accompanying text
        #[arg(long, default_value = "")]
        text: String,
        /// Print the request without sending it
        #[arg(long)]
        dry_run: bool,
    },

    /// Read a Loop page snapshot (S1: --host) or an ODSP snapshot
    /// (S2: --site) / ops range (S3: --site + --ops start:end)
    Read {
        /// Page host (S1)
        #[arg(long)]
        host: Option<String>,
        /// Drive id (S1/S2/S3)
        #[arg(long)]
        drive: Option<String>,
        /// Item id (S1/S2/S3)
        #[arg(long)]
        item: Option<String>,
        /// ODSP file site origin (S2/S3)
        #[arg(long)]
        site: Option<String>,
        /// Ops range start:end (S3; without it S2 loads)
        #[arg(long)]
        ops: Option<String>,
        /// Redeem link for single-round-trip S2
        #[arg(long)]
        share_link: Option<String>,
        /// Print the request without sending it
        #[arg(long)]
        dry_run: bool,
    },

    /// Join a collab session: socket creds for one file (S4)
    Sync {
        /// ODSP file site origin
        #[arg(long)]
        site: String,
        /// Drive id
        #[arg(long)]
        drive: String,
        /// Item id
        #[arg(long)]
        item: String,
        /// Print the request without sending it
        #[arg(long)]
        dry_run: bool,
    },
}

/// Print one request exactly as it would go out (loop --dry-run):
/// method + URL, headers, blank line, body. No network, no auth.
fn print_dry_run(method: &str, url: &str, headers: &[(&str, &str)], body: &str) {
    println!("{} {}", method, url);
    for (k, v) in headers {
        println!("{}: {}", k, v);
    }
    println!();
    println!("{}", body);
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let verbose = cli.verbose;

    let filter_str = if verbose { "debug" } else { "info" };

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| filter_str.into()),
        )
        .with(tracing_subscriber::fmt::layer().with_target(false))
        .init();

    match cli.command {
        Commands::Login { force } => {
            tracing::info!("Starting authentication flow...");
            auth::login(force).await?;
        }
        Commands::Logout => {
            tracing::info!("Logging out...");
            auth::logout().await?;
        }
        Commands::Status => {
            auth::status().await?;
        }
        Commands::Teams => {
            api::list_teams().await?;
        }
        Commands::TeamsCreate { name, description } => {
            tracing::info!("Creating team...");
            api::create_team(&name, description.as_deref()).await?;
        }
        Commands::Tabs { channel_id } => {
            tracing::info!("Fetching channel tabs...");
            api::list_tabs(&channel_id).await?;
        }
        Commands::TabsAll => {
            tracing::info!("Fetching all channel tabs...");
            api::list_tabs_all().await?;
        }
        Commands::TabsAdd { target, name, url, app, chat } => {
            tracing::info!("Adding tab...");
            if chat {
                api::add_chat_tab(&target, &name, app.as_deref(), url.as_deref()).await?;
            } else {
                api::add_channel_tab(&target, &name, app.as_deref(), url.as_deref()).await?;
            }
        }
        Commands::TabsRename { target, tab, name, chat } => {
            tracing::info!("Renaming tab...");
            if chat {
                api::rename_chat_tab(&target, &tab, &name).await?;
            } else {
                api::rename_channel_tab(&target, &tab, &name).await?;
            }
        }
        Commands::TabsRemove { target, tab, chat } => {
            tracing::info!("Removing tab...");
            if chat {
                api::remove_chat_tab(&target, &tab).await?;
            } else {
                api::remove_channel_tab(&target, &tab).await?;
            }
        }
        Commands::WbList => {
            tracing::info!("Fetching whiteboards...");
            api::list_whiteboards().await?;
        }
        Commands::WbCreate { title } => {
            tracing::info!("Creating whiteboard...");
            api::create_whiteboard(title.as_deref()).await?;
        }
        Commands::WbShow { board_id } => {
            tracing::info!("Fetching whiteboard...");
            api::show_whiteboard(&board_id).await?;
        }
        Commands::WbRename { board_id, title } => {
            tracing::info!("Renaming whiteboard...");
            api::rename_whiteboard(&board_id, &title).await?;
        }
        Commands::WbDelete { board_id } => {
            tracing::info!("Deleting whiteboard...");
            api::delete_whiteboard(&board_id).await?;
        }
        Commands::WbShare { board_id } => {
            tracing::info!("Sharing whiteboard...");
            api::share_whiteboard(&board_id).await?;
        }
        Commands::WbShareShow { board_id } => {
            tracing::info!("Fetching whiteboard share link...");
            api::show_share_link(&board_id).await?;
        }
        Commands::WbUnshare { board_id } => {
            tracing::info!("Revoking whiteboard share link...");
            api::revoke_share_link(&board_id).await?;
        }
        Commands::WbCollaborators { board_id } => {
            tracing::info!("Fetching whiteboard collaborators...");
            api::show_collaborators(&board_id).await?;
        }
        Commands::WbMyPerms { board_id } => {
            tracing::info!("Fetching whiteboard permissions...");
            api::show_my_permissions(&board_id).await?;
        }
        Commands::WbRedeem { token } => {
            tracing::info!("Redeeming whiteboard share token...");
            api::redeem_whiteboard(&token).await?;
        }
        Commands::WbContent { board_id, cursor } => {
            tracing::info!("Reading whiteboard content...");
            api::show_content(&board_id, cursor.as_deref()).await?;
        }
        Commands::WbJoin { site, drive, item, auth } => {
            tracing::info!("Joining whiteboard session...");
            api::join_whiteboard(&site, &drive, &item, &auth).await?;
        }
        Commands::WbTabUrl { board, token, web_url } => {
            api::show_tab_urls(board.as_deref(), token.as_deref(), web_url.as_deref()).await?;
        }
        Commands::WbMeetingUrl { web_url, can_edit, proof_token, fluid_file_id, annotation } => {
            api::show_meeting_url(
                &web_url,
                can_edit,
                proof_token.as_deref(),
                fluid_file_id.as_deref(),
                annotation,
            )
            .await?;
        }
        Commands::Members {
            team,
            owners,
            add,
            owner,
            remove,
        } => {
            if let Some(user) = add {
                if remove.is_some() {
                    anyhow::bail!("--add and --remove are exclusive");
                }
                tracing::info!("Adding team member...");
                api::add_team_member(&team, &user, owner).await?;
            } else if let Some(member) = remove {
                tracing::info!("Removing team member...");
                api::remove_team_member(&team, &member).await?;
            } else {
                api::list_team_members(&team, owners).await?;
            }
        }
        Commands::ChannelModeration {
            team,
            channel,
            posts,
            replies,
        } => {
            if posts.is_none() && replies.is_none() {
                api::show_moderation(&team, &channel).await?;
            } else {
                tracing::info!("Setting channel moderation...");
                api::set_moderation(&team, &channel, posts.as_deref(), replies.as_deref()).await?;
            }
        }
        Commands::TeamVisibility { team, set } => {
            match set.as_deref().map(|s| s.trim().to_ascii_lowercase()) {
                None => api::show_visibility(&team).await?,
                Some(which) if which.is_empty() => api::show_visibility(&team).await?,
                Some(which) if which == "private" || which == "public" => {
                    tracing::info!("Setting team visibility...");
                    api::set_visibility(&team, which == "private").await?;
                }
                Some(other) => anyhow::bail!("--set must be 'private' or 'public' (got '{}')", other),
            }
        }
        Commands::Team {
            team,
            rename,
            description,
            photo,
            archive,
            unarchive,
            delete,
        } => {
            if archive && unarchive {
                anyhow::bail!("--archive and --unarchive are exclusive");
            }
            if delete && (rename.is_some() || description.is_some() || photo.is_some() || archive || unarchive) {
                anyhow::bail!("--delete is exclusive with all other team actions");
            }
            let mut acted = false;
            if rename.is_some() || description.is_some() {
                tracing::info!("Updating team...");
                api::update_team(&team, rename.as_deref(), description.as_deref()).await?;
                acted = true;
            }
            if let Some(path) = photo {
                tracing::info!("Setting team photo...");
                api::set_team_photo(&team, &path).await?;
                acted = true;
            }
            if archive {
                tracing::info!("Archiving team...");
                api::archive_team(&team).await?;
                acted = true;
            }
            if unarchive {
                tracing::info!("Unarchiving team...");
                api::unarchive_team(&team).await?;
                acted = true;
            }
            if delete {
                tracing::info!("Deleting team...");
                api::delete_team(&team).await?;
                acted = true;
            }
            if !acted {
                anyhow::bail!("team: pass one of --rename/--description/--photo/--archive/--unarchive/--delete");
            }
        }

        Commands::Channels {
            team,
            channel,
            create,
            ctype,
            owner,
            description,
            owners,
            add,
            owner_flag,
            remove,
            archive,
            unarchive,
        } => {
            if let Some(name) = create {
                if channel.is_some()
                    || add.is_some()
                    || remove.is_some()
                    || archive
                    || unarchive
                {
                    anyhow::bail!("--create is exclusive with member/archive ops");
                }
                tracing::info!("Creating channel...");
                let owners_ref: Vec<&str> = owner.iter().map(String::as_str).collect();
                api::create_channel_typed(
                    &team,
                    &name,
                    description.as_deref(),
                    ctype.as_deref(),
                    &owners_ref,
                )
                .await?;
            } else if let Some(channel_id) = channel {
                let mut acted = false;
                if let Some(user) = add {
                    if remove.is_some() || archive || unarchive {
                        anyhow::bail!("--add is exclusive with --remove/--archive/--unarchive");
                    }
                    tracing::info!("Adding channel member...");
                    api::add_channel_member(&team, &channel_id, &user, owner_flag).await?;
                    acted = true;
                }
                if let Some(member) = remove {
                    if archive || unarchive {
                        anyhow::bail!("--remove is exclusive with --archive/--unarchive");
                    }
                    tracing::info!("Removing channel member...");
                    api::remove_channel_member(&team, &channel_id, &member).await?;
                    acted = true;
                }
                if archive {
                    if unarchive {
                        anyhow::bail!("--archive and --unarchive are exclusive");
                    }
                    tracing::info!("Archiving channel...");
                    api::archive_channel(&team, &channel_id).await?;
                    acted = true;
                }
                if unarchive {
                    tracing::info!("Unarchiving channel...");
                    api::unarchive_channel(&team, &channel_id).await?;
                    acted = true;
                }
                if !acted {
                    api::list_channel_members(&team, &channel_id, owners).await?;
                }
            } else {
                anyhow::bail!("pass --create NAME or --channel ID (see --help)");
            }
        }
        Commands::Files { chat_id, limit } => {
            tracing::info!("Fetching shared files...");
            api::list_files(&chat_id, limit).await?;
        }
        Commands::FilesDownload {
            drive_id,
            item_id,
            out,
        } => {
            api::download_file(&drive_id, &item_id, &out).await?;
        }
        Commands::FilesUpload { to, path } => {
            tracing::info!("Uploading file...");
            api::upload_file(&to, &path).await?;
        }
        Commands::FilesLink {
            drive_id,
            item_id,
            scope,
        } => {
            api::create_link(&drive_id, &item_id, &scope).await?;
        }
        Commands::FileSearch { query, limit } => {
            tracing::info!("Searching files...");
            api::search_files(&query, limit).await?;
        }
        Commands::PeopleSearch { query, limit } => {
            tracing::info!("Searching people...");
            api::search_people(&query, limit).await?;
        }
        Commands::Notes {
            group,
            notebook,
            page,
            append,
        } => {
            api::notes(
                group.as_deref(),
                notebook.as_deref(),
                page.as_deref(),
                append.as_deref(),
            )
            .await?;
        }
        Commands::Whoami => {
            api::whoami().await?;
        }
        Commands::Chats { limit } => {
            tracing::info!("Fetching chats...");
            api::list_chats(limit).await?;
        }
        Commands::Read { chat_id, limit } => {
            api::read_messages(&chat_id, limit, verbose).await?;
        }
        Commands::Send { to, message, reply_to } => {
            tracing::info!("Sending message...");
            match reply_to {
                Some(parent) => api::reply_message(&to, &parent, &message).await?,
                None => api::send_message(&to, &message).await?,
            }
        }
        Commands::SendSticker { to, file, label } => {
            tracing::info!("Sending sticker...");
            api::send_sticker(&to, &file, &label).await?;
        }
        Commands::React {
            to,
            message_id,
            emoji,
            remove,
        } => {
            api::react(&to, &message_id, &emoji, remove).await?;
        }
        Commands::Edit {
            to,
            message_id,
            message,
        } => {
            tracing::info!("Editing message...");
            api::edit_message(&to, &message_id, &message).await?;
        }
        Commands::Delete { to, message_id } => {
            tracing::info!("Deleting message...");
            api::delete_message(&to, &message_id).await?;
        }
        Commands::MarkRead { to, message_id } => {
            api::mark_read(&to, &message_id).await?;
        }
        Commands::Leave { to } => {
            tracing::info!("Leaving chat...");
            api::leave_chat(&to).await?;
        }
        Commands::Trouter => {
            trouter::connect_and_run().await?;
        }
        Commands::CallTest {
            duration,
            record,
            echo,
            thread,
            camera,
            display,
            tone,
        } => {
            calling::call_test::run_call_test(
                duration, record, echo, thread, camera, display, tone,
            )
            .await?;
        }
        #[cfg(feature = "audio")]
        Commands::MicTest => {
            calling::audio::mic_test()?;
        }
        #[cfg(feature = "video-capture")]
        Commands::CamTest => {
            calling::camera::cam_test()?;
        }
        Commands::Presence { set } => match set {
            Some(status) => {
                tracing::info!("Setting presence to {}...", status);
                api::set_presence(&status).await?;
            }
            None => {
                api::get_presence().await?;
            }
        },
        Commands::Todo {
            list,
            limit,
            add,
            to,
            done,
        } => {
            if let Some(title) = add {
                let Some(list_id) = to else {
                    anyhow::bail!("--add requires --to <list-id>");
                };
                tracing::info!("Creating To Do task...");
                api::create_todo_task(&list_id, &title).await?;
            } else if let Some(task_id) = done {
                let Some(list_id) = to else {
                    anyhow::bail!("--done requires --to <list-id>");
                };
                tracing::info!("Completing To Do task...");
                api::complete_todo_task(&list_id, &task_id).await?;
            } else if let Some(list_id) = list {
                api::list_todo_tasks(&list_id, limit).await?;
            } else {
                api::list_todo_lists().await?;
            }
        }
        Commands::Search { query, limit } => {
            api::search_messages(&query, limit).await?;
        }
        Commands::MeetingAttendance { meeting_id } => {
            api::show_meeting_attendance(&meeting_id).await?;
        }
        Commands::MeetingCapture { meeting_id } => {
            api::show_meeting_capture(&meeting_id).await?;
        }
        Commands::BreakoutRooms { coords } => {
            api::show_breakout_rooms(&coords).await?;
        }
        Commands::BreakoutCreate { coords, count, preconfig, settings, version } => {
            api::show_breakout_create(&coords, count, preconfig.as_deref(), settings.as_deref(), version.as_deref())
                .await?;
        }
        Commands::BreakoutAdd { coords, name, participants, version } => {
            api::show_breakout_add(&coords, &name, &participants, version.as_deref()).await?;
        }
        Commands::BreakoutGet { coords } => {
            api::show_breakout_get(&coords).await?;
        }
        Commands::BreakoutUpdate { coords, name, participants, restrict_chat_access, version } => {
            api::show_breakout_update(&coords, &name, &participants, restrict_chat_access, version.as_deref()).await?;
        }
        Commands::BreakoutDelete { coords, version } => {
            api::show_breakout_delete(&coords, version.as_deref()).await?;
        }
        Commands::BreakoutDeleteAll { coords, rooms_refs, version } => {
            api::show_breakout_delete_all(&coords, rooms_refs.as_deref(), version.as_deref()).await?;
        }
        Commands::BreakoutAssign { coords, rooms, total_participants, version } => {
            api::show_breakout_assign(&coords, &rooms, total_participants, version.as_deref()).await?;
        }
        Commands::BreakoutOpen { coords, rooms, new_timer_flow, total_participants, version } => {
            api::show_breakout_open(&coords, &rooms, new_timer_flow, total_participants, version.as_deref()).await?;
        }
        Commands::BreakoutClose { coords, rooms, total_participants, version } => {
            api::show_breakout_close(&coords, &rooms, total_participants, version.as_deref()).await?;
        }
        Commands::BreakoutSettings { coords } => {
            api::show_breakout_settings(&coords).await?;
        }
        Commands::BreakoutSettingsSet { coords, settings, version } => {
            api::show_breakout_settings_set(&coords, &settings, version.as_deref()).await?;
        }
        Commands::BreakoutAssignees {
            coords,
            calendar_event_id,
            ical_uid,
            event_type,
            team_id,
            max_nest_level,
            user_threshold,
        } => {
            api::show_breakout_assignees(
                &coords,
                calendar_event_id.as_deref(),
                ical_uid.as_deref(),
                event_type.as_deref(),
                team_id.as_deref(),
                max_nest_level.as_deref(),
                user_threshold.as_deref(),
            )
            .await?;
        }
        Commands::BreakoutAnnounce { coords, rooms, message } => {
            api::show_breakout_announce(&coords, &rooms, &message).await?;
        }
        Commands::Copilot {
            print_frames,
            replay,
            chat,
            license_status,
            token_family,
            tone,
            option_set,
            hub,
        } => {
            copilot_probe(print_frames, replay, chat, license_status, &token_family, &tone, option_set, &hub)
                .await?;
        }
        Commands::Meetings { limit, parse } => {
            if let Some(raw) = parse {
                let t = api::parse_join_url(&raw);
                println!("kind: {}", t.kind);
                if let Some(tid) = t.thread_id {
                    println!("thread: {}", tid);
                }
                if let Some(mid) = t.meeting_id {
                    println!("meeting: {}", mid);
                }
                println!("url: {}", t.url);
            } else {
                api::list_upcoming_meetings(limit).await?;
            }
        }
        Commands::Loop { action } => match action {
            LoopCommands::Create {
                site, drive, folder, file, body, share, dry_run,
            } => {
                let url = api::snapshot_create_url(&site, &drive, &folder, &file, share.as_deref());
                if dry_run {
                    print_dry_run("POST", &url, &[("Content-Type", "application/json")], &body);
                } else {
                    let c = api::create_snapshot(&site, &drive, &folder, &file, &body, share.as_deref()).await?;
                    println!("{}", serde_json::to_string_pretty(&c)?);
                }
            }
            LoopCommands::Page {
                site, drive, title, content_type, content, path, dry_run,
            } => {
                let url = api::storage_pages_url(&site, &drive);
                let body = api::page_create_body(&title, &content_type, &content, &path, None);
                if dry_run {
                    print_dry_run("POST", &url, &[("Content-Type", "application/json")], &body.to_string());
                } else {
                    let link = api::create_loop_page(&site, &drive, &title, &content_type, &content, &path).await?;
                    println!("link: {}", link);
                }
            }
            LoopCommands::Send { to, component_url, text, dry_run } => {
                let cards = api::embed_cards_json(&component_url);
                let body = api::embed_message_body(&text, &cards);
                if dry_run {
                    // No client here on purpose: dry-run never touches
                    // auth; {chatSvc} is the account's chat-service host.
                    let url = format!("{{chatSvc}}/v1/users/ME/conversations/{}/messages", to);
                    print_dry_run("POST", &url, &[("Content-Type", "application/json")], &body.to_string());
                } else {
                    let client = api::client::TeamsClient::new().await?;
                    let cmid = api::new_client_message_id();
                    let sent = api::send_loop_embed(&client, &to, &text, &component_url, &cmid).await?;
                    println!("id: {}", sent.id.as_deref().unwrap_or(""));
                    println!("client_message_id: {}", sent.client_message_id);
                }
            }
            LoopCommands::Read {
                host, drive, item, site, ops, share_link, dry_run,
            } => {
                if let Some(h) = host {
                    let (d, i) = (drive.unwrap_or_default(), item.unwrap_or_default());
                    if d.trim().is_empty() || i.trim().is_empty() {
                        anyhow::bail!("page read needs --drive and --item");
                    }
                    let url = api::page_read_url(&h, &d, &i);
                    let body = api::page_read_body(None, None);
                    if dry_run {
                        print_dry_run("POST", &url, &[("Content-Type", "application/json")], &body.to_string());
                    } else {
                        println!("{}", api::read_loop_page(&h, &d, &i).await?);
                    }
                } else if let Some(s) = site {
                    let (d, i) = (drive.unwrap_or_default(), item.unwrap_or_default());
                    if d.trim().is_empty() || i.trim().is_empty() {
                        anyhow::bail!("snapshot/ops read needs --drive and --item");
                    }
                    match ops {
                        Some(range) => {
                            let (a, b) = range.split_once(':').unwrap_or(("", ""));
                            let (start, end): (u64, u64) =
                                (a.trim().parse().unwrap_or(0), b.trim().parse().unwrap_or(0));
                            let url = api::ops_fetch_url(&s, &d, &i, start, end);
                            if dry_run {
                                print_dry_run("GET", &url, &[("Accept", "application/json")], "");
                            } else {
                                let v = api::ops_fetch(&s, &d, &i, start, end).await?;
                                println!("{}", serde_json::to_string_pretty(&v)?);
                            }
                        }
                        None => {
                            let url = api::snapshot_load_url(&s, &d, &i, share_link.as_deref());
                            if dry_run {
                                print_dry_run("GET", &url, &[("Accept", "application/json")], "");
                            } else {
                                let v = api::snapshot_load(&s, &d, &i, share_link.as_deref()).await?;
                                println!("{}", serde_json::to_string_pretty(&v)?);
                            }
                        }
                    }
                } else {
                    anyhow::bail!("read needs --host (S1) or --site (S2/S3)");
                }
            }
            LoopCommands::Sync { site, drive, item, dry_run } => {
                let url = api::join_session_url(&site, &drive, &item);
                if dry_run {
                    print_dry_run("GET", &url, &[("Accept", "application/json")], "");
                } else {
                    let v = api::join_session(&site, &drive, &item).await?;
                    println!("{}", serde_json::to_string_pretty(&v)?);
                }
            }
        },
    }

    Ok(())
}

/// COPILOT-BUILD probe. Offline modes (`--print-frames`, `--replay`)
/// never touch the network; live modes (`--chat`, `--license-status`)
/// are phase-2 only (tenant recovery + owner brief).
#[allow(clippy::too_many_arguments)]
async fn copilot_probe(
    print_frames: Option<String>,
    replay: Option<String>,
    chat: Option<String>,
    license_status: bool,
    token_family: &str,
    tone: &str,
    option_set: Vec<String>,
    hub: &str,
) -> Result<()> {
    let mut turn = api::ChatTurn::free_tier("");
    turn.tone = tone.to_string();
    turn.options_sets = option_set;
    if let Some(prompt) = print_frames {
        turn.text = prompt;
        let inv = api::chat_invocation(&turn, "0");
        println!("f0 handshake: {}", api::handshake_request().replace('\u{1e}', "␞"));
        println!("f2 ping: {}", api::ping_frame().replace('\u{1e}', "␞"));
        println!("f3 invocation: {}", api::frame(&inv).replace('\u{1e}', "␞"));
        let q = api::HubQuery::default();
        let url = api::hub_url_2026(api::HUB_DEFAULT, &turn.conversation_id, "REDACTED", "teamshub", "teamshub", &q);
        println!("url: {}", url);
        return Ok(());
    }
    if let Some(record) = replay {
        for r in api::split_frames(&record) {
            println!("{:?}", api::parse_server_record(r));
        }
        return Ok(());
    }
    let profile = config::active_profile();
    if license_status {
        let scope = format!("{}/.default", api::TAIGER_BASE);
        let grant = auth::oauth::token_for_scope_for(&profile, &scope).await?;
        let (oid, tid) = api::jwt_oid_tid(&grant.access_token)
            .ok_or_else(|| anyhow::anyhow!("token has no oid/tid"))?;
        let s = api::license_status(&grant.access_token, &oid, &tid).await;
        println!("status: {}", s.status);
        println!("licensed: {}", api::licensed(&s.status));
        if let Some(r) = api::license_reason(&s.status) {
            println!("reason: {}", r);
        }
        if let Some(e) = s.error_text() {
            println!("error: {}", e);
        }
        return Ok(());
    }
    if let Some(prompt) = chat {
        turn.text = prompt;
        let token = match token_family {
            "substrate" => api::substrate_token_for(&profile).await?,
            _ => api::sydney_token_for(&profile).await?,
        };
        let url = if hub == "teams2024" {
            let (oid, tid) =
                api::jwt_oid_tid(&token).ok_or_else(|| anyhow::anyhow!("token has no oid/tid"))?;
            api::hub_url_teams(&oid, &tid, &token)
        } else {
            let base = match hub {
                "prod" => api::HUB_PROD,
                "sdf" => api::HUB_SDF,
                "msit" => api::HUB_MSIT,
                "gcch" => api::HUB_GCCH,
                "dod" => api::HUB_DOD,
                _ => api::HUB_DEFAULT,
            };
            api::hub_url_2026(base, &turn.conversation_id, &token, "teamshub", "teamshub", &api::HubQuery::default())
        };
        let answer = api::run_turn(&url, &turn, |p| match p {
            api::TurnProgress::Text(t) => {
                print!("\r\x1b[2K{}", t.lines().last().unwrap_or(""));
                use std::io::Write;
                let _ = std::io::stdout().flush();
            }
            api::TurnProgress::Progress(p) => tracing::info!("progress: {}", p),
            api::TurnProgress::Done(_) => {}
        })
        .await?;
        println!("\r\x1b[2K{}", answer.text);
        for s in &answer.suggestions {
            println!("suggestion: {}", s);
        }
        return Ok(());
    }
    anyhow::bail!("pick one: --print-frames | --replay | --chat | --license-status");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copilot_probe_parses_offline_and_live_modes() {
        let cli = Cli::try_parse_from(["teams-cli", "copilot", "--print-frames", "hi"]).unwrap();
        match cli.command {
            Commands::Copilot { print_frames, tone, token_family, hub, .. } => {
                assert_eq!(print_frames.as_deref(), Some("hi"));
                assert_eq!(tone, "Magic");
                assert_eq!(token_family, "sydney");
                assert_eq!(hub, "default");
            }
            _ => panic!("wrong command parsed"),
        }
        let cli = Cli::try_parse_from([
            "teams-cli", "copilot", "--chat", "hi", "--token-family", "substrate",
            "--tone", "Chat", "--option-set", "a", "--option-set", "b", "--hub", "teams2024",
        ])
        .unwrap();
        match cli.command {
            Commands::Copilot { chat, token_family, tone, option_set, hub, .. } => {
                assert_eq!(chat.as_deref(), Some("hi"));
                assert_eq!(token_family, "substrate");
                assert_eq!(tone, "Chat");
                assert_eq!(option_set, vec!["a".to_string(), "b".to_string()]);
                assert_eq!(hub, "teams2024");
            }
            _ => panic!("wrong command parsed"),
        }
    }

    #[test]
    fn mark_read_parses_to_and_message_id() {
        // Verb + args mirror `delete`: `--to` chat, `--message-id` frontier.
        let cli = Cli::try_parse_from([
            "teams-cli",
            "mark-read",
            "--to",
            "19:abc@thread.v2",
            "--message-id",
            "1750000000000",
        ])
        .expect("mark-read parses");
        match cli.command {
            Commands::MarkRead { to, message_id } => {
                assert_eq!(to, "19:abc@thread.v2");
                assert_eq!(message_id, "1750000000000");
            }
            _ => panic!("wrong command parsed"),
        }
    }

    #[test]
    fn mark_read_requires_message_id() {
        assert!(Cli::try_parse_from(["teams-cli", "mark-read", "--to", "19:abc"]).is_err());
    }

    #[test]
    fn breakout_verbs_parse() {
        let coords = r#"{"tenant_id":"t","organizer_id":"o","thread_id":"19:x","message_id":"1"}"#;
        match Cli::try_parse_from(["teams-cli", "breakout-rooms", coords]).expect("rooms parses").command {
            Commands::BreakoutRooms { coords: c } => assert!(c.contains("tenant_id")),
            _ => panic!("wrong command parsed"),
        }
        match Cli::try_parse_from([
            "teams-cli", "breakout-create", coords, "--count", "6", "--version", "3",
        ])
        .expect("create parses")
        .command
        {
            Commands::BreakoutCreate { count, version, preconfig, .. } => {
                assert_eq!(count, 6);
                assert_eq!(version.as_deref(), Some("3"));
                assert_eq!(preconfig, None);
            }
            _ => panic!("wrong command parsed"),
        }
        match Cli::try_parse_from([
            "teams-cli", "breakout-update", coords, "--name", "R", "--restrict-chat-access",
        ])
        .expect("update parses")
        .command
        {
            Commands::BreakoutUpdate { name, restrict_chat_access, .. } => {
                assert_eq!(name, "R");
                assert!(restrict_chat_access);
            }
            _ => panic!("wrong command parsed"),
        }
        match Cli::try_parse_from(["teams-cli", "breakout-announce", coords, "--rooms", "a,b", "--message", "hi"])
            .expect("announce parses")
            .command
        {
            Commands::BreakoutAnnounce { rooms, message, .. } => {
                assert_eq!(rooms, "a,b");
                assert_eq!(message, "hi");
            }
            _ => panic!("wrong command parsed"),
        }
    }

    #[test]
    fn breakout_verbs_require_their_args() {
        assert!(Cli::try_parse_from(["teams-cli", "breakout-rooms"]).is_err());
        assert!(Cli::try_parse_from(["teams-cli", "breakout-add", "{}"]).is_err());
        assert!(Cli::try_parse_from(["teams-cli", "breakout-assign", "{}", "--rooms", "[]"]).is_ok());
    }

    #[test]
    fn read_still_parses_unchanged() {
        let cli = Cli::try_parse_from(["teams-cli", "read", "19:abc", "--limit", "5"])
            .expect("read parses");
        match cli.command {
            Commands::Read { chat_id, limit } => {
                assert_eq!(chat_id, "19:abc");
                assert_eq!(limit, 5);
            }
            _ => panic!("wrong command parsed"),
        }
    }

    #[test]
    fn loop_nested_verbs_parse_with_dry_run() {
        let cli = Cli::try_parse_from([
            "teams-cli", "loop", "create", "--site", "https://s", "--drive", "d",
            "--file", "x.loop", "--body", "{}", "--dry-run",
        ])
        .expect("loop create parses");
        match cli.command {
            Commands::Loop { action: LoopCommands::Create { folder, dry_run, .. } } => {
                assert_eq!(folder, "Loop");
                assert!(dry_run);
            }
            _ => panic!("wrong command parsed"),
        }
        let cli = Cli::try_parse_from([
            "teams-cli", "loop", "send", "--to", "19:abc", "--component-url", "https://t/x",
        ])
        .expect("loop send parses");
        match cli.command {
            Commands::Loop { action: LoopCommands::Send { to, dry_run, .. } } => {
                assert_eq!(to, "19:abc");
                assert!(!dry_run);
            }
            _ => panic!("wrong command parsed"),
        }
        // All five sub-verbs exist.
        for args in [
            vec!["teams-cli", "loop", "page", "--site", "s", "--drive", "d", "--title", "t",
                 "--content-type", "html", "--content", "c"],
            vec!["teams-cli", "loop", "read", "--host", "h", "--drive", "d", "--item", "i"],
            vec!["teams-cli", "loop", "sync", "--site", "s", "--drive", "d", "--item", "i"],
        ] {
            assert!(Cli::try_parse_from(args).is_ok());
        }
    }
}
