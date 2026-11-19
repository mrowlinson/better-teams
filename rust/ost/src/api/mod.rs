//! API client module for Microsoft Teams

pub mod apps;
mod calendar;
mod calweek;
mod channel_moderation;
mod chat;
pub mod client;
#[cfg(test)]
pub(crate) mod fake_transport;
mod files;
mod filesearch;
mod graph;
mod me;
pub mod media;
mod meetings_plus;
mod notes;
mod planner;
mod presence;
mod recordings;
mod schedule;
mod search;
pub mod tags;
mod tabs;
mod team_settings;
mod teams;
mod todo;
mod transcripts;
#[cfg(test)]
mod write_fakes;

use anyhow::Result;

// Re-export data types for TUI integration
pub use chat::{
    ChatInfo, ChatMemberInfo, EchoMention, MessageInfo, MessagesPage, ReactionCount, Reactor,
    ReadReceipt, RosterSource, REACTION_EMOJI,
};
pub use calendar::{
    JoinIdResolve, JoinTarget, LobbyEvent, LobbyState, MeetingInfo, ResolvedJoinId,
};
pub use files::{FileVersion, SharedFile};
pub use me::UserInfo;
pub use meetings_plus::{
    attendance_records_path, attendance_reports_path, capture_options_body,
    capture_options_path, meeting_attendance_data, meeting_capture_options_data,
    parse_attendance_records, parse_capture_options, parse_first_report_id,
    set_meeting_capture_options_data, show_meeting_attendance, show_meeting_capture,
    AttendanceEntry, CaptureOptions,
};
pub use notes::{NotePage, NotebookInfo, PageInfo, SectionInfo};
pub use planner::{BucketInfo, GroupPost, PlanInfo, PlannerChecklistItem, PlannerReference, PlannerTaskDetails, PlannerTaskInfo};
pub use presence::PresenceInfo;
pub use channel_moderation::{
    moderation_data, moderation_path, moderation_read_path,
    parse_moderation_settings, parse_thread_settings, posts_perm, render_thread_settings,
    replies_perm, set_moderation, show_moderation, thread_settings_data, thread_settings_thread_url,
    thread_settings_url, update_moderation_data,
    ChannelModeration, ThreadChannelSettings, CHANNEL_SETTINGS_PROPERTY,
    THREAD_BOTS_KEY, THREAD_CONNECTORS_KEY,
    POST_EVERYONE, POST_EXCEPT_GUESTS, POST_MODERATORS,
    REPLY_AUTHOR_MODERATORS, REPLY_EVERYONE,
};
pub use team_settings::{
    set_visibility, show_visibility, team_settings_data, team_visibility_data,
    update_team_visibility_data, visibility_body, visibility_path, visibility_read_path,
    parse_visibility, TeamMemberSettings,
};
pub use recordings::{
    clamp_limit as recordings_clamp_limit, is_video as is_recording_video,
    list_recordings_data, parse_recordings_response, recordings_children_path,
    recordings_search_path, search_recordings_data, sort_newest as sort_recordings_newest,
    RecordingInfo, RecordingSource, RECORDINGS_MAX_LIMIT,
};
pub use schedule::{
    create_offer_request_data, create_shift_data, create_swap_request_data, create_timeoff_data,
    create_timeoff_request_data, datetime_ok, decide_change_request_data, delete_shift_data,
    is_missing_scope, list_change_requests_data, list_schedule_data, list_shifts_data,
    list_shifts_range_data, list_timeoff_reasons_data, list_timesoffs_data, list_timesoffs_range_data,
    request_collection, schedule_range_path, share_schedule_data, update_shift_data, ChangeRequestInfo,
    ScheduleInfo, ShiftInfo, TimeOffInfo, TimeOffReason,
};
pub use search::{clamp_size, next_from, parse_search_response, search_body, search_messages_data, SearchHitInfo, SearchPage, SEARCH_MAX_SIZE};
pub use apps::{
    app_catalog_data, app_search_data, app_store_data, install_app_for_user, sharepoint_sites_data,
    team_app_definitions_data, AppCatalog, AppEntitlement, AppManifest, AppStore, ConfigurableTab, SharePointSites,
    StaticTab, StoreSection, WebApplicationInfo,
};
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
    chat_members_path, create_group_chat_data, group_chat_create_body, created_thread_id, thread_create_url,
    group_chat_members, is_channel_conversation_id, list_chat_members_data,
    parse_graph_chat_members, parse_thread_members, reaction_counts_from_values,
    thread_reply_conversation, thread_reply_url, thread_reply_with_client,
};
// OstMac §106 (SENDFIX): idempotent sends + verify-by-clientmessageid.
pub use chat::{
    find_by_client_id, find_message_by_client_id, is_chat_mri, new_client_message_id,
    one_to_one_thread_body, one_to_one_thread_id,
    reply_message_with_client_id, send_message_with_client_id, sent_id_from_response,
    thread_reply_with_client_id, SentMessage,
};
// OstMac COMPOSER-B (C1b): importance/urgent, subject, broadcast mentions.
pub use chat::{
    apply_mentions, build_message_html_opts, build_reply_html_opts, parse_wire_mentions,
    reply_message_with_client_id_opts, restore_mentions, send_message_body_opts,
    send_message_with_client_id_opts, thread_reply_with_client_id_opts,
    SendOpts, WireImportance, WireMention, WIRE_MENTION_MAX,
};
// OstMac PRAISE: Praise card post.
pub use chat::{
    praise_card_content, praise_message_body, send_praise_with_client_id,
    ADAPTIVE_CARD_CONTENT_TYPE, PRAISE_APP_ID,
};
// OstMac §84: server-side pinned chat messages.
pub use chat::{
    chat_pinned_messages_data, chat_unpin_message_with_client, fill_pin_from_message,
    graph_pins_path, graph_unpin_path, parse_graph_pins, parse_thread_pins, pick_pins,
    pin_message_with_client, pinned_items_add, pinned_items_body, pinned_items_from_raw,
    pinned_items_remove, pinned_items_url, thread_pins_url,
    unpin_thread_message_with_client, PinSource, PinnedRef,
};
pub use chat::{
    alerts_body, alerts_muted, alerts_url, conversation_folder_move_with_client,
    conversation_folders_data, conversation_folders_url, folder_move_actions, folder_move_body,
    conversation_property_url, hide_chat_properties, parse_conversation_folders, set_chat_hidden_with_client,
    set_chat_muted_with_client, ConversationFolder, CHATSVCAGG_SCOPE, SYSTEM_FOLDER_TYPES,
};
pub use chat::{
    add_chat_members_with_client, chat_add_member_body, group_thread_id, member_user_ref,
    remove_chat_member_with_client, rename_chat_with_client, thread_topic_body, thread_topic_url,
    MemberAddResult, ShareHistory,
};
// OstMac stickers: native AMS-upload sticker send + detect.
pub use chat::{
    is_sticker_html, parse_sticker_object_id, png_dimensions,
    send_sticker_message_with_client_id, sticker_content, sticker_create_body,
    sticker_effective_label, sticker_label, sticker_message_body, sticker_view_url,
    upload_sticker_image_data, STICKER_DEFAULT_LABEL, STICKER_EDGE_MAX, STICKER_IMAGE_MAX_BYTES,
    STICKER_ITEMTYPE,
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
    clamp_limit, drive_search_path, external_search_path, looks_like_email,
    merge_people, parse_drive_search_response, parse_external_search_response,
    parse_people_search_response, people_mail_path, people_search_path,
    search_external_data, search_files_data, search_people_data, FIND_MAX_LIMIT,
};
pub use files::{
    content_range_value, copy_body, copy_file_data, create_folder_data, create_link_data,
    delete_file_data, download_file_data, download_file_version_data, drive_item_path,
    drive_recents_path, folder_children_path, list_chat_files_data, list_chat_files_data_opts,
    list_drive_recents_data, list_file_versions_data, list_folder_children_data,
    list_message_files_data, message_path, mkdir_body, mkdir_path, move_body,
    move_file_data, rename_body, rename_file_data, restore_file_version_data, upload_chunk_ranges,
    upload_file_data, upload_file_data_idem, upload_file_data_with_progress, upload_session_body,
    UploadProgress,
};
pub use media::{fetch_media_data, MediaBytes, MAX_BYTES};
pub use me::whoami_data;
pub use notes::{
    append_note_paragraph_data, list_notebook_sections_data, list_notebooks_data,
    read_note_page_data,
};
pub use planner::{
    bucket_create_body, buckets_collection_path, buckets_path,
    checklist_body, comment_body, create_bucket_data, create_plan_data, create_task_body,
    create_task_data, create_thread_data, delete_plan_data, delete_task_data, delete_thread_data,
    description_body, get_plan_data, get_task_details_data, list_buckets_data, list_plans_data,
    list_tasks_data, list_thread_posts_data, parse_bucket, parse_buckets, parse_plan, parse_plans,
    parse_task, parse_task_details, parse_tasks, parse_thread_posts, patch_task_details_data,
    plan_categories_body, plan_create_body, plan_path, plans_collection_path, post_task_comment_data,
    reference_body, reference_decode, reference_key,
    set_assignment_body, set_complete_body, set_plan_categories_data, set_task_assignee_data,
    set_task_checklist_data, set_task_complete_data, set_task_description_data, set_task_labels_data,
    set_task_reference_data, task_details_path, task_labels_body, task_path, tasks_path,
    thread_create_body, thread_path, thread_posts_path, thread_reply_path, threads_collection_path,
};
pub use presence::get_presence_data;
pub use tabs::{
    add_channel_tab_data, add_chat_tab_data, list_chat_tabs_data, list_tabs_data,
    remove_channel_tab_data, remove_chat_tab_data, rename_channel_tab_data, rename_chat_tab_data,
};
pub use teams::{
    add_channel_member_body, add_channel_member_data, add_member_body, add_team_member_data,
    archive_channel_body, archive_channel_data, archive_channel_path,
    channel_member_path, channel_members_path, channel_react_body,
    channel_reply_set_reaction_path, channel_reply_unset_reaction_path,
    channel_path, channel_set_reaction_path, channel_unset_reaction_path,
    create_channel_body, create_channel_body_typed, create_channel_data,
    create_channel_typed_data, delete_channel_data, list_channel_members_data,
    normalize_membership_type, remove_channel_member_data,
    unarchive_channel_data, unarchive_channel_path, update_channel_body,
    update_channel_data, create_channel_path, create_team_body, create_team_data,
    ChannelMemberInfo,
    mt_create_team_url, created_team_ids, team_thread_id, mt_channel_url, delete_channel_body,
    is_thread_id, team_internal_id, TEAM_ACCESS_PRIVATE, join_team_data, list_team_members_data, list_teams_data,
    parse_public_teams, public_teams_groups_path, public_teams_list_path,
    search_public_teams_data, PublicTeamInfo, PublicTeamsSource, PUBLIC_TEAMS_MAX,
    member_path, members_path, operation_failed, operation_succeeded,
    operation_team_id, operation_url, remove_team_member_data,
    set_channel_reaction_data, TeamCreateResult, update_team, update_team_body,
    update_team_data, update_team_path, archive_team, archive_team_data,
    archive_team_path, unarchive_team, unarchive_team_data, unarchive_team_path,
    delete_team, delete_team_data, delete_team_path, set_team_photo,
    set_team_photo_data, team_photo_path,
    TeamsAsyncOperation, TEAM_CREATE_POLL_SECS, TEAM_CREATE_TIMEOUT_SECS,
    unset_channel_reaction_data,
};
pub use todo::{
    complete_todo_task_data, create_todo_task_data, list_todo_lists_data,
    list_todo_tasks_data, reopen_todo_task_data,
};

