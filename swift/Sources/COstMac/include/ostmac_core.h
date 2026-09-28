// ostmac_core.h — C ABI of the ostmac-core Rust staticlib.
// JSON over the boundary; every returned string freed with ostmac_free.
// Frame/media payloads travel byte+len (no base64 on the hot path);
// poll payloads are freed with ostmac_bytes_free.
#ifndef OSTMAC_CORE_H
#define OSTMAC_CORE_H

#include <stddef.h>
#include <stdint.h>

// NOTE (R12 ffi-move-now B0): version/init/status/status_for/
// profile_active moved to Swift (CoreLocal); decls deleted.

// Switch the active account profile ("" = default): {ok, profile}.
// Caller frees. No network.
char *ostmac_profile_set(const char *profile);

// NOTE (R14 om-later-b18 B18): device_start/device_start_for/
// device_poll moved to Swift (DeviceAuth); decls deleted.

// Browser-capture fallback start (auth-code + PKCE, no network):
// {ok, session, authorize_url, redirect_uri, expires_in}.
// Load authorize_url in a webview; the redirect_uri hit carries ?code&state.
// Caller frees.
char *ostmac_authcode_start(void);

// Browser-capture complete: session + intercepted callback URL (or raw
// query). Verifies state, exchanges the code, saves tokens:
// {ok, status:"complete", tokens} or {ok:false}. Parse/state failures
// keep the session (retryable); success drops it. Caller frees.
char *ostmac_authcode_complete(const char *session, const char *callback);

// Drop one pending browser session: {ok, cancelled}. Caller frees.
char *ostmac_authcode_cancel(const char *session);

// Browser-capture start for one account profile (exchanged tokens land
// there). No network. Caller frees.
char *ostmac_authcode_start_for(const char *profile);

// NOTE (R14 om-later-b4 B4): whoami/teams/chats moved to Swift
// (CoreReads); decls deleted.

// Create (or re-open) a 1:1 chat with one user ref, AAD id or UPN
// (Graph POST /me/chats, requires sign-in): {ok,chat:{id,name,
// is_group,...}} (name empty: Graph sends no 1:1 topic — callers
// name the thread after the peer). Caller frees.
char *ostmac_chat_create_one_to_one(const char *user);

// Create one standard channel in a team (Graph POST, requires sign-in):
// {ok,channel:{id,name}}. description may be NULL (no description).
// Caller frees.
char *ostmac_channel_create(
    const char *team_id, const char *name, const char *description);

// Join one team by id (self-enroll): {ok, team_id}. Caller frees.
char *ostmac_team_join(const char *team_id);

// Search public (joinable) teams by name (core-b): {ok,query,source,
// teams:[{id,name,description?,visibility}]}. Joined teams included;
// join a hit with ostmac_team_join(id). limit clamped 1..25. Caller frees.
char *ostmac_team_search(const char *query, int limit);

// Create one standard team (async Graph POST, requires sign-in):
// {ok,team:{id,name,channels},polls,elapsed_ms}. description may be
// NULL (no description). Caller frees.
char *ostmac_team_create(const char *name, const char *description);

// One channel's pinned tabs JSON, read-only: {ok, channel_id, tabs}. Caller frees.
char *ostmac_tabs(const char *channel_id);

// One team's roster JSON: {ok, team_id, members:[{id, display_name,
// user_id?, email?, roles, is_owner}]} (requires sign-in). Caller frees.
char *ostmac_team_members(const char *team_id);

// Add one user (id or UPN) to a team; owner nonzero grants the owner
// role. Returns {ok, member}. Caller frees.
char *ostmac_team_member_add(const char *team_id, const char *user, int owner);

// Remove one membership id from a team. Returns {ok, team_id,
// member_id}. Caller frees.
char *ostmac_team_member_remove(const char *team_id, const char *member_id);

// Message history JSON for one chat (requires sign-in). Caller frees.
char *ostmac_messages(const char *chat_id, int limit);

// Older history page: page_token is the previous response's opaque cursor.
// Caller frees.
char *ostmac_messages_page(const char *chat_id, const char *page_token, int limit);

// Teams message search (Graph /search/query, one from/size window):
// {ok,query,from,size,total?,more,next_from?,hits:[{message_id,chat_id,
// team_id?,channel_id?,sender,timestamp,preview,subject?}]}. chat_id is
// the conversation to open (channel id for channel hits). Empty query
// is rejected pre-network; size clamps to 1..=25 (<=0 means 25).
// Requires sign-in. Caller frees.
char *ostmac_search(const char *query, int from, int size);

