//! API client module for Microsoft Teams

mod calendar;
mod calweek;
mod chat;
pub mod client;
mod files;
mod filesearch;
mod graph;
mod me;
pub mod media;
mod notes;
mod planner;
mod presence;
mod recordings;
mod schedule;
mod search;
mod tabs;
mod teams;
mod todo;
mod transcripts;

use anyhow::Result;

// Re-export data types for TUI integration
pub use chat::{
    ChatInfo, ChatMemberInfo, MessageInfo, MessagesPage, ReactionCount, Reactor, ReadReceipt,
    RosterSource, REACTION_EMOJI,
};
pub use calendar::{
    JoinIdResolve, JoinTarget, LobbyEvent, LobbyState, MeetingInfo, ResolvedJoinId,
};
pub use files::{FileVersion, SharedFile};
pub use me::UserInfo;
pub use notes::{NotePage, NotebookInfo, PageInfo, SectionInfo};
pub use planner::{BucketInfo, PlanInfo, PlannerTaskInfo};
pub use presence::PresenceInfo;
pub use recordings::{
    clamp_limit as recordings_clamp_limit, is_video as is_recording_video,
    list_recordings_data, parse_recordings_response, recordings_children_path,
    recordings_search_path, search_recordings_data, sort_newest as sort_recordings_newest,
    RecordingInfo, RecordingSource, RECORDINGS_MAX_LIMIT,
};
pub use schedule::{
    list_schedule_data, list_shifts_data, list_shifts_range_data, list_timeoff_reasons_data,
    list_timesoffs_data, list_timesoffs_range_data, schedule_range_path, ScheduleInfo, ShiftInfo, TimeOffInfo, TimeOffReason,
};
pub use search::{clamp_size, next_from, parse_search_response, search_body, search_messages_data, SearchHitInfo, SearchPage, SEARCH_MAX_SIZE};
pub use tabs::TabInfo;
pub use teams::TeamInfo;
pub use teams::TeamMemberInfo;
pub use todo::{TodoListInfo, TodoTaskInfo};
pub use transcripts::{
    clamp_limit as transcripts_clamp_limit, is_transcript,
    list_transcripts_data, parse_transcripts_response, search_transcripts_data,
    sort_newest as sort_transcripts_newest, transcripts_children_path,
    transcripts_search_path, TranscriptInfo, TranscriptSource, TRANSCRIPTS_MAX_LIMIT,
};

// Re-export ChannelInfo for use in TUI sidebar (currently consumed
// only through TeamInfo.channels, but kept public for future callers).
#[allow(unused_imports)]
pub use teams::ChannelInfo;