/// List recent chats (native Teams API)
pub async fn list_chats(limit: usize) -> Result<()> {
    chat::list_chats(limit).await
}

/// Read messages from a chat (native Teams API)
pub async fn read_messages(chat_id: &str, limit: usize, verbose: bool) -> Result<()> {
    chat::read_messages(chat_id, limit, verbose).await
}

/// Mark one conversation read up to a message (native Teams API)
pub async fn mark_read(chat_id: &str, message_id: &str) -> Result<()> {
    chat::mark_read(chat_id, message_id).await
}

/// Send a message to a chat (native Teams API)
pub async fn send_message(to: &str, message: &str) -> Result<()> {
    chat::send_message(to, message).await
}

/// Send a local PNG file as a sticker (AMS upload + sticker message)
pub async fn send_sticker(to: &str, png_path: &str, label: &str) -> Result<()> {
    chat::send_sticker(to, png_path, label).await
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

/// Create one standard (private) team via the middle tier
pub async fn create_team(name: &str, description: Option<&str>) -> Result<()> {
    teams::create_team(name, description).await
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

/// Create one channel of any membership type
pub async fn create_channel_typed(
    team_id: &str,
    name: &str,
    description: Option<&str>,
    membership_type: Option<&str>,
    owners: &[&str],
) -> Result<()> {
    teams::create_channel_typed(team_id, name, description, membership_type, owners).await
}

/// List one private/shared channel's members
pub async fn list_channel_members(
    team_id: &str,
    channel_id: &str,
    owners_only: bool,
) -> Result<()> {
    teams::list_channel_members(team_id, channel_id, owners_only).await
}

/// Add one user to a private/shared channel
pub async fn add_channel_member(
    team_id: &str,
    channel_id: &str,
    user: &str,
    owner: bool,
) -> Result<()> {
    teams::add_channel_member(team_id, channel_id, user, owner).await
}

/// Remove one membership from a private/shared channel
pub async fn remove_channel_member(
    team_id: &str,
    channel_id: &str,
    member_id: &str,
) -> Result<()> {
    teams::remove_channel_member(team_id, channel_id, member_id).await
}

/// Archive one channel (async server-side; re-read to confirm)
pub async fn archive_channel(team_id: &str, channel_id: &str) -> Result<()> {
    teams::archive_channel(team_id, channel_id).await
}

/// Restore one archived channel
pub async fn unarchive_channel(team_id: &str, channel_id: &str) -> Result<()> {
    teams::unarchive_channel(team_id, channel_id).await
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

/// Add a website/app tab to a channel (prints the created tab)
pub async fn add_channel_tab(
    channel_id: &str,
    name: &str,
    app: Option<&str>,
    url: Option<&str>,
) -> Result<()> {
    tabs::add_channel_tab(channel_id, name, app, url).await
}

/// Rename a channel tab (prints the updated tab)
pub async fn rename_channel_tab(channel_id: &str, tab_id: &str, name: &str) -> Result<()> {
    tabs::rename_channel_tab(channel_id, tab_id, name).await
}

/// Remove a channel tab
pub async fn remove_channel_tab(channel_id: &str, tab_id: &str) -> Result<()> {
    tabs::remove_channel_tab(channel_id, tab_id).await
}

/// Add a website/app tab to a chat (prints the created tab)
pub async fn add_chat_tab(
    chat_id: &str,
    name: &str,
    app: Option<&str>,
    url: Option<&str>,
) -> Result<()> {
    tabs::add_chat_tab(chat_id, name, app, url).await
}

/// Rename a chat tab (prints the updated tab)
pub async fn rename_chat_tab(chat_id: &str, tab_id: &str, name: &str) -> Result<()> {
    tabs::rename_chat_tab(chat_id, tab_id, name).await
}

/// Remove a chat tab
pub async fn remove_chat_tab(chat_id: &str, tab_id: &str) -> Result<()> {
    tabs::remove_chat_tab(chat_id, tab_id).await
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