// Post one message to a chat. Caller frees.
char *ostmac_send(const char *chat_id, const char *text);

// Add one emoji reaction to a message. Caller frees.
char *ostmac_react(const char *chat_id, const char *message_id, const char *emoji);

// Remove one emoji reaction from a message. Caller frees.
char *ostmac_react_remove(const char *chat_id, const char *message_id, const char *emoji);

// Post one quote reply to a chat message: parent_id is the quoted
// message id, parent_sender/parent_text attribute the quote block
// (blank sender/text fall back to "?"/parent id in core).
// Returns {ok, chat_id}. Caller frees.
char *ostmac_reply(
    const char *chat_id, const char *parent_id,
    const char *parent_sender, const char *parent_text,
    const char *text);

// Post one reply into a channel thread (core-a): posts to the reply
// chain <channel_id>;messageid=<root_id>, not a new top-level post.
// channel_id must be a channel (19:...@thread.tacv2/.skype).
// Returns {ok, chat_id, root_id}. Caller frees.
char *ostmac_thread_reply(
    const char *channel_id, const char *root_id, const char *text);

// One chat's roster (core-a): {ok, chat_id, source:"graph"|"chatsvc",
// members:[{mri, user_id?, display_name, email?, roles, is_owner}]}.
// Graph first, chat-service fallback (names may be ""). Caller frees.
char *ostmac_chat_members(const char *chat_id);

// Create a group chat (core-a G5, Graph POST /chats): users_json is a
// JSON array of user refs (AAD ids or UPNs; self added by core); topic
// may be NULL. {ok, chat:{id, name, is_group, ...}}. Caller frees.
char *ostmac_chat_create_group(const char *users_json, const char *topic);

// Edit one own message: {ok, chat_id, message_id}. Caller frees.
char *ostmac_edit(const char *chat_id, const char *message_id, const char *text);

// Delete one own message: {ok, chat_id, message_id}. Caller frees.
char *ostmac_delete(const char *chat_id, const char *message_id);

// Leave one group chat (remove self from the thread roster):
// {ok, chat_id}. Caller frees.
char *ostmac_leave(const char *chat_id);

// Mark one conversation read up to a message (consumption horizon PUT):
// {ok, chat_id, message_id}. Caller frees.
char *ostmac_mark_read(const char *chat_id, const char *message_id);

// Peer read positions for one thread:
// {ok, thread_id, receipts:[{user, message_id, horizon}]}. Caller frees.
char *ostmac_receipts(const char *thread_id);

// Fetch one inline-image URL: {ok, data_base64, content_type?}.
// Microsoft media hosts attach the Skype token; public hosts fetch
// without auth. https only. Requires sign-in for auth'd hosts.
// Caller frees.
char *ostmac_media_fetch(const char *url);

// Shared files JSON for one chat/channel (requires sign-in). Caller frees.
char *ostmac_files(const char *chat_id, int limit);

// Shared files, optionally including folders (om-i5-folders):
// include_folders nonzero keeps folder driveItems (each is_folder).
// Same {ok, chat_id, files} envelope. Caller frees.
char *ostmac_files_opts(const char *chat_id, int limit, int include_folders);

// One folder's children by drive+item id (requires sign-in): files AND
// subfolders, unfiltered. Returns {ok, drive_id, item_id, files}.
// Caller frees.
char *ostmac_files_children(const char *drive_id, const char *item_id, int limit);

// Recently accessed files across OneDrive + SharePoint (top10-files,
// requires sign-in). limit<=0 means 25. Returns {ok, files:[...]}
// (Shared-tab row shape, files only). Caller frees.
char *ostmac_files_recents(int limit);

// Upload a local file to a chat/channel + post reference message
// (<=4 MB one PUT, larger via a resumable upload session).
// Returns {ok, file}. Caller frees.
char *ostmac_files_upload(const char *chat_id, const char *path);

// Meeting recordings, newest first (OneDrive + channel Recordings
// folders, requires sign-in). limit<=0 means 50. Returns
// {ok,recordings:[{id,name,size,mime?,web_url?,download_url?,
// drive_id?,created?,modified?,duration_ms?,source}]}. Caller frees.
char *ostmac_recordings_list(int limit);

// One recordings search window (requires sign-in). limit<=0 means 50.
// Returns {ok,query,recordings:[...]} (same row shape). Caller frees.
char *ostmac_recordings_search(const char *query, int limit);