// Re-export data-returning functions for TUI integration
pub use chat::{
    build_message_html, build_reply_html, consumptionhorizon_body, consumptionhorizon_url,
    consumptionhorizon_value, consumptionhorizons_url, create_one_to_one_chat_data,
    delete_message_with_client,
    edit_message_body, edit_message_with_client, emoji_for_reaction_type, leave_chat_with_client,
    leave_member_url, list_chats_data, mark_read_with_client, message_url, one_to_one_create_body,
    one_to_one_create_path, own_member_mri, parse_created_chat,
    parse_consumptionhorizons, reaction_add_body, reaction_add_url, reaction_remove_url,
    reaction_type_for_emoji, read_messages_data, read_messages_page, read_receipts_data,
    receipt_message_id, remove_reaction_with_client, reply_message_with_client, reply_snippet,
    send_message_body, send_message_with_client, send_reaction_with_client, split_reply_quote,
    REPLY_SNIPPET_MAX, WIRE_FENCE_MAX_BLOCKS,
};
// OstMac core-a: channel thread replies, chat roster, group create, reactors.
pub use chat::{
    chat_members_path, create_group_chat_data, group_chat_create_body, group_chat_create_path,
    group_chat_members, is_channel_conversation_id, list_chat_members_data,
    parse_graph_chat_members, parse_thread_members, reaction_counts_from_values,
    thread_reply_conversation, thread_reply_url, thread_reply_with_client,
};
pub use calendar::{
    calendar_view_path, list_upcoming_meetings_data, lobby_next, normalize_join_meeting_id,
    online_meeting_by_join_id_path, parse_calendar_view, parse_join_id_lookup, parse_join_url,
    resolve_join_meeting_id_data,
};
pub use calweek::{
    calweek_view_path, cancel_meeting_data, list_week_meetings_data, parse_created_event,
    schedule_event_body, schedule_meeting_data, validate_schedule,
};
pub use filesearch::{
    clamp_limit, drive_search_path, parse_drive_search_response,
    parse_people_search_response, people_search_path, search_files_data,
    search_people_data, FIND_MAX_LIMIT,
};
pub use files::{
    content_range_value, copy_body, copy_file_data, create_link_data, delete_file_data,
    download_file_data, download_file_version_data, drive_item_path, drive_recents_path,
    folder_children_path, list_chat_files_data, list_chat_files_data_opts,
    list_drive_recents_data, list_file_versions_data, list_folder_children_data, move_body,
    move_file_data, rename_body, rename_file_data, restore_file_version_data, upload_chunk_ranges,
    upload_file_data, upload_file_data_with_progress, upload_session_body, UploadProgress,
};
pub use media::{fetch_media_data, MediaBytes, MAX_BYTES};
pub use me::whoami_data;
pub use notes::{
    append_note_paragraph_data, list_notebook_sections_data, list_notebooks_data,
    read_note_page_data,
};
pub use planner::{
    buckets_path, create_task_body, create_task_data, list_buckets_data, list_plans_data,
    list_tasks_data, parse_buckets, parse_plans, parse_task, parse_tasks, plans_path,
    set_assignment_body, set_complete_body, set_task_assignee_data, set_task_complete_data,
    task_path, tasks_path,
};
pub use presence::get_presence_data;
pub use tabs::list_tabs_data;
pub use teams::{
    add_member_body, add_team_member_data, channel_react_body,
    channel_reply_set_reaction_path, channel_reply_unset_reaction_path,
    channel_set_reaction_path, channel_unset_reaction_path, create_channel_body,
    create_channel_data, create_channel_path, create_team_body, create_team_data,
    create_team_path, join_team_data, list_team_members_data, list_teams_data,
    parse_public_teams, public_teams_groups_path, public_teams_list_path,
    search_public_teams_data, PublicTeamInfo, PublicTeamsSource, PUBLIC_TEAMS_MAX,
    member_path, members_path, operation_failed, operation_succeeded,
    operation_team_id, operation_url, remove_team_member_data,
    set_channel_reaction_data, standard_team_template, TeamCreateResult,
    TeamsAsyncOperation, TEAM_CREATE_POLL_SECS, TEAM_CREATE_TIMEOUT_SECS,
    unset_channel_reaction_data,
};
pub use todo::{
    complete_todo_task_data, create_todo_task_data, list_todo_lists_data,
    list_todo_tasks_data,
};

/// List recent chats (native Teams API)
pub async fn list_chats(limit: usize) -> Result<()> {
    chat::list_chats(limit).await
}

/// Read messages from a chat (native Teams API)
pub async fn read_messages(chat_id: &str, limit: usize) -> Result<()> {
    chat::read_messages(chat_id, limit).await
}

/// Send a message to a chat (native Teams API)
pub async fn send_message(to: &str, message: &str) -> Result<()> {
    chat::send_message(to, message).await
}

/// Add (or with `remove`, remove) an emoji reaction on one message.
pub async fn react(chat_id: &str, message_id: &str, emoji: &str, remove: bool) -> Result<()> {
    chat::react(chat_id, message_id, emoji, remove).await
}

/// Reply to one message in a chat (quote reply, native Teams API)
pub async fn reply_message(chat_id: &str, parent_id: &str, message: &str) -> Result<()> {
    chat::reply_message(chat_id, parent_id, message).await
}

/// Edit one own message (native Teams API, PUT per-message URL)
pub async fn edit_message(chat_id: &str, message_id: &str, text: &str) -> Result<()> {
    chat::edit_message(chat_id, message_id, text).await
}

/// Delete one own message (native Teams API, DELETE per-message URL)
pub async fn delete_message(chat_id: &str, message_id: &str) -> Result<()> {
    chat::delete_message(chat_id, message_id).await
}

