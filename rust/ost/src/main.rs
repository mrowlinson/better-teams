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

        /// Server message id (from `read` verbose logs)
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

        /// Server message id (from `read` verbose logs)
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

    /// List a channel's pinned tabs (read-only)
    Tabs {
        /// Channel ID (from `teams` output)
        channel_id: String,
    },

    /// Dump every joined channel's tabs (one auth, read-only)
    TabsAll,

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

    let filter_str = if cli.verbose { "debug" } else { "info" };

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
        Commands::Tabs { channel_id } => {
            tracing::info!("Fetching channel tabs...");
            api::list_tabs(&channel_id).await?;
        }
        Commands::TabsAll => {
            tracing::info!("Fetching all channel tabs...");
            api::list_tabs_all().await?;
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
            api::read_messages(&chat_id, limit).await?;
        }
        Commands::Send { to, message, reply_to } => {
            tracing::info!("Sending message...");
            match reply_to {
                Some(parent) => api::reply_message(&to, &parent, &message).await?,
                None => api::send_message(&to, &message).await?,
            }
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