// Meeting transcripts, newest first (OneDrive + channel Recordings
// folders, requires sign-in). limit<=0 means 50. Returns
// {ok,transcripts:[{id,name,size,mime?,web_url?,drive_id?,created?,
// modified?,source}]}. Caller frees.
char *ostmac_transcripts_list(int limit);

// One transcripts search window (requires sign-in). limit<=0 means 50.
// Returns {ok,query,transcripts:[...]} (same row shape). Caller frees.
char *ostmac_transcripts_search(const char *query, int limit);

// Create a view-only sharing link for one driveItem (Graph createLink).
// scope NULL/empty = organization (org-only); "anonymous" = anyone link.
// Returns {ok, link, scope}. Caller frees.
char *ostmac_files_link(const char *drive_id, const char *item_id, const char *scope);

// Current upload progress (pure read, no network, never fails):
// {ok, uploaded, total, percent, active}. Poll while an upload
// spinner runs. Caller frees.
char *ostmac_files_upload_progress(void);

// Download one driveItem's content to dest path.
// Returns {ok, path, bytes}. Caller frees.
char *ostmac_files_download(const char *drive_id, const char *item_id, const char *dest);

// Version history for one driveItem (requires sign-in):
// {ok, drive_id, item_id, versions:[{id,size,modified?,modified_by?}]},
// newest first. Caller frees.
char *ostmac_file_versions(const char *drive_id, const char *item_id);

// Restore one version as current (Graph restoreVersion action).
// Returns {ok, drive_id, item_id, version_id}. Caller frees.
char *ostmac_file_version_restore(
    const char *drive_id, const char *item_id, const char *version_id);

// Download one old version's content to dest path.
// Returns {ok, path, bytes}. Caller frees.
char *ostmac_file_version_download(
    const char *drive_id, const char *item_id,
    const char *version_id, const char *dest);

// Rename one driveItem (PATCH name). Returns {ok, file}. Caller frees.
char *ostmac_files_rename(const char *drive_id, const char *item_id, const char *new_name);

// Move one driveItem to another folder (same drive). Returns {ok, file}.
// Caller frees.
char *ostmac_files_move(const char *drive_id, const char *item_id, const char *dest_folder_id);

// Copy one driveItem to another folder (same drive, async server-side).
// new_name may be NULL to keep the source name. Returns {ok, monitor}.
// Caller frees.
char *ostmac_files_copy(const char *drive_id, const char *item_id, const char *dest_folder_id, const char *new_name);

// Delete one driveItem. Returns {ok, id}. Caller frees.
char *ostmac_files_delete(const char *drive_id, const char *item_id);

// OneDrive file search by name/content (requires sign-in): one $top
// window (limit<=0 means 25). Returns {ok, query, files:[SharedFile]}.
// Caller frees.
char *ostmac_file_search(const char *query, int limit);

// Directory people search by display name (requires sign-in): one $top
// window (limit<=0 means 25). Returns {ok, query, people:[TeamMember]}
// (roles empty: directory hits carry no team role). Caller frees.
char *ostmac_people_search(const char *query, int limit);

// To Do lists JSON (requires sign-in): {ok,lists:[{id,name,wellknown?}]}.
// Caller frees.
char *ostmac_reminders(void);

// Tasks for one To Do list: {ok,list_id,tasks:[{id,title,status,
// importance,due?,reminder?,completed}]}. Caller frees.
char *ostmac_reminder_tasks(const char *list_id, int limit);

// Create one task in a list: {ok,task}. Caller frees.
char *ostmac_reminder_add(const char *list_id, const char *title);

// Mark one task completed: {ok,task}. Caller frees.
char *ostmac_reminder_done(const char *list_id, const char *task_id);

// Planner: one team's plans (group id == team id, requires sign-in):
// {ok,group_id,plans:[{id,title}]}. Caller frees.
char *ostmac_planner_plans(const char *group_id);

// Planner: one plan's buckets: {ok,plan_id,buckets:[{id,plan_id,name}]}.
// Caller frees.
char *ostmac_planner_buckets(const char *plan_id);

// Planner: one plan's tasks (limit<=0 means 100):
// {ok,plan_id,tasks:[{id,plan_id,bucket_id,title,percent,completed,
// priority?,due?,etag}]}. Caller frees.
char *ostmac_planner_tasks(const char *plan_id, int limit);

// Planner: create one task in a bucket: {ok,task}. Caller frees.
char *ostmac_planner_add(const char *plan_id, const char *bucket_id,
                         const char *title);