/// Leave one chat thread (native Teams API, DELETE own roster membership)
pub async fn leave_chat(chat_id: &str) -> Result<()> {
    chat::leave_chat(chat_id).await
}

/// Get current presence status
pub async fn get_presence() -> Result<()> {
    presence::get_presence().await
}

/// Set presence status
pub async fn set_presence(status: &str) -> Result<()> {
    presence::set_presence(status).await
}

/// Show current user info
pub async fn whoami() -> Result<()> {
    me::whoami().await
}

/// List joined teams and their channels
pub async fn list_teams() -> Result<()> {
    teams::list_teams().await
}

/// List one team's roster (members + owners; `owners_only` filters)
pub async fn list_team_members(team_id: &str, owners_only: bool) -> Result<()> {
    teams::list_team_members(team_id, owners_only).await
}

/// Add one user to a team (`owner` grants the owner role)
pub async fn add_team_member(team_id: &str, user: &str, owner: bool) -> Result<()> {
    teams::add_team_member(team_id, user, owner).await
}

/// Remove one membership from a team
pub async fn remove_team_member(team_id: &str, member_id: &str) -> Result<()> {
    teams::remove_team_member(team_id, member_id).await
}

/// List shared files in a chat or channel
pub async fn list_files(chat_id: &str, limit: usize) -> Result<()> {
    files::list_files(chat_id, limit).await
}

/// List a channel's pinned tabs (read-only)
pub async fn list_tabs(channel_id: &str) -> Result<()> {
    tabs::list_tabs(channel_id).await
}

/// Dump every joined channel's tabs (one auth, read-only)
pub async fn list_tabs_all() -> Result<()> {
    tabs::list_tabs_all().await
}

/// Print one team's schedule week grid (shifts + time-off, read-only)
pub async fn list_shifts(team_id: &str) -> Result<()> {
    schedule::list_shifts(team_id).await
}

/// List upcoming meetings (Graph calendarView, next 7 days)
pub async fn list_upcoming_meetings(limit: usize) -> Result<()> {
    calendar::list_upcoming_meetings(limit).await
}

/// Download a shared file by drive+item id
pub async fn download_file(drive_id: &str, item_id: &str, dest: &str) -> Result<()> {
    files::download_file(drive_id, item_id, dest).await
}

/// Upload a local file to a chat or channel
pub async fn upload_file(chat_id: &str, local_path: &str) -> Result<()> {
    files::upload_file(chat_id, local_path).await
}

/// Create a view-only sharing link for a shared file (om-i1-links)
pub async fn create_link(drive_id: &str, item_id: &str, scope: &str) -> Result<()> {
    files::create_link(drive_id, item_id, scope).await
}

/// Search OneDrive files by name/content (om-jb-filesearch)
pub async fn search_files(query: &str, limit: usize) -> Result<()> {
    filesearch::search_files(query, limit).await
}

/// Search the directory for people (om-jb-filesearch)
pub async fn search_people(query: &str, limit: usize) -> Result<()> {
    filesearch::search_people(query, limit).await
}

/// List Microsoft To Do lists
pub async fn list_todo_lists() -> Result<()> {
    todo::list_todo_lists().await
}

/// List tasks in one To Do list
pub async fn list_todo_tasks(list_id: &str, limit: usize) -> Result<()> {
    todo::list_todo_tasks(list_id, limit).await
}

/// Create one task in a To Do list
pub async fn create_todo_task(list_id: &str, title: &str) -> Result<()> {
    todo::create_todo_task(list_id, title).await
}

/// Mark one To Do task completed
pub async fn complete_todo_task(list_id: &str, task_id: &str) -> Result<()> {
    todo::complete_todo_task(list_id, task_id).await
}

/// OneNote notebooks/sections/pages (read; `--append` edits a page)
pub async fn notes(
    group_id: Option<&str>,
    notebook: Option<&str>,
    page: Option<&str>,
    append: Option<&str>,
) -> Result<()> {
    notes::notes(group_id, notebook, page, append).await
}

/// Search Teams messages (Graph `/search/query`, first window)
pub async fn search_messages(query: &str, limit: usize) -> Result<()> {
    search::search_messages(query, limit).await
}
