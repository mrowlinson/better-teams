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

    /// Test microphone capture: record 3 seconds then play back
    #[cfg(feature = "audio")]
    MicTest,

    /// Test camera capture: record 3 seconds then play back in SDL2 window
    #[cfg(feature = "video-capture")]
    CamTest,
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
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