// Planner: complete one task (percentComplete 100, If-Match etag):
// {ok,task}. Caller frees.
char *ostmac_planner_done(const char *task_id, const char *etag);

// Planner: reopen one task (percentComplete 0, If-Match etag): {ok,task}.
// Caller frees.
char *ostmac_planner_reopen(const char *task_id, const char *etag);

// Planner: assign (assign!=0) or unassign one user on one task
// (assignments PATCH, If-Match etag): {ok,task}. Task JSON carries
// "assignees":[user ids]. Caller frees.
char *ostmac_planner_assign(const char *task_id, const char *etag,
                            const char *user_id, int assign);

// NOTE (R14 om-later-b4 B4): meetings/presence moved to Swift
// (CoreReads); decls deleted.
// NOTE (R12 ffi-move-now B1): meeting_join_parse moved to Swift
// (JoinParse); decl deleted.

// Week-window meetings JSON (Graph calendarView [week_start,
// week_start+days], requires sign-in): {ok,week_start,days,
// meetings:[{id,subject,start?,end?,join_url?,organizer?,
// organizer_email?,is_organizer,is_online}]}. week_start<=0 means now; days<=0 means 7. Caller frees.
char *ostmac_cal_week(long long week_start, int days, int limit);

// Schedule one meeting (requires sign-in + Calendars.ReadWrite):
// {ok,event:{...}}. online!=0 requests a Teams link. Caller frees.
char *ostmac_cal_schedule(
    const char *subject, const char *start, const char *end,
    const char *time_zone, int online);

// Cancel one meeting (requires sign-in): {ok,id}. Caller frees.
char *ostmac_cal_cancel(const char *event_id);

// Resolve a typed meeting ID + passcode (core-c; Graph onlineMeetings
// joinMeetingId lookup, requires sign-in + OnlineMeetings.Read):
// {ok,found:true,join_url,subject?,passcode_required} | {ok:true,
// found:false} | {ok:false,error:"passcode"|"arg"|"meetid"}. passcode
// may be NULL. Caller frees.
char *ostmac_meeting_resolve_id(const char *meeting_id, const char *passcode);

// One team's schedule week JSON (Graph schedule API, read-only,
// requires sign-in): {ok,team_id,schedule:{enabled,time_zone,
// provision_status},shifts:[{id,user_id?,display_name,start?,end?,
// theme?,notes?,is_draft}],times_off:[...],reasons:[{id,name,
// code?}]}. Empty team_id yields {ok:false} pre-network. Caller frees.
char *ostmac_schedule_week(const char *team_id);

// Same envelope as ostmac_schedule_week, but only shifts / time off
// overlapping [start, end] (ISO-8601 date-times), filtered server-side,
// every page. Bad bounds yield {ok:false,error:"arg"} pre-network.
// Caller frees.
char *ostmac_schedule_range(const char *team_id, const char *start,
                            const char *end);

// Start background Trouter push: 0 ok, -1 running, -2 no auth, -3 rt fail.
int ostmac_trouter_start(void);

// Drain queued Trouter events as JSON. Caller frees.
char *ostmac_trouter_poll(void);

// Blocking drain: waits up to timeout_ms for the first event instead
// of returning empty immediately (0 = poll without waiting). Same
// envelope as ostmac_trouter_poll. Call off the main thread. Caller frees.
char *ostmac_trouter_poll_wait(uint64_t timeout_ms);

// Drain queued Trouter events as typed realtime messages:
// {ok, messages:[{chat_id,id,sender,text,time,is_edit,edited_id?}],
// resync, skipped}. resync=true means a trouter.message_loss frame arrived:
// the UI must re-fetch visible conversations (push had a gap; the socket is
// fine, no reconnect needed). Drains the same queue as ostmac_trouter_poll —
// use one consumer. Caller frees.
char *ostmac_trouter_poll_typed(void);

// Blocking typed drain: waits up to timeout_ms for the first event
// (0 = poll without waiting). Same envelope as
// ostmac_trouter_poll_typed. Call off the main thread. Caller frees.
char *ostmac_trouter_poll_typed_wait(uint64_t timeout_ms);

// Stop background Trouter: 0 stopped, -1 idle.
int ostmac_trouter_stop(void);

// Refresh AAD + derived tokens via the stored refresh token:
// {ok, refreshed, tokens?}. refreshed=false means no refresh token stored
// (run device flow). Caller frees. Hits network when a refresh token exists.
char *ostmac_refresh(void);

// Clear all stored tokens (sign out); drops pending device sessions.
// {ok:true} or {ok:false}. Caller frees. No network.
char *ostmac_sign_out(void);

// Sign one account profile out (clears its tokens, deletes a
// non-default profile file; other profiles untouched). Caller frees.
char *ostmac_sign_out_for(const char *profile);

// Refresh one account profile's tokens (no active switch). Same
// envelope as ostmac_refresh. Caller frees.
char *ostmac_refresh_for(const char *profile);

// Set own preferred presence. status is one of (case-insensitive):
// available, busy, dnd (donotdisturb), away, offline.
// Returns the applied {ok,availability,activity}. Caller frees.
char *ostmac_presence_set(const char *status);

// One other user's presence JSON (Entra ID or UPN):
// {ok,id,availability,activity}. Caller frees. Hits network.
char *ostmac_presence_user(const char *user_id);

// Resolve a Teams MRI (8:orgid:<aad-oid>) to a Graph user:
// {ok,id,email?,display_name}. {ok:false,error:"not_found"} for unknown
// users (permanent). Caller frees. Hits network.
char *ostmac_resolve_mri(const char *mri);

// OneNote notebooks JSON: {ok,notebooks:[{id,name}]}. group_id NULL/empty
// reads the user's own; otherwise the M365 group (team) notebooks.
// Requires sign-in. Caller frees. Hits network.
char *ostmac_notes(const char *group_id);

// One notebook's sections, each with pages:
// {ok,sections:[{id,name,pages:[{id,title,updated?}]}]}. Caller frees.
char *ostmac_note_sections(const char *notebook_id, const char *group_id);

// One page's HTML content: {ok,id,title,html}. Caller frees.
char *ostmac_note_page(const char *page_id, const char *group_id);

// Append one plain-text paragraph to a page: {ok,id}. Caller frees.
char *ostmac_note_append(const char *page_id, const char *text, const char *group_id);

// Current call slot JSON: {ok, call:{id,dir,peer,peer_name,thread,
// state,controller?,started_at,detail?}|null}. Caller frees. No network.
char *ostmac_call_status(void);

// Place an outgoing call to a thread id (1:1 or channel), signaling
// only. Blocks up to timeout_secs (clamped 5..120) waiting for the
// answer: {ok,placed,accepted,rejection?,call}. Caller frees.
char *ostmac_call_place(const char *thread_id, int timeout_secs);

// Place the echo-bot test call, signaling only. Same envelope as
// ostmac_call_place. Caller frees.
char *ostmac_call_echo(int timeout_secs);

// Place an outgoing call with live media attached on acceptance:
// {ok,placed,accepted,live_media,call}. Caller frees.
char *ostmac_call_place_live(const char *thread_id, int timeout_secs);

// Place a 1:1 video call with live media (Audio + Video modalities).
// Same envelope as ostmac_call_place_live; group/channel threads fail
// with code "unsupported". Caller frees.
char *ostmac_call_place_live_video(const char *thread_id, int timeout_secs);

// Place the echo-bot test call with live media. Same envelope as
// ostmac_call_place_live. Caller frees.
char *ostmac_call_echo_live(int timeout_secs);

// Accept the ringing incoming call with live media:
// {ok,accepted,media_answered,live_media,call}. Caller frees.
char *ostmac_call_accept_live(void);

// Accept the ringing incoming call with live media as a video call
// (acceptedCallModalities Audio + Video). Same envelope. Caller frees.
char *ostmac_call_accept_live_video(void);

// Live media engine stats:
// {ok, media:{running,audio_sent,audio_recv,video_sent,video_recv,
// send_queued,send_dropped,recv_pending,recv_dropped,
// ice_audio,ice_video,error?,started_at}}. Caller frees. No network.
char *ostmac_call_media(void);

// Stop the live media engine: {ok, media}. Caller frees.
char *ostmac_call_media_stop(void);

// Mute/unmute the live call mic (nonzero = muted), sticky across calls:
// {ok, muted}. Stored when idle, honored by the next call. Caller frees.
// No network.
char *ostmac_call_mute(int muted);

// Select the call speaker route (NULL/"" = system default): {ok, speaker}.
// Stored always; reroutes a live call without dropping the current device
// on failure. Caller frees. No network.
char *ostmac_call_speaker(const char *name);

// Framed NAL payload (both directions): u32LE nal_count (1..=32), then
// per NAL u32LE len + raw bytes (no start codes). Total fits 4 MiB.
// Push one send-side access unit in that layout. Over-cap pushes drop
// the oldest unit. Returns {ok, queued}. Caller frees.
char *ostmac_video_send_push_bytes(const uint8_t *data, size_t len);

// Drain the newest incoming access unit into a framed NAL payload:
// 1 = AU present (*out set, caller frees with ostmac_bytes_free),
// 0 = none (*out NULL), -1 = null out-param. *dropped counts the stale
// units discarded ahead of the newest.
int ostmac_video_poll_incoming_bytes(uint8_t **out, size_t *out_len, int *dropped);

// Offline loopback: run queued send units through packetize -> SRTP ->
// depacketize -> incoming queue (no network/auth/hardware).
// {ok, units, packets, aus, nals}. Caller frees.
char *ostmac_live_loopback(void);

// Accept the ringing incoming call:
// {ok,accepted,media_answered,call}. Caller frees.
char *ostmac_call_accept(void);

// End/decline the active call: {ok,ended,call}. Caller frees.
char *ostmac_call_end(void);

// Inject the recorder bot into the connected outgoing call:
// {ok,injected,response_bytes}. Caller frees.
char *ostmac_call_record_inject(void);

// NOTE (R12 ffi-move-now B1): av_info moved to Swift (CoreLocal);
// decl deleted.

// Mic/speaker availability probe (cpal open+close, fast). Caller frees.
char *ostmac_mic_probe(void);

// Capture `seconds` (1-10, default 3) of mic + play back:
// {ok, frames, seconds, peak_db, played_back} or {ok:false, error:"no_input"}.
// Caller frees. Blocks for the capture duration.
char *ostmac_mic_test(int seconds);

// Play 1kHz tone for `msecs` (default 1000): {ok, frames} or
// {ok:false, error:"no_output"}. Caller frees. Blocks while playing.
char *ostmac_tone_play(int msecs);

// NOTE (R12 ffi-move-now B2): tone_check moved to Swift (ToneDsp);
// decl deleted.

// Audio device display names + system defaults:
// {ok, inputs[], outputs[], default_input, default_output}. Caller frees.
char *ostmac_audio_devices(void);

// Named-device mic test (NULL/"" = default):
// {ok, frames, seconds, peak_db, played_back} or
// {ok:false, error:"no_input"|"unknown_device"}. Caller frees. Blocks.
char *ostmac_mic_test_on(int seconds, const char *input, const char *output);

// Named-device tone play (NULL/"" = default output).
// Caller frees. Blocks while playing.
char *ostmac_tone_play_on(int msecs, const char *output);

// Short mic level sample for a live meter:
// {ok, peak_db, has_input} (never errors; no device -> has_input=false).
// Caller frees. Blocks ~msecs + 100ms setup.
char *ostmac_mic_level(int msecs, const char *input);

// Begin a camera run (Swift AVCapture feeds frames). Caller frees.
char *ostmac_camera_begin(int width, int height, int fps);

// Push one camera frame: raw pixels, fmt i420|nv12|bgra (420v|32bgra
// aliases). Convert failures count as drops. Returns stats JSON.
// Caller frees.
char *ostmac_camera_push_bytes(
    const uint8_t *pixels, size_t len, int width, int height, const char *fmt);

// Camera stats JSON. Caller frees.
char *ostmac_camera_stats(void);

// End the camera run. Caller frees.
char *ostmac_camera_end(void);

// Push one decoded remote I420 frame (raw bytes) for display. Caller frees.
char *ostmac_video_push_remote_bytes(
    const uint8_t *data, size_t len, int width, int height);

// Drain latest remote frame: 1 = frame (*out set, caller frees with
// ostmac_bytes_free), 0 = none (*out NULL), -1 = null out-param.
int ostmac_video_poll_remote_bytes(
    int *width, int *height, uint8_t **out, size_t *out_len);

// Black 176x144 IDR access unit as base64 NALs (VideoToolbox target).
// Caller frees.
char *ostmac_av_black_iframe(void);

// Offline call pipeline: SRTP loopback + H.264 packetize round-trip
// (no network/auth/hardware). Caller frees.
char *ostmac_call_dry_run(void);

// Free a string from any ostmac_* call. Null-safe.
void ostmac_free(char *s);

// Free a byte payload from any *_bytes poll call. Null-safe; len must
// be the length the poll reported.
void ostmac_bytes_free(uint8_t *ptr, size_t len);

#endif
