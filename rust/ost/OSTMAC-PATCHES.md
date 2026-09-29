# OstMac patches on vendored ost

Upstream ref: `TeamsNotifier/tmp/refs/eisbaw_ost` (read-only). This copy is
vendored so the spike can build on macOS and expose a library surface.

Tags: [minor] = bugfix/small improvement, no API/architecture change.
[major] = new modules, lib surface, platform code, or behavior change
needing maintainer buy-in. Minor PRs stand alone; majors are separate PRs.

1. [minor] `src/calling/sdp_compress.rs` — **build fix (upstream bug)**.
   `SDP_DICTIONARY: &[u8; 20623]` but `sdp_dictionary.bin` is 20476 bytes →
   E0308. Changed to unsized `&[u8]`, dropped two `.as_slice()` calls.
2. [minor] `src/tui/app.rs` — **stay open unsigned**.
   Unsigned, the backend task exits → channel closes → `run_app` broke the
   loop → exit 0 with no UI. Now the loop survives backend death (guarded
   `select!` branch) so layout + auth error stay visible and navigable.
3. [major] `src/event_hub.rs` (new) + 1 line in `src/trouter/mod.rs` + `mod` in
   `src/main.rs` — **Trouter event channel**. Frame handler publishes event
   JSON to an in-process queue; embedders drain via `event_hub::drain`.
4. [major] `Cargo.toml` (`[lib]` name `ost` + `[[bin]]`) + `src/lib.rs` (new) —
   **library surface**. Same modules as the binary, `pub`, so `ostmac-core`
   reuses auth/api/trouter without forking. Binary untouched.
5. [minor] `src/api/chat.rs` — **message ids for embedders (om-conv lane)**.
   `MessageInfo` gains `id` (server `NativeMessage.id`, synthetic
   `timestamp@sender` fallback) so Swift can match realtime edits in place.
   TUI mapping is field-wise reads; only the constructor here changed.
6. [minor] `src/api/chat.rs` `read_messages_data` — **skip media payloads (om-conv)**.
   `RichText/Media_*` stripped to "TitlePlay" fragments (CallRecording) or
   raw JSON (CallTranscript); now skipped. Empty display names fall back to
   `"?"` like missing ones. TUI list benefits identically.
7. [minor] `src/api/chat.rs` — **history paging + raw HTML (om-convrich lane)**.
   New `read_messages_page` follows `_metadata.backwardLink` for older pages
   (live-verified: no overlap, chainable; `startTime=` alone is ignored by
   the server); `pageSize` rewritten per call. `MessagesPage`/`read_messages_page`
   re-exported in `src/api/mod.rs`. `MessageInfo` gains `raw` (unstripped
   HTML for mention/code mining). `read_messages_data` keeps its signature
   (delegates, newest page). TUI untouched.
8. [minor] `src/calling/audio.rs` — **audio test utils + device pickers
   (om-av, extended om-av-polish)**. `audio_probe()`, `mic_test_report(seconds,
   vu)` (`mic_test()` delegates), `play_tone(msecs)`; named devices via
   `start_on`, `input/output_device_names`, `default_input/output_name`,
   `mic_test_report_on`, `play_tone_on`; metering via `frame_db`,
   `mic_level_sample`. Robustness: serialized CoreAudio setup lock, bounded
   waits (`poll_started` replaces fixed sleep), unknown names fail fast.
9. [minor] `src/trouter/mod.rs` — **`TEAMS_MANUAL_CALLS` gate**.
   Set to take call accept/end in embedding UI; the invitation is still
   published to `event_hub` either way. Unset = auto-answer as before.
10. [minor] `src/calling/recording.rs` — **`TEAMS_DEBUG_DUMP` gate**.
    Full add-recorder response was written to `/tmp` unconditionally;
    now only when the env var is set. CLI sets it for protocol analysis.
11. [major] `src/calling/macav.rs` (new, 514 lines) + `pub mod macav` —
    **macOS A/V bridge, Rust side (om-av lane)**. I420 conversion, camera/
    remote frame slots fed by Swift AVCapture, tone echo check, black-frame
    NAL source, offline call dry-run (tone→PCMU→RTP→SRTP round-trip plus
    black IDR packetize/depacketize). No network, no auth, unit-testable.
12. [minor] `src/api/media.rs` (new) + `media_get` in `src/api/client.rs` +
    `has_image` keep in `src/api/chat.rs` (om-richmedia lane) — **inline
    media fetch**. `fetch_media_data` downloads chat `<img>` bytes (15MB
    cap, https-only); `needs_auth` keeps the Skype token on Microsoft
    hosts, public URLs fetch bare. Image-only bubbles (empty stripped
    text) survive the filter. Re-exported in `src/api/mod.rs`.
13. `src/tui/` deleted + `Tui` subcommand + `mod tui` wiring (`main.rs`,
    `lib.rs`) + `ratatui`/`crossterm`/`tokio-stream`/`unicode-width` deps —
    [major][LOCAL-ONLY, do not upstream] **drop TUI from our vendored copy**.
    Diet Teams (SwiftUI) replaces the UI; the TUI is eisbaw's product, we
    keep our copy lean (CLI debug surface + `ostmac-core` lib only). All CLI
    subcommands (`chats`/`read`/`send`/`call-test`/etc) unchanged. 8 TUI unit
    tests drop with the module; zero failures expected elsewhere.
14. [major] `src/api/files.rs` (new) + `src/api/client.rs` + `src/api/mod.rs` +
    `src/main.rs` — **chat shared files via Graph driveItems (om-shared lane)**.
    `SharedFile`/`list_chat_files_data`/`download_file_data`/`upload_file_data`
    re-exported in `src/api/mod.rs`. Chats: Graph `/me/chats/{id}/messages`
    `reference` attachments resolved via `/shares/{u!b64}/driveItem` (deduped
    by item id, folders skipped); channels: team scan + `filesFolder` +
    `/drives/{d}/items/{i}/children`. CLI: `files`, `files-download`,
    `files-upload`. `client.rs` gains `graph_put_bytes` (drive PUT). Upload is
    small-file PUT only (<4 MB, chat folder "Microsoft Teams Chat Files") +
    `reference` message post (attachment id = GUID from driveItem eTag,
    contentUrl = webDavUrl/webUrl). No auth scope change: existing Graph token
    (`/.default`) already carries Files.Read/Write. Unit tests: share-id
    round-trip, segment encoding, eTag GUID scan, children/message parsing,
    attachment preference.

15. [major] `src/api/todo.rs` (new) + `src/api/mod.rs` + `src/api/client.rs` +
    `src/main.rs` — **Microsoft To Do lists/tasks (om-remind lane)**.
    Graph `/me/todo/lists`, `/lists/{id}/tasks` (GET), create (POST),
    complete (PATCH `status: completed`). `TodoListInfo`/`TodoTaskInfo`
    + `*_data` fns re-exported; CLI `todo` (bare lists, `--list`,
    `--add/--to`, `--done/--to`). `client.rs` gains generic `graph_patch`.
    Auth: existing Graph token, NO scope widening (Teams client id already
    consents Tasks.ReadWrite; 403 surfaces as the call detail). Ids breaking
    the path (`/`, `?`, `#`, whitespace) rejected pre-network. TUI untouched.

16. [major] `src/api/notes.rs` (new) + `src/api/client.rs` (`graph_patch_raw`) +
    `src/main.rs` (`Notes` cmd) — **OneNote read + paragraph append
    (om-notes lane)**. `list_notebooks_data` (`/me` or `/groups/{id}` scoped),
    `list_notebook_sections_data` (sections with nested pages; failed pages
    fetch warns + empties, teams.rs parity), `read_note_page_data` (raw HTML,
    title scraped from `<title>`), `append_note_paragraph_data` (PATCH with
    hand-rolled multipart Commands, no new deps). CLI: `notes [--group]`,
    `--notebook` lists sections+pages, `--page` prints stripped text,
    `--page --append` appends then prints. Auth scopes unchanged: the
    existing Graph `/.default` exchange covers OneNote (delegated perms ride
    the first-party client); no new consent requested.

17. [minor] `src/api/chat.rs` + `src/api/client.rs` (`chat_delete`) +
    `src/api/mod.rs` + `src/main.rs` (`React` cmd) — **message reactions
    (om-reactions lane)**. Emoji↔type map (`REACTION_EMOJI`, the six Teams
    types), `reaction_add_url/body` + `reaction_remove_url` builders,
    `send/remove_reaction_with_client` (POST/DELETE
    `.../messages/{id}/reactions` with skypetoken auth, Graph-mirrored
    shape), `MessageInfo.reactions` grouped counts parsed from top-level
    or `properties.reactions` (unknown types dropped). CLI: `react --to
    --message-id <emoji> [--remove]`. NOT YET VERIFIED LIVE: the add/
    remove wire shape is best-effort (Graph resource layout over the
    native chat service); confirm with `react` against a signed-in box
    before upstreaming. Unit tests: emoji map, endpoint shapes, grouping
    order, nested/unknown/missing reaction payloads.
18. [minor] `src/api/chat.rs` + `src/api/mod.rs` + `src/main.rs` —
    **quote replies (om-replies lane)**. `MessageInfo` gains `reply_to`
    (parent id mined from the first `<quote guid>` block; `content` is the
    reply body only, `raw` keeps the full HTML). Pure helpers
    `reply_snippet` (one-line, 140 chars + `…`), `build_reply_html`
    (Skype-style `<quote author guid>` + `<p>` body, all fields escaped),
    `split_reply_quote` (malformed quotes keep content, never drop it),
    re-exported in `src/api/mod.rs`. Send path:
    `reply_message_with_client` posts `RichText/Html` with the quote block
    (official clients render it as a quote); `reply_message` resolves the
    parent from the newest history page for attribution. CLI: `send
    --reply-to <id>`; `read` marks replies `(reply to <id>)`. Unit tests:
    snippet collapse/truncate (incl. multibyte boundary), build→split
    round-trip with escaping, malformed-quote cases.
19. [minor] `src/api/chat.rs` — **chat names: mate resolve, system
    labels, spacing-aware strip (om-chatnames lane)**. `conversation_name`
    fallback is now topic → resolved 1:1 mate → last sender → system
    label, never the raw thread id (`48:notifications` → `Notifications`,
    else `[Direct message]`/`[Group chat]`/`[Meeting chat]`/`[Chat]`).
    1:1 mate names resolve via MRI: thread roster (`GET
    /v1/threads/{id}/members`, read-only) minus self (whoami OID suffix
    match) leaves the mate, attributed to the newest message carrying
    that MRI (`MessageInfo` gains `sender_mri`, parsed from the `from`
    user link). Best-effort: roster/history/whoami failures keep the
    sender/label fallback, never fail the list. `strip_html` is
    spacing-aware: block-tag boundaries yield one space (`</p><p>`
    no longer glues words), inline tags vanish silently, no
    leading/trailing space. Dup-name threads are real: live fetch shows
    distinct server threads sharing a display name (e.g. two 1:1s with
    one mate), not a client duplication — no dedup applied. Unit tests:
    strip boundaries, name fallback chain, MRI parse/match, roster
    shape. Live-verified 2026-09-23 (`chats`: labels applied, 1:1s
    mate-named).

20. [minor] `src/api/media.rs` + `src/api/client.rs` +
    `tests/imgfix_live_probe.rs` (new) — **live AMS fetch fix (om-imgfix
    lane)**. Inline images 401d: the ASM object-store family
    (`*.asm.skype.com`, `*.asyncgw.teams.microsoft.com`) authenticates
    with `Authorization: skype_token …`, not the chat-service scheme
    (`Authentication: skypetoken=` + `X-SkypeToken`), which is kept for
    chat-hosted views (`…msg.teams.microsoft.com…`). New pure
    `media::auth_headers` picks the scheme per host; `media_get`
    delegates transport to `media_fetch` so the mocked repro matrix
    (local TCP stub, no new deps) pins all three legs: ASM/chat header
    mapping, same-host 302 follow, 401 surfacing, non-image shape
    passthrough, 15 MB cap. `MediaBytes` gains `Debug`. Committed
    `#[ignore]`d live probe harvests one AMS `<img>` from newest pages
    then issues a single redirect-disabled GET with production headers
    (status/size/shape booleans only, bytes discarded). Verified: live
    probe pre-fix 401 on `us-api.asm.skype.com …/views/imgo`; matrix
    red→green on the mapping; app screenshots show loaded images.

21. [minor] `src/api/chat.rs` — **keep RSS/bot/card posts (om-botposts
    lane)**. `has_card_payload` (an `<attachment>` block or an O365 /
    Adaptive / MessageCard marker, case-insensitive) joins the empty-text
    keep rule next to `has_image`: card posts strip to `""` but are real
    messages — the embedder renders title+link rows from `raw`, or a
    placeholder when it cannot parse the payload — so history never
    silently drops them. CLI `read` prints `(card post)` for kept
    card-shaped empties instead of a blank line (image-only bubbles
    unchanged). Unit tests: attachment/marker detection incl. casing,
    plain/image/empty negatives.

22. [minor] `src/api/files.rs` — **scope-aware chat/channel routing
    (om-sharednotes lane)**. New `is_channel_id` (`@thread.tacv2` suffix;
    chats share the `19:` prefix but end `@thread.v2`): list tries the
    channel filesFolder path first for channel-shaped ids and the
    chat-messages path first otherwise, each keeping the other as fallback.
    Upload routes the same way, so chat uploads skip the team scan
    (joinedTeams + one channels call per team) and channel uploads fail fast
    with "no joined team contains channel" instead of mis-posting to the
    OneDrive chat folder. Unit test: tacv2 suffix cases.

23. [minor] `src/api/chat.rs` + `src/api/client.rs` + `src/api/mod.rs` +
    `src/main.rs` — **edit + delete own messages (om-editdel lane)**.
    Native chat service per-message URL (`PUT` edit with `skypeeditedid`,
    `DELETE` remove); pure `message_url`/`edit_message_body` builders so
    embedders pin the wire shape. `client.rs` gains `chat_put`/`chat_delete`
    (skypetoken auth, `chat_post` parity). Re-exported in `mod.rs`; CLI
    `edit --to --message-id` / `delete --to --message-id`. Unit test:
    URL + escaped-body shape.

24. [major] `src/api/calendar.rs` (new) + `src/api/mod.rs` + `src/main.rs`
    (`Meetings` cmd) — **upcoming meetings + join-URL parse + lobby
    machine (om-meet-join lane)**. `MeetingInfo`/`list_upcoming_meetings_data`
    read Graph `/me/calendar/calendarView` (next 7 days, soonest first);
    UTC datetimes format via std-only civil-date math (no chrono).
    `parse_join_url` classifies pasted strings: `thread` (meetup-join
    links with a decoded `19:…@thread…` id, or bare thread ids),
    `meeting-id` (`teams.live.com/meet/<id>`), `url` (other https,
    opened as-is), `unknown` (never dialed). `LobbyState`
    (`idle|joining|lobby|admitted|failed`) + `LobbyEvent` + pure
    `lobby_next` model the waiting-room flow for embedders.
    Re-exported in `mod.rs`; CLI `meetings [--limit]`,
    `meetings --parse <url>`. Auth scopes unchanged: existing Graph
    `/.default` covers `Calendars.Read` (403 surfaces as the detail).
    Unit tests: calendar parse/defaults, query shape, date spot checks,
    join-URL matrix, lobby transitions.

25. [minor] `src/api/chat.rs` + `src/api/mod.rs` —
    **read receipts: consumption-horizon send + peer positions
    (om-receipts lane)**. `ReadReceipt` (user key + last-read message id
    + raw horizon); pure `consumptionhorizon_url` (`PUT
    `.../v1/users/ME/conversations/{id}/properties?name=consumptionhorizon`)
    / `consumptionhorizons_url` (`GET
    `.../v1/threads/{id}/consumptionhorizons`) / `consumptionhorizon_value`
    (`"<now_ms>;<now_ms>;<message_id>"`) / `consumptionhorizon_body` /
    `receipt_message_id` (text after the last `;`, blank → `None`)
    builders; `mark_read_with_client` (PUT, empty ids rejected
    pre-network) + `read_receipts_data` (GET, read-only).
    `parse_consumptionhorizons` is tolerant: missing/empty lists yield
    `vec![]`, unparseable entries are dropped, bare-string entries use
    `""` as the user key, user via `mri` → `id` → `user` → display name.
    Re-exported in `mod.rs`; no CLI (embedder-driven). Unit tests:
    endpoint/body shapes, id split incl. blanks, tolerant parse incl.
    missing/empty lists.

26. [minor] `src/calling/audio.rs` — **F32 audio path + open/resolve
    error split + fail-fast setup (om-av-fix lane)**. Streams build as F32
    (i16 rejected by CoreAudio: "stream configuration not supported") with
    `f32_to_i16`/`i16_to_f32`/`f32_interleaved_to_mono_i16` conversion in
    the callback accumulator (mic + speaker; multi-channel downmixed).
    `AudioStartError::{UnknownDevice,NoDevice,OpenFailed}` splits
    resolve-fail from open-fail (`start_on_detailed`; `mic_test_report_on`/
    `play_tone_on` propagate it); `start_on` keeps its `Option` shape for
    probe/meter/media callers. Setup reports over a oneshot channel so
    `build_*_stream` errors return in milliseconds instead of burning the
    10 s poll timeout on every path (mic test, meter, probe, tone).
    Unit tests: converter scale/clamp/mono/stereo/6ch, error display
    prefixes, detailed-unknown determinism. Live-verified 2026-09-24
    (MacBook mic + BoomAudio resolve AND open; mic_test dB numbers,
    tone_play exit 0).

27. [minor] `src/api/chat.rs` + `src/api/mod.rs` + `src/main.rs` —
    **leave chat (om-leave-block lane)**. `leave_chat_with_client`
    removes self from one thread's roster via
    `DELETE .../v1/threads/{id}/members/{mri}` (skypetoken auth,
    existing `chat_delete` with `None` body); the own MRI resolves via
    `whoami_data` (`8:orgid:{oid}`, see `own_member_mri`), pure target
    in `leave_member_url`. Empty chat ids (and empty owner ids) bail
    pre-network. `leave_chat` CLI entry (`teams-cli leave --to <id>`)
    prints "Left chat.". Best-effort: NOT live-verified — do not
    upstream until `leave` succeeds against a signed-in box (same bar
    as ledger 17 reactions). Unit tests: MRI + endpoint shapes.

28. [minor] `src/api/teams.rs` — **channel list detail (om-h1-listdetail
    lane)**. `ChannelInfo` gains `description`, `membership_type`,
    `web_url` (all `Option<String>`, from Graph `description` /
    `membershipType` / `webUrl` on `GET /teams/{id}/channels`).
    Additive fields only; `list_teams` output and TUI unchanged.
    Live findings (tacv2 channel ids through chat-service endpoints):
    `send` / `mark_read` / `delete` accept tacv2 ids;
    `read_receipts_data` 403s (`AclCheckFailed`, not a roster member;
    chats OK); `react` 404s on `/reactions`. Receipts/reactions on
    channels need a different (likely Graph) path; not implemented.

29. [minor] `src/api/teams.rs` + `src/api/mod.rs` —
    **join team by id (om-h2-join lane)**. New `join_team_data(client,
    team_id)` self-enrolls via `POST /teams/{id}/members`
    (`aadUserConversationMember`, no roles; own user id resolved from
    Graph /me first). Trims id; rejects empty + path separators before
    network. Re-exported in `src/api/mod.rs`. Join-by-code NOT Graph
    (6-char codes redeem only via undocumented teams.microsoft.com web
    API) — out of scope. TUI untouched.

30. [minor] `src/api/teams.rs` + `src/api/mod.rs` —
    **channel creation (om-h3-create lane)**. New
    `create_channel_data(client, team_id, name, description)` via Graph
    `POST /teams/{team-id}/channels` (body `displayName` + optional
    `description`), returning `ChannelInfo` (`ChannelInfo` shape
    unchanged). Pure `create_channel_path` / `create_channel_body`
    pinned by unit tests; shared `channel_info` mapper now feeds both
    list and create paths. NOT verified live against the server in
    this lane; a 403 surfaces as the call's detail. Team creation
    (`POST /teams`) deliberately excluded: Graph returns 202 + async
    provisioning (Content-Location poll), left for a follow-up lane.
    TUI untouched.

31. [minor] `src/api/tabs.rs` (new) + `src/api/mod.rs` + `src/main.rs` —
    **channel tabs read-only (om-h4-tabs lane)**. New `TabInfo` (`id`,
    `name`, `app_id`, `content_url`, `website_url` — link-out targets
    only, no content) from Graph
    `GET /teams/{team}/channels/{channel}/tabs`. `list_tabs_data`
    resolves the owning team via a joinedTeams scan (files.rs parity);
    empty ids bail pre-network, unknown channels post-scan. CLI:
    `teams-cli tabs <channel_id>` (read-only). Additive module only;
    existing commands and TUI unchanged. Live findings (tacv2
    channels): the list carries Files/Notes/website tabs with
    deep-link URLs; Posts is absent (built-in, not returned).

32. [minor] `src/api/teams.rs` + `src/api/client.rs` + `src/api/mod.rs` +
    `src/main.rs` — **team roster: list/add/remove members + owners
    (om-h5-members lane)**. New `TeamMemberInfo` (membership id,
    display_name, user_id?, email?, roles, is_owner from
    `roles.contains("owner")`); `list_team_members_data` (Graph
    `GET /teams/{id}/members`), `add_team_member_data` (Graph
    `POST /teams/{id}/members`, `aadUserConversationMember` body,
    optional `owner` role), `remove_team_member_data` (Graph
    `DELETE /teams/{id}/members/{membership-id}`). Pure
    `members_path` / `member_path` / `add_member_body` pinned by unit
    tests; ids guarded (empty + `/ ? #` + whitespace rejected before
    network, todo.rs pattern). New `TeamsClient::graph_delete`.
    CLI: `teams-cli members --team <id> [--owners]` lists,
    `--add <user-or-upn> [--owner]` adds, `--remove <membership-id>`
    removes (`--add`+`--remove` exclusive). Re-exported in
    `src/api/mod.rs`. Missing displayName falls back to membership
    id; blank stays blank (Swift caller-fallback owns names). NOT
    verified live against the server in this lane; 403 surfaces as
    call detail. TUI untouched.

33. [minor] `src/api/files.rs` + `src/api/mod.rs` —
    **folder listing + children endpoint (om-i5-folders lane)**.
    `SharedFile` gains `is_folder` (driveItem `folder` facet);
    `list_chat_files_data` delegates to new
    `list_chat_files_data_opts(.., include_folders)` (default false,
    shape stable); new `list_folder_children_data(drive_id, item_id,
    limit)` (`GET /drives/{d}/items/{i}/children`, unfiltered) plus
    pure `folder_children_path`. Re-exported in `src/api/mod.rs`.
    TUI untouched.

34. [minor] `src/api/files.rs` + `src/api/mod.rs` + `src/main.rs` —
    **view-only sharing links (om-i1-links lane)**. New
    `SharedLink{url, scope}`; `create_link_data` (`POST
    /drives/{d}/items/{i}/createLink`, view-only);
    `normalize_link_scope` (blank/unknown normalizes to
    `organization`, least privilege; `anonymous` opt-in);
    `create_link_body` / `create_link_path` / `parse_create_link`.
    `SharedFile` gains `share_url` (None at list; Swift caches the
    created link per file id). CLI: `files-link` subcommand; `files`
    list prints the Drive id. Idempotent server-side (same scope,
    same link). TUI untouched.

35. [minor] `src/api/files.rs` + `src/api/mod.rs` —
    **file version history (om-i2-versions lane)**. New `FileVersion`
    (`id`, `size`, `modified`, `modified_by`) +
    `list_file_versions_data` (`GET /drives/{d}/items/{i}/versions`,
    newest first), `restore_file_version_data` (`POST
    .../versions/{v}/restoreVersion`), `download_file_version_data`
    (`GET .../versions/{v}/content`). Additive only; existing
    files/upload/download paths untouched. TUI untouched.

36. [minor] `src/api/files.rs` + `src/api/mod.rs` —
    **driveItem rename/move/copy/delete (om-i3-manage lane)**. New
    `rename_file_data` (PATCH name), `move_file_data` (PATCH
    parentReference), `copy_file_data` (`POST .../copy`, 202 +
    monitor URL), `delete_file_data` (DELETE, 204 no body) plus pure
    `drive_item_path` / `rename_body` / `move_body` / `copy_body`
    pinned by unit tests. Re-exported in `src/api/mod.rs`. No CLI
    commands added (FFI lane). TUI untouched.

37. [major] `src/api/files.rs` + `src/api/client.rs` + `src/api/mod.rs` +
    `src/main.rs` — **resumable file uploads >4 MB (om-i4-bigup lane)**.
    `upload_file_data` no longer bails over `MAX_SIMPLE_UPLOAD`: files
    <=4 MB keep the single simple PUT, larger files use a Graph resumable
    session (`POST .../createUploadSession` with `conflictBehavior:
    replace` matching simple-PUT overwrite semantics, then sequential
    5 MiB fragment PUTs to the pre-authenticated `uploadUrl`). New
    `TeamsClient::drive_session_put` (absolute-URL PUT, no bearer,
    `Content-Range`/`Content-Length` headers; 202 continues, 200/201
    returns the driveItem). Progress: new
    `upload_file_data_with_progress` (`(sent, total)` per fragment;
    simple PUT reports once at completion); old `upload_file_data`
    delegates with no sink. Pure `upload_chunk_ranges` /
    `content_range_value` / `upload_session_body` pinned by unit tests.
    CLI `files-upload` streams `\rUploading N%` to stderr. Channel and
    chat destinations share the session path (channel resolves the team
    filesFolder first, as before); the `reference` message post is
    unchanged. NOT live-verified against Graph in this lane (no test
    chat; session wire shape per Graph resumable-upload docs). TUI
    untouched (still builds).

38. [minor] `src/api/client.rs` + `src/auth/skype.rs` + `src/trouter/mod.rs` —
    **shared reqwest pool (om-s1-rtshare lane)**. New
    `api::client::shared_http()` (`OnceLock` process-wide `Client`;
    `Client::clone` shares the pool); `TeamsClient::new`, skype token
    exchange, and the trouter registrar use it (was: `Client::new()` per
    call, no TLS connection reuse). Same requests, same results. TUI
    untouched.

39. [minor] `src/config/mod.rs` + `src/event_hub.rs` + `src/api/client.rs` +
    `src/auth/oauth.rs` + `src/trouter/mod.rs` + `src/calling/call_test.rs` —
    **in-memory config cache + blocking event wait (om-s5-cachepoll
    lane)**. `Config::load_cached` reuses an in-memory copy while the
    file's (size, mtime) is unchanged; `save()` writes through the cache,
    so in-process updates stay coherent and external writers are picked
    up on mtime change. Same results as `load`, no disk read + TOML parse
    on hits. Call sites (`TeamsClient::new`, oauth, trouter registrar,
    call test) use `load_cached`. `event_hub` gains
    `drain_wait(max, timeout_ms)` (condvar; wakes on `publish`, timeout
    yields whatever is queued) and `len()` for backlog reporting. TUI
    untouched.

40. [major] `src/api/search.rs` (new) + `src/api/mod.rs` + `src/main.rs` —
    **Teams message search (om-ja-search lane)**. New
    `search_messages_data` (Graph `POST /search/query`, `entityTypes
    ["chatMessage"]`, `from`/`size` paging) returning `SearchPage`
    (`hits`, `total?`, `more`); `SearchHitInfo` (`message_id`, `chat_id`,
    `team_id?`, `channel_id?`, `sender`, `timestamp`, `preview`,
    `subject?`). `chat_id` = chat thread, or channel id for channel hits
    (those carry no `chatId`). Pure `search_body` /
    `parse_search_response` / `clamp_size` (1..=25, `SEARCH_MAX_SIZE`) /
    `next_from` pinned by unit tests; blank queries bail pre-network.
    Re-exported in `src/api/mod.rs`. CLI `teams-cli search <query>
    [--limit]`. No scope change (existing Graph token). NOT live-verified
    (stored Graph token expired; wire shape per MS chat-message search
    docs) — confirm with `search` on a signed-in box before upstreaming.
    TUI untouched.

41. [major] `src/api/filesearch.rs` (new) + `src/api/client.rs` +
    `src/api/mod.rs` + `src/main.rs` — **file + people search
    (om-jb-filesearch lane)**. New `search_files_data` (OneDrive `GET
    /me/drive/root/search(q='{q}')`, parsed into `SharedFile` rows —
    search projects no eTag GUID, so no bubble-match key) and
    `search_people_data` (Graph `GET /users?$search="displayName:{q}"`,
    parsed into `TeamMemberInfo` rows with empty roles, `user_id` = user
    id, email = mail else UPN). New `TeamsClient::graph_get_consistent`
    (GET with `ConsistencyLevel: eventual`; `$search` 400s without it).
    Pure `drive_search_path` (quote-doubling + URL-encode) /
    `people_search_path` (quotes dropped + URL-encode) /
    `parse_drive_search_response` / `parse_people_search_response` /
    `clamp_limit` (1..=25, `FIND_MAX_LIMIT`) pinned by unit tests; blank
    queries bail pre-network; id-less items skipped. Re-exported in
    `src/api/mod.rs`. CLI `teams-cli file-search` / `people-search
    <query> [--limit]`. No scope change. NOT live-verified (stored Graph
    token expired; shapes per MS driveitem-search + `$search` docs) —
    confirm on a signed-in box before upstreaming. TUI untouched.

42. [minor] `src/api/teams.rs` + `src/api/mod.rs` — **channel message
    reactions, Graph groundwork (om-je-parity lane)**. Pure builders
    `channel_set/unset_reaction_path` (+ reply variants) pinning the v1.0
    docs shapes (`/teams/{id}/channels/{id}/messages/{id}/[replies/{r}/]
    (set|unset)Reaction`), `channel_react_body` (`{"reactionType": emoji}`,
    unicode per docs), `set/unset_channel_reaction_data` (id guards +
    picker-emoji validation reused from `REACTION_EMOJI` before any
    network; 204, no body). Unit tests: docs path shapes, unicode body.
    NOT live-verified (refresh token expired when this landed): the
    unicode-vs-named `reactionType` form, the `ChannelMessage.Send` grant
    on the first-party client id, and the Graph-vs-chat-service message
    id mapping need a signed-in probe before any core/Swift caller is
    wired. Receipts stay on HOLD: Graph v1.0 exposes no channel
    read-receipt API and the chat-service consumptionhorizons call 403s
    on channel threads (H1 baseline). No behavior change: new fns only,
    no callers yet.

43. [minor] `src/api/teams.rs` + `src/api/client.rs` + `src/api/mod.rs` —
    **team CREATE: async Graph POST /teams + operation poll
    (om-jf-teamcreate lane)**. New `create_team_data` (Graph `POST /teams`
    with `teamsTemplates('standard')` bind + `displayName` + optional
    `description` + caller as owner member via `/me`; 202 +
    `Content-Location` polled every 3s until the `teamsAsyncOperation`
    reports `succeeded`/`failed` or 120s elapse; non-202 answers parse as
    a sync team fallback). New `TeamsClient::graph_get_url`
    (absolute-URL GET, same Graph bearer). Returns `TeamCreateResult`
    (team + `polls` + `elapsed_ms`); created team refetched with channels
    (channel errors degrade to empty, same as `list_teams_data`). Pure
    `create_team_path` / `create_team_body` / `operation_succeeded` /
    `operation_failed` / `operation_team_id` (`targetResourceId` first,
    else `targetResourceLocation` `/teams('guid')` or `/teams/guid`) /
    `operation_url` (absolute passes through, relative expands under
    Graph v1.0) pinned by unit tests; empty names rejected before
    network. Re-exported in `src/api/mod.rs`. No CLI commands added (FFI
    lane). NOT verified live against the server in this lane (would create
    a real team; wire shape per Graph create-team docs). TUI untouched
    (still builds).

44. [minor] `src/api/chat.rs` — **channel reply parent mining
    (om-lt2-quotelink lane)**. `NativeMessage` / `MessageProperties` gain
    flattened `extra` maps (unknown wire fields survive deserialize);
    `message_parent_id` mines the thread parent case-insensitively from
    top-level → `properties.*` → content-embedded forms. Keys:
    `rootMessageId` (native channel cards, H0 live probe in
    om-channel-history) + `replyToId` (Graph channel shape) +
    `parentMessageId` / `parentId` fallbacks; string values trim,
    numbers stringify, null/empty drop. `parent_id_from_content` scans
    Media_Card payloads byte-wise (`"key":"val"`, `key="val"`, `key:123`,
    any quote/sep mix; unterminated drops, Unicode-safe). In
    `read_messages_page` the quote `<guid>` parent still wins; the wire
    parent is the fallback so channel threads (no quote block) ride
    `reply_to` into the existing Swift quoteBlock. Self/blank parents
    drop (corrupt-wire guard). Unit tests: top-level root/reply ids +
    lowercase variant, properties nesting, content JSON + attr forms,
    missing/empty/null/unterminated → None. Wire field confirmed during
    lane: `rootMessageId` on channel cards (H0 probe note); `replyToId`
    accepted per Graph chatMessage docs (channel-only, read-only parent
    id). `backwardLink` confirmed NOT a parent signal (page cursor in
    `_metadata`, unchanged). Swift surface (quote-link tap) is
    Swift-only, no ledger item.

45. [minor] `src/api/chat.rs` + `src/api/mod.rs` — **Graph 1:1 chat
    create (om-lt5-person11 lane)**. New `one_to_one_create_path`
    (`POST /me/chats`), `one_to_one_create_body` (oneOnOne + peer as
    owner member), `parse_created_chat`, `create_one_to_one_chat_data`;
    re-exported in `src/api/mod.rs`. Unit tests: create path/body +
    created-chat parse. No existing-1:1 lookup (Graph mints a thread
    per call — minimal path, dupes possible). Unverified live (no
    signed-in runs in lane scope). Consumer: `ostmac-core`
    `chat_create_one_to_one_json` + `ostmac_chat_create_one_to_one` FFI
    (empty-user/null guards, unit-tested); Swift person-pick wiring is
    Swift-only, no ledger item.

46. [major] `src/api/planner.rs` (new) + re-exports in `src/api/mod.rs` —
    **Planner boards (om-planner lane)**. Team → plans → buckets +
    tasks via the Graph Planner API: `plans_path`, `buckets_path`,
    `tasks_path`, `task_path` builders; `parse_plans`,
    `parse_buckets`, `parse_tasks`, `parse_task`; `list_plans_data`,
    `list_buckets_data`, `list_tasks_data`, `create_task_data`
    (`create_task_body`), `set_task_complete_data`
    (`set_complete_body`, complete/reopen via PATCH + If-Match etag).
    9 unit tests (docs-grounded fixtures). Deliberately NOT in
    `src/api/client.rs` (no shared `graph_patch_etag`; the module
    builds its own If-Match PATCH from cached config) and no CLI
    subcommand in `src/main.rs` this wave. Unverified live (refresh
    dead per PARTIAL-flex-15; no signed-in runs). Consumer:
    `ostmac-core` `planner.rs` + 6 FFI exports
    (`ostmac_planner_plans/buckets/tasks/add/done/reopen`, 6 tests);
    Swift Planner tab (models/core/demo/view-model/browser + 20
    PlannerTests) is Swift-only, no ledger item.

47. [minor] `src/api/calweek.rs` (new) + re-exports in `src/api/mod.rs` —
    **calendar week view + schedule/cancel (om-calendar lane)**.
    Extends the ledger-24 calendar surface: `calweek_view_path` (GET
    `/me/calendar/calendarView` + `$top/$orderby/$select`,
    Calendars.Read), `list_week_meetings_data`, `validate_schedule`,
    `schedule_event_body` (POST `/me/calendar/events`,
    `isOnlineMeeting` + `teamsForBusiness` toggle; join URL reads
    back at `onlineMeeting.joinUrl`), `parse_created_event`,
    `schedule_meeting_data` (Calendars.ReadWrite), and
    `cancel_meeting_data` (DELETE `/me/calendar/events/{id}`). 7
    fixture tests. Unverified live (no signed-in runs; ReadWrite
    consent on the first-party client id unconfirmed). Consumer:
    `ostmac-core` `calweek.rs` (`calweek_json`/`calschedule_json`/
    `calcancel_json` + `ostmac_cal_week/schedule/cancel` exports, 4
    tests); Swift week grid + schedule sheet + store (17
    CalendarWeekTests) is Swift-only, no ledger item. Skipped v1:
    edit/reschedule (occurrence PATCH recurrence semantics) and an
    attendees picker.

48. [minor] `src/api/schedule.rs` (new) + re-exports in `src/api/mod.rs` —
    **Shifts schedule week, read-only (om-shifts lane)**. One team's
    7-day schedule via the Graph schedule API:
    `list_schedule_data` (GET `/teams/{id}/schedule`),
    `list_shifts_data`, `list_timesoffs_data`,
    `list_timeoff_reasons_data`, plus a `list_shifts` CLI helper
    (no `src/main.rs` subcommand this wave). 3 unit tests. NO writes
    v1 (no swap/time-off requests by design). Unverified live (no
    signed-in runs). Consumer: `ostmac-core` `schedule.rs` (one
    combined `schedule_week_json` — single FFI round-trip for the
    grid — + `ostmac_schedule_week` export, 4 tests); Swift Shifts
    tab + store (11 ShiftsTests) is Swift-only, no ledger item.
    Time-off "balances" are approved-instance counts per reason
    (Graph has no balances endpoint) — proxy pending owner confirm.

49. [major] `src/api/recordings.rs` (new) + re-exports in `src/api/mod.rs` —
    **meeting recordings browser, drive-backed (om-recordings lane)**.
    OneDrive `Recordings` folder + per-channel SharePoint `Recordings`
    folders: `recordings_children_path`, `recordings_search_path`
    (drive search), `channel_files_folder_path`, `folder_children_path`,
    `clamp_limit` (50, `RECORDINGS_MAX_LIMIT`, `MAX_CHANNEL_DRIVES` 50);
    `RecordingSource` (OneDrive / Channel team+channel + `label`) +
    `RecordingInfo` (id, name, size, mime, web/download urls,
    drive_id, created/modified, `duration_ms` from the driveItem
    `video` facet, source); `is_video` (video/ mime or mp4/mov/m4v
    ext), `parse_recordings_response` (folders/non-video/id-less
    skipped), `sort_newest`, `is_not_found` (404→empty);
    `list_recordings_data` (OneDrive + channel fan-out, only a total
    failure errors) + `search_recordings_data`. 10 fixture tests. No
    CLI subcommand (FFI lane). Live status: paths return 200 on the
    tenant (B2 P2/P3: Recordings children + search 200-empty); E2E
    synthetic round-trip proven via the transcripts twin (§50, same
    wire shape: PUT→search→GET→parse→DELETE); zero real .mp4 on the
    tenant, so no real-data E2E. Consumer: `ostmac-core`
    `recordings.rs` FFI list/search + Swift RecordingsBrowser/VM
    (27 tests); merged R2 `48e0ded`.

50. [major] `src/api/transcripts.rs` (new) + re-exports in `src/api/mod.rs` —
    **meeting transcripts browser, drive-backed (om-transcripts-build
    lane)**. Mirrors §49 for `.vtt` files: `transcripts_children_path`,
    `transcripts_search_path`, `channel_files_folder_path`,
    `folder_children_path`, `clamp_limit` (50), `TranscriptSource`,
    `TranscriptInfo`, `is_transcript` (`.vtt`-only — a `.docx` twin was
    REJECTED by live probe: 7 drive `.docx` hits, all unrelated, none
    in `Recordings`, none transcript-named), `parse_transcripts_response`
    (folders/non-vtt/id-less skipped), `sort_newest`, `is_not_found`,
    `list_transcripts_data` + `search_transcripts_data`. 10 fixture
    tests. No CLI subcommand (FFI lane). Live-verified E2E self-only
    (TEST-labeled, deleted back): PUT 201 → search FOUND (attempt 2,
    index lag) → GET 409 bytes identical → shipped Swift parser 4
    cues → DELETE 204 + re-GET 404, prod footprint zero. Zero real
    transcripts on the tenant (owner transcribes 1 meeting for
    real-data E2E — non-blocking). Consumer: `ostmac-core`
    `transcripts.rs` FFI (3 tests) + Swift browser/parser/VM (33
    tests); merged `d13a8d5`. No new auth/scopes.

51. [minor] `src/calling/call_test.rs` (+6/-5) — **send audio RTP with
    the SDP-advertised SSRC (om-testcall lane)**. `spawn_media_leg`
    minted a random-uuid audio SSRC while the offer declared
    `x-ssrc-range audio_ssrc`; the echo bot filters undeclared SSRCs
    → 0 return RTP. `audio_ssrc` is now threaded via
    `MediaLeg`/`setup_media_leg` (video_ssrc parity); the random SSRC
    is deleted. Genuine signaling bugfix, not OstMac-specific.
    Live-verified end to end: random-SSRC call 0 audio return
    (`echo_detected=false`); declared-SSRC call 1251 sent / 409 rcvd,
    `echo_detected=true`, delay 965.8ms, corr 0.995. Merged R2
    `f22161f` (rust 234/0 on the merge tree).

52. [major] `src/config/mod.rs` + `src/auth/oauth.rs` + `src/api/client.rs` —
    **per-account token profiles (d1-accounts lane)**. `Config` gains a
    profile id: `default` (or blank) keeps the legacy `config.toml`;
    every other id maps to `config-<sanitized>.toml` beside it (0600,
    sanitize = alnum + `._-`, cap 64, no separators survive). New
    `load_for`/`load_cached_for`/`save_to`/`delete_for`/
    `invalidate_cache_for`/`config_path_for` + process-wide
    `active_profile`/`set_active_profile` (default `default`); the
    load cache is now a per-profile map. Legacy `load`/`load_cached`/
    `save` route through the active profile, so the CLI and TUI are
    byte-identical single-account until something calls
    `set_active_profile`. `oauth::refresh_for(profile)` and
    `TeamsClient::new_for_profile(profile)` scope network refresh +
    client build to one profile (`refresh()`/`new()` delegate to
    active). 3 config tests (path separation + hostile ids, active
    round-trip, missing-delete). Consumer: `ostmac-core` twins
    (`status/refresh/sign_out/whoami/device_start/authcode_start`
    `_for` variants + `profile_set`/`profile_active` FFI, per-profile
    whoami cache, session→profile binding; no ledger item — own crate).
   Upstream: https://github.com/eisbaw/ost/pull/50 (wave 8, after
   #30).
53. [minor] `src/calling/signaling.rs` — **parameterized region headers
    (om-region-headers lane)**. New `TeamsRegion { partition, region,
    ring }` (`Default` = AMER `amer03`/`amer`/`general`) + `TeamsHeaders`
    `RequestBuilder` extension applying the three `ms-teams-*` headers;
    all 8 signaling call sites go through it (byte-identical default).
    Consts kept as the `Default` source. 2 tests (amer default
    vs non-amer override, offline `Request::build` inspection). Next:
    thread region through `ConversationCallParams`/recording params
    from config so non-AMER tenants stop using the default.
    Follow-up (same lane): `region: &TeamsRegion` on both params
    structs; all 8 signaling sites + `add_recorder_bot` read
    `params.region`; entry points source
    `TeamsRegion::from_env_or_default()` (`TEAMS_PARTITION`/
    `TEAMS_REGION`/`TEAMS_RING` env, per-field AMER fallback; +2
    tests, hermetic `with_overrides`).
    Upstream: https://github.com/eisbaw/ost/pull/52 (filed
    2026-09-25, base 0892144; lane hunk minus the RecordingParams
    retype, which stacks after as §54; recording.rs conv_params
    construction fix included for the new required field; doc
    line drops the RecordingParams mention for standalone
    review; 95/95 bin tests with sdp-dance temp-fix reverted;
    offline vectors only, no live non-AMER call — stated in
    body; config-file derivation §57).

54. [minor] `src/calling/turn.rs` + `Cargo.toml`/`Cargo.lock` —
    **RFC 5389 MD5 long-term credential key (om-turn-md5 lane)**.
    `compute_long_term_key` ignored its MD5(username:realm:password)
    contract and returned raw password bytes (short-term fallback
    with a TODO); every authenticated Allocate/Permission/ChannelBind
    derived the wrong HMAC key against long-term servers. Now
    `md5::compute` via new `md5 = "0.8"` dep. 2 key-vector tests
    (user:realm:pass, empty) cross-checked against system md5(1);
    MI/fingerprint test re-keyed through the same helper. Genuine
    signaling bugfix, not OstMac-specific. Merged `4129087`
    (lanes/om-turn-md5).
    Upstream: https://github.com/eisbaw/ost/pull/51 (filed
    2026-09-25, base 0892144; verbatim lane hunk, 93/93 bin tests
    with sdp-dance temp-fix reverted; unit vectors only, no live
    TURN-server verification — stated in body).
    (Renumbered §53→§54: disambiguates the duplicate §53 from the
    om-region-headers lane; entry order preserved, no history
    rewrite — cf. wave-2 and wave-8 dup notes. PR #51's body cites
    no ledger number, so no upstream mismatch.)

54. [minor] `src/calling/recording.rs` — **region-threaded
    recorder-base fallback (om-recorder-region lane)**.
    `RecordingParams` gains `region`; `extract_recorder_from_payload`
    + `wait_for_recorder_info` take a caller-supplied
    `fallback_region` instead of hardcoded `TEAMS_REGION`
    (`DEFAULT_RECORDER_REGION = "amer"`, captured traffic is
    AMER/USEA). Payload callrecorder-hostname extraction stays the
    primary path; the region map feeds only the fallback.
    Follow-up: `eu`/`emea` aliases pinned to the EUWE base +
    case/whitespace test. Region-headers lane later retyped the
    field to `&TeamsRegion` (its slug feeds the fallback; §53
    region-headers). Tests: recorder-base region variance,
    primary-path precedence, eu-alias pin. Genuine signaling
    generalization, not OstMac-specific. Merged `7296487` + alias
    pin `5b93357` (both on main @ `98e3e33`).
    (Numbering note: two §54 entries — turn-md5 renumbered §53→§54
    after this entry was written; left as-is per the wave-2 dup-17/19
    precedent. Neither PR #51's nor #53's body cites a ledger number,
    so no upstream mismatch.)
    Upstream: https://github.com/eisbaw/ost/pull/53 (filed
    2026-09-25, stacks after #52 on `TeamsRegion`, only the top
    commit new; recording.rs only, 102/102 bin tests with the
    sdp-dance temp-fix reverted; offline vectors only, no live
    non-AMER call — stated in body).

55. [minor] `src/calling/recording.rs` — **gate recorder frame
    dumps behind `TEAMS_DEBUG_DUMP` (om-recorder-region lane)**.
    `wait_for_recorder_info` wrote `/tmp/recorder_trouter_payload.json`
    + `/tmp/recorder_frame_N.json` unconditionally on every frame;
    only the add-recorder response dump honored the opt-in gate.
    New `debug_dump_enabled`/`write_debug_dump` helpers (pure
    `enabled` param keeps tests hermetic, `with_overrides` pattern);
    all 3 dump sites go through them. 2 tests (disabled writes
    nothing, enabled round-trips content).
    Upstream: UNFILED (stacks with §54).

57. [minor] `src/config/mod.rs` + `src/calling/signaling.rs`/
    `call_test.rs`/`recording.rs` — **config-file region derivation
    (om-region-headers lane)**. Closes the §53 open item: `Config`
    gains optional `teams_partition`/`teams_region`/`teams_ring`
    (old TOMLs parse, all-None); `TeamsRegion::from_config` (pure,
    hermetic) + `from_config_or_env` (per-field env > config >
    AMER default; supersedes `from_env_or_default`). Call-test
    entry builds one region from the loaded config; recorder entry
    takes `region: &TeamsRegion` instead of re-sourcing env (sole
    caller updated). 2 tests (config round-trip + legacy parse,
    per-field config vectors incl. header reach). Genuine
    signaling generalization, not OstMac-specific.
    Upstream: UNFILED (stacks after §53 region-headers).

58. [minor] `src/calling/signaling.rs` — **restore
    `TeamsRegion::from_env_or_default` (perf-harness-build lane)**.
    Base e87c64f red: §57 removed it as superseded but two
    ostmac-core calls.rs sites (recorder + call-place, no config
    in scope) still call it (E0599 x2). Thin wrapper over
    `with_overrides` (env > AMER default per field); no behavior
    change elsewhere.
    Upstream: UNFILED (bugfix; file separately from majors).

59. [minor] `src/api/files.rs` + re-exports in `src/api/mod.rs` —
    **drive recents (top10-files lane)**. New `drive_recents_path`
    (`/me/drive/recent?$top=N`, clamped ≥1) + async
    `list_drive_recents_data` (same driveItem-collection parse as
    the children path, folders filtered for the stable files-only
    list shape, sender None). Feeds the unified Files surface's
    OneDrive/SharePoint leg: catches drive uploads no conversation
    list shows yet (e.g. Q&A exports). 2 tests (path shape +
    folders-skipped parse).
    Upstream: UNFILED (small feature; file with minors).

60. [minor] `src/api/chat.rs` + re-exports in `src/api/mod.rs` —
    **`<pre>` for fenced code blocks on the wire (wire-pre lane)**.
    New `build_message_html` (fence parser mirroring Swift
    `CodeBlocks`: ```/~~~, ≥3 run, info w/o fence char, closer ≥
    opener length, unclosed runs to end, 50-block cap) + `send_message_body`
    captured-body seam. Send/edit/reply bodies route through it:
    fenced blocks go out as `<pre>` (byte-exact code, fences/info
    consumed) so other clients keep indents; fence-less prose keeps
    the legacy single-`<p>` shape bit-identical. 6 tests (prose
    regression, byte-exact `<pre>`, mixed segments, unclosed fence,
    block cap, reply/edit carry).
    Upstream: UNFILED (behavior fix; file with minors).

## Upstream PRs (2026-09-22, base 0892144; main red on sdp E0308 until #5)

Minor (standalone modulo #5-first; merge in any order after):
- (a) bugfixes sdp+tui: https://github.com/eisbaw/ost/pull/5
- (b) chat API ids+media+paging+fetch: https://github.com/eisbaw/ost/pull/6
- (c) audio test utils: https://github.com/eisbaw/ost/pull/7
- (d) debug gates MANUAL_CALLS+DEBUG_DUMP: https://github.com/eisbaw/ost/pull/8
Major (need maintainer buy-in):
- (e) [major] macav module: https://github.com/eisbaw/ost/pull/9
- (f) [major] event_hub+lib surface: https://github.com/eisbaw/ost/pull/10

## Upstream PRs, wave 2 (2026-09-23, base 0892144; ledger renumbered 17–23
preserving entry order — dup 17s/19s disambiguated, no history rewrite)

Major (need maintainer buy-in; branch names predate the [major] tag):
- (g) [major] files (ledger 14): https://github.com/eisbaw/ost/pull/11
- (h) [major] todo (ledger 15): https://github.com/eisbaw/ost/pull/12
- (i) [major] notes (ledger 16): https://github.com/eisbaw/ost/pull/13
Minor (stacked: merge after the noted base; only each PR's top commit is new):
- (j) quote replies (ledger 18, after #6): https://github.com/eisbaw/ost/pull/14
- (k) chat names (ledger 19, after #6): https://github.com/eisbaw/ost/pull/15
- (l) AMS imgfetch fix (ledger 20, after #6 + #10 — lib surface needed to
  compile the integration probe): https://github.com/eisbaw/ost/pull/16
- (m) bot/card posts (ledger 21, after #6): https://github.com/eisbaw/ost/pull/17
- (n) shared scope routing (ledger 22, after #11): https://github.com/eisbaw/ost/pull/18
- (o) edit + delete msgs (ledger 23, after #6; DELETE takes an optional JSON
  body, deletes pass None): https://github.com/eisbaw/ost/pull/19
Skipped: ledger 17 reactions (wire shape NOT live-verified — confirm with
`react` against a signed-in box before upstreaming); ledger 13
[LOCAL-ONLY, do not upstream].

## Upstream PRs, wave 3 (2026-09-24, base 0892144)

Minor (stacked: merge after the noted base; only the PR's top commit is new):
- (p) read receipts (ledger 25, after #19 — needs `chat_put`;
  #19 after #6): https://github.com/eisbaw/ost/pull/20
- (r) F32 audio path + error split (ledger 26, after #7):
  https://github.com/eisbaw/ost/pull/22
Major (need maintainer buy-in):
- (q) [major] calendar (ledger 24): https://github.com/eisbaw/ost/pull/21

## Upstream PRs, wave 4 (2026-09-24, base 0892144; origin/main still 0892144)

Minor (stacked: merge after the noted base; only the PR's top commit is new):
- (s) channel list detail (ledger 28): https://github.com/eisbaw/ost/pull/23
- (t) channel tabs (ledger 31, after #23):
  https://github.com/eisbaw/ost/pull/24
- (u) file folders (ledger 33, after #11 + #18 — extends `api::files`):
  https://github.com/eisbaw/ost/pull/25
- (v) file share links (ledger 34, after #25):
  https://github.com/eisbaw/ost/pull/26
- (w) file versions (ledger 35, after #26):
  https://github.com/eisbaw/ost/pull/27
- (x) file manage (ledger 36, after #27; carries `graph_patch` +
  `graph_delete` — `graph_patch` duplicates #12's helper, keep one copy):
  https://github.com/eisbaw/ost/pull/28
- (y) shared reqwest pool (ledger 38):
  https://github.com/eisbaw/ost/pull/29
- (z) config cache + blocking event wait (ledger 39, after #10 — extends
  `event_hub`): https://github.com/eisbaw/ost/pull/30
Held (need signed-in live runs before upstreaming):
- ledger 17 reactions (wire shape NOT live-verified — confirm with `react`
  against a signed-in box; held since wave 2).
- ledger 27 leave chat (NOT live-verified — confirm `leave` succeeds
  against a signed-in box).
- ledger 29 join team (H2: no live run — POST /teams/{id}/members
  unconfirmed against the server).
- ledger 30 channel create (H3: NOT verified live — confirm channel
  creation + 403 surfacing against a signed-in box).
- ledger 32 team members (H5: NOT verified live — confirm list/add/
  remove against a signed-in box).
- ledger 37 [major] resumable uploads (I4: NOT live-verified — no test
  chat; session wire shape per Graph docs only).

## Upstream PRs, wave 5 (2026-09-24, base 0892144; origin/main still 0892144)

Minor (stacked: merge after the noted base; only the PR's top commit is new):
- (aa) channel reply parents (ledger 44, after #14 — needs `reply_to` +
  quote-split surface; #14 after #6):
  https://github.com/eisbaw/ost/pull/31
Held (docs shapes only, no live run — confirm on a signed-in box before
upstreaming):
- ledger 40 [major] message search (JA: wire shape per MS chat-message
  search docs; stored Graph token expired, no live run).
- ledger 41 [major] file + people search (JB: shapes per MS
  driveitem-search + `$search` docs; no live run).
- ledger 42 channel reactions (JE: unicode-vs-named `reactionType`, grant,
  and id mapping unconfirmed; probe auth-blocked before any network, no
  writes made).
- ledger 43 team create (JF: would create a real team; wire shape per
  Graph create-team docs, no live run).
- ledger 45 1:1 chat create (LT5: no signed-in runs; Graph mints a thread
  per call, dupes possible).
Still held from wave 4 — OWNER-BLOCKED 2026-09-24: refresh token dead
(AADSTS70043 token_expired, max lifetime 86400s; only fix is human
`teams-cli login`). Post-login harness ready (`tmp/om-live-api-verify.sh`
+ RUNBOOK, PARTIAL-flex-15). Items: ledger 17, 27, 29, 30, 32, 37.

## Upstream PRs, wave 6 (2026-09-25, base 0892144; origin/main still 0892144)

Filed WITHOUT live verification per OWNER OVERRIDE 2026-09-24 (auth
still dead, no signed-in runs possible). Every PR body states its
verification status honestly (NOT live-verified + what to confirm on a
signed-in box). Clears all wave-4 + wave-5 holds; Held list is empty.

Minor (stacked: merge after the noted base; only each PR's top commit
is new, except the two merge-base PRs noted):
- (ab) join team (ledger 29, after #23):
  https://github.com/eisbaw/ost/pull/32
- (ac) channel create (ledger 30, after #32 — `channel_info` mapper
  keeps the #23 detail fields):
  https://github.com/eisbaw/ost/pull/33
- (ad) team members (ledger 32, after #33; new `graph_delete`;
  `id_guard` test merged with #33's):
  https://github.com/eisbaw/ost/pull/34
- (ae) message reactions (ledger 17, after #19 — needs `chat_delete`;
  #19 after #6): https://github.com/eisbaw/ost/pull/35
- (af) leave chat (ledger 27, after #35):
  https://github.com/eisbaw/ost/pull/36
- (ag) 1:1 chat create (ledger 45, after #36):
  https://github.com/eisbaw/ost/pull/37
- (ah) channel reactions (ledger 42): merge of #34 (teams chain) +
  #35 (REACTION_EMOJI validation) plus the JE top commit (same
  merge-base pattern as #16); merge after #34 and #35:
  https://github.com/eisbaw/ost/pull/39
  (https://github.com/eisbaw/ost/pull/38 was the same content on the
  chat chain — same-team duplicate, all 7 JE fns byte-identical,
  CLOSED in favor of #39 which carries no duplicated `check_id` and
  shares the teams tests module.)
- (ai) team create (ledger 43, after #39; new `graph_get_url`):
  https://github.com/eisbaw/ost/pull/42
Major (need maintainer buy-in):
- (aj) [major] resumable uploads (ledger 37, after #28 — extends
  `api::files`): https://github.com/eisbaw/ost/pull/40
- (ak) [major] message search (ledger 40, after #23 — standalone
  module, no teams.rs dependency):
  https://github.com/eisbaw/ost/pull/41
- (al) [major] file + people search (ledger 41): merge of #28
  (files chain, `SharedFile` with `is_folder` + `share_url`) + #34
  (teams chain, `TeamMemberInfo`) plus the filesearch top commit
  (new `graph_get_consistent`); merge after #28 and #34:
  https://github.com/eisbaw/ost/pull/43
  (`SharedFile` gains no new fields here: the vendored
  `attachment_id` is unledgered om-inline-docs eTag mining — no
  ledger entry, no PR — and stays out of scope.)

Held: none.

Notes:
- Test counts quoted per-PR in the PR bodies (sdp dance throughout:
  temp fix for local `cargo test`, reverted, tree clean).
- Cosmetic, pre-existing: several `client.rs` doc lines (added by
  lanes and carried into PRs, e.g. PATCH/DELETE/GET helpers) read
  `(Bearer [REDACTED] with Graph token)` where eisbaw's original
  lines read `(bearer auth with Graph token)`. Doc comments only,
  no behavior impact; tool-output scrubbing artifact propagated by
  copy-paste. Deliberately left as-is in this wave for
  lane-fidelity; a one-pass cleanup can normalize all copies later.
- Merge guidance: #34's `graph_delete` duplicates #28's helper
  (identical signature + body; keep one copy at merge — same
  situation as #28's `graph_patch` vs #12's).
- #40 follow-up (f1): the `drive_session_put` doc line was restored
  to the vendored lane's exact bytes after filing (amended +
  force-pushed; the vendored source is clean on that line). The
  REDACTED note above still covers the PATCH/DELETE/GET lines.

## Upstream PRs, wave 7 (2026-09-25, base 0892144; origin/main still 0892144)

R5 wave: B1 entries (§§46–48, ledgered at the B1 merge) + R2 entries
(§§49–51). Every PR body states its per-entry verification (no blanket
override this wave); ledger entries above carry the entry text (tags
preserved).

Minor (stacked: merge after the noted base; only each PR's top commit
is new):
- (am) testcall echo SSRC (ledger 51, standalone on 0892144;
  LIVE-VERIFIED TESTCALL-PROOF: declared SSRC 1251 sent/409 rcvd,
  echo=true, 965.8ms, corr 0.995):
  https://github.com/eisbaw/ost/pull/44
- (an) calendar week + schedule/cancel (ledger 47, after #21 — reads
  reuse its parse_calendar_view/MeetingInfo; bundles graph_delete in
  client.rs, identical to the file-manage stack's, keep either):
  https://github.com/eisbaw/ost/pull/45
- (ao) Shifts schedule week (ledger 48, after #45):
  https://github.com/eisbaw/ost/pull/46
Major (need maintainer buy-in; sequential, only each top commit new):
- (ap) [major] Planner boards (ledger 46, standalone on 0892144;
  reshaped for standalone compile: If-Match PATCH via new
  client::graph_patch_etag instead of vendored-only
  load_cached/shared_http; live re-probe of the exact new path
  pending, stated in body):
  https://github.com/eisbaw/ost/pull/47
- (aq) [major] meeting recordings (ledger 49, after #47; PARTIAL live:
  B2 P2/P3 paths 200-empty, E2E synthetic round-trip via the §50
  twin, zero real .mp4 on tenant):
  https://github.com/eisbaw/ost/pull/48
- (ar) [major] meeting transcripts (ledger 50, after #48;
  LIVE-VERIFIED E2E self-only: PUT 201 → search FOUND → GET 409B
  identical → shipped parser 4 cues → DELETE 204 + re-GET 404):
  https://github.com/eisbaw/ost/pull/49

Merge order: #44 anytime; #21 → #45 → #46; #47 → #48 → #49.
Minor stacks separate from major stacks per ledger rule.

Held: none.

Notes:
- Test counts quoted per-PR in the PR bodies (sdp dance throughout:
  temp fix for local `cargo test`, reverted, tree clean): #44 91/91,
  #45 112/112 (7 new calweek), #46 115/115 (3 new schedule), #47
  100/100 (9 new planner), #48 110/110 (10 new recordings), #49
  120/120 (10 new transcripts).
- §46 live caveat: set_task_complete_data's 204-empty re-fetch of the
  task fixes the live-observed bare-PATCH wart in-PR; live re-probe
  of the exact new path pending (stated in the #47 body).
- §49 doc parenthetical updated at filing (paths now live-probed
  200-empty; was "no live probe backs this lane").
- §51 is the exact lane hunk (+6/-5) applied clean to base; §48, §50
  verbatim copies + mod.rs lines.

## Upstream PRs, wave 8 (2026-09-25, base 0892144; origin/main still 0892144)

Filed the one held item (ledger 52 [major] per-account token
profiles, d1-accounts; renumbered from a duplicate §49 at the R4
merge).

Major (need maintainer buy-in):
- (as) [major] per-account token profiles (ledger 52, after #30 —
  extends its `load_cached` cache into a per-profile map; #30 after
  #10; only the top commit new):
  https://github.com/eisbaw/ost/pull/50

Held: none.

Notes:
- Test counts quoted in the PR body (sdp dance: temp fix for the
  local `cargo test` run, reverted, tree clean): 96/96 on the stack
  (bin + lib targets; 3 new profile tests).
- Vendored lane evidence at the merge (e9a6f48): ost lib 257 passed,
  ostmac-core lib 204 passed; FFI twins (`status`/`refresh`/
  `sign_out`/`whoami`/`device_start`/`authcode_start` `_for` +
  `profile_set`/`profile_active`) consume the `_for` surface.
- Verification limit stated in the body: no live 2-account sign-in
  (second sign-in is interactive, owner-driven).

61. [major] `src/api/transcripts.rs` (behavior change) — **transcript
    `.docx` twins + search fallback + raised caps (transcripts-fix
    lane; renumbered §53→§61 by the transcripts-wiring lane — §53
    already held the region-headers entry)**. `is_transcript` widens past `.vtt`-only: `.docx`/`.doc`
    now accept when the stem contains `transcript` (case-insensitive;
    covers `transcription`), so Teams transcript twins surface while
    the build lane's 7 unrelated `.docx` still filter out (Word mime
    alone does NOT accept). `list_transcripts_data` gains a bounded
    full-drive search fallback on empty folder scans (OneDrive `.vtt`
    + `transcript`, `transcript` per channel drive; same predicate;
    `dedupe_transcripts` by drive+id). Caps raised 50 -> 100
    (`TRANSCRIPTS_MAX_LIMIT`, `MAX_CHANNEL_DRIVES`; worst-case list
    ~151 -> ~301 small sequential requests). Module docs gain the
    HONEST GAP (organizer-owned transcripts unreachable: Graph
    transcript API needs declined admin consent). 14 fixture tests
    (was 10). Consumer: `ostmac-core` `transcripts.rs` doc touch
    (100-row window); Swift `MeetingDisplayName` + `TranscriptItem`/
    `RecordingItem.displayName` (7 new tests; view wiring next wave).
62. [minor] `src/api/tabs.rs` + `src/api/mod.rs` + `src/main.rs` —
    **tabs-all dump (frame-live lane)**. New `teams-cli tabs-all`:
    every joined channel's tabs in one auth session (one Graph
    round-trip per channel; N `tabs` spawns would pay N auth setups).
    Shared `print_tabs` helper (no output change to `tabs`); sections
    split on `=== team | channel | id` headers
    (`tabs_all_section_header`, unit-tested) for the Swift app
    library parser. Read-only, no scope change.
63. [minor] `src/api/chat.rs` + `src/api/mod.rs` — **chat core gaps
    (core-a lane)**. (a) Channel thread replies:
    `thread_reply_with_client` posts the plain send body to
    `<channelId>;messageid=<rootId>` (reply chain) instead of a new
    top-level quoted post; `is_channel_conversation_id` (tacv2/skype).
    (b) Chat roster: `list_chat_members_data` — Graph
    `GET /chats/{id}/members` (names, emails, `owner` role) with
    chat-service `/v1/threads/{id}/members` fallback (MRI + Admin/User
    role; `ThreadMember` gains optional `role`/`friendlyName`);
    `ChatMemberInfo.is_owner` is role-based. (c) Group chat create:
    `create_group_chat_data` — Graph `POST /chats` `chatType:group`,
    creator + peers as `owner`, optional topic. (d) Who reacted:
    `ReactionCount.reactors` (`Reactor{id,name}`); raw reaction values
    are parsed by `reaction_counts_from_values` from Graph-like
    `reactions[].user` or native `properties.emotions[{key,users[{mri}]}]`
    (the latter previously dropped — counts now also come from it).
    `NativeReaction` removed (reactions kept as raw JSON). Tests pinned
    in `ostmac-core` (one test run covers both crates). Wire shapes are
    NOT live-verified against a tenant.

64. [minor] `src/api/teams.rs` + `src/api/mod.rs` — **public team
    search (core-b lane)**. `search_public_teams_data` searches the
    directory for joinable teams by name: Graph `GET /groups`
    `$search="displayName:<q>"` + `resourceProvisioningOptions/Any(x:x
    eq 'Team')` (`ConsistencyLevel: eventual`, `$count=true`), falling
    back on any error to `GET /teams?$filter=startswith(displayName,'<q>')`.
    `parse_public_teams` keeps `visibility == public` only (dedupe, blank
    ids dropped). Joining a hit reuses `join_team_data` (hit id = team
    id). Pure path builders + parser pinned in `ostmac-core` tests. NOT
    live-verified against a tenant (scope for `/groups` search unknown
    on the first-party client id; the `/teams` fallback is prefix-only).

65. [minor] `src/api/calendar.rs` + `src/api/calweek.rs` +
    `src/api/mod.rs` — **meeting organizer identity + join by meeting
    ID (core-c lane)**. (a) `MeetingInfo` gains `is_organizer` (Graph
    event `isOrganizer`, false when absent) and `organizer_email`
    (`organizer.emailAddress.address`); both `calendarView` `$select`s
    (upcoming + week) add `isOrganizer`. Lets embedders gate
    organizer-only actions (cancel) by identity, not display name.
    (b) Join by typed meeting ID + passcode:
    `resolve_join_meeting_id_data` — Graph `GET /me/onlineMeetings?
    $filter=joinMeetingIdSettings/joinMeetingId eq '<digits>'`
    (`OnlineMeetings.Read`) → `JoinIdResolve::{Found(ResolvedJoinId
    {join_web_url,subject,passcode_required}),NotFound,
    PasscodeMismatch}`; the typed passcode is compared only when Graph
    discloses `joinMeetingIdSettings.passcode`. Pure helpers
    `normalize_join_meeting_id` (9..=15 digits, whitespace dropped),
    `online_meeting_by_join_id_path`, `parse_join_id_lookup`. `/me`
    scope sees only meetings the user organizes or is invited to;
    embedders fall back to the web `/meet/<id>?p=` link on NotFound.
    Tests pinned in `ostmac-core`. NOT live-verified against a tenant
    (`OnlineMeetings.Read` consent on the first-party client unknown).
66. [minor] `src/api/files.rs` — **move/copy to a drive root (files3
    lane)**. Graph rejects `parentReference {"id":"root"}` on move and
    copy; `move_file_data` / `copy_file_data` now resolve the `root`
    alias via `GET /drives/{d}/root?$select=id` (`drive_root_path`)
    before the PATCH/POST. Other folder ids pass through unchanged.
    Path pinned in `manage_paths_and_bodies`. NOT live-verified.

67. [minor] `src/api/planner.rs` + `src/api/schedule.rs` +
    `src/api/mod.rs` — **Planner assignees + server-side Shifts week
    (p4b-left lane)**. (a) `PlannerTaskInfo.assignee_ids`: sorted
    `assignments` keys whose value is non-null. `set_task_assignee_data`
    PATCHes `{"assignments":{uid:{"@odata.type":
    "#microsoft.graph.plannerAssignment","orderHint":" !"}}}` (assign) or
    `{uid:null}` (unassign); body builder `set_assignment_body` guards
    the id like a path id. The task PATCH (complete/reopen/assign) moved
    into one `patch_task` helper that also sends
    `Prefer: return=representation`: Graph answers a plain PATCH with
    204 and no body, so the old complete/reopen parse of the response
    could not succeed live (behavior fix). (b) `list_shifts_range_data`
    / `list_timesoffs_range_data`: `$filter=<slot>/startDateTime le
    <end> and <slot>/endDateTime ge <start>` (overlap; each property
    once, per the List shifts note) for the shared then the draft slot,
    `@odata.nextLink` followed (20-page cap), deduped by id (shared
    wins). `schedule_range_path` guards bounds to ISO-8601 characters
    and escapes `+`. Tests: `assignments_parse_and_bodies_match_graph_docs`,
    `range_path_filters_overlap_and_guards_bounds`. NOT live-verified
    against a tenant (the overlap form of the schedule filter is not the
    docs' example shape; Planner assign needs `Tasks.ReadWrite`/Group
    scopes already used by complete).
68. [minor] `src/calling/signaling.rs` — **accept an incoming call as
    video (video1 lane)**. `accept_call` hardcoded
    `acceptedCallModalities: ["Audio"]`, so an answering endpoint could
    never accept a video call. New `accept_call_with_video(http,
    skype_token, notification, video)` sends `["Audio","Video"]` when
    `video` is set (pure helper `accepted_call_modalities`);
    `accept_call` keeps its signature and delegates with `false` (no
    behavior change for existing callers). The SDP answer already
    carried the video m-line. Outgoing 1:1 video needed no ost change
    (`invite_user(.., include_video)` existed). Test pinned in
    `ostmac-core` (`video_call_offer_answer_carry_video_mline`). NOT
    live-verified against a tenant.

69. [minor] `src/api/todo.rs` + `src/api/files.rs` + `src/api/schedule.rs`
    + `src/api/mod.rs` — **To Do reopen, one message's files, documented
    Shifts range filter (left2 lane)**. (a) `reopen_todo_task_data`
    PATCHes `{"status":"notStarted"}`; complete and reopen share
    `set_todo_task_status` / `todo_status_body`. (b)
    `list_message_files_data` resolves one message's `reference`
    attachments (chat message or channel post, `message_path`), tagging
    each file with the attachment id the body references, so file chips
    resolve past the first shared-files page. (c) `list_shifts_range_data`
    / `list_timesoffs_range_data` now use the docs' containment shape
    `$filter=<slot>/startDateTime ge <from> and <slot>/endDateTime le
    <to>` over a window padded by `range_pad_days` (per collection), then
    keep only rows overlapping `[start, end]` client-side
    (`overlaps_range`) — replaces §67(b)'s undocumented overlap filter;
    overlap semantics unchanged. Tests: `status_bodies_complete_and_reopen`,
    `message_paths_and_attachment_ids`,
    `range_path_uses_documented_filter_and_keeps_overlaps`. NOT
    live-verified against a tenant.
70. [minor] `src/calling/signaling.rs` — **join a group call / meeting
    with video (meetvideo lane)**. `join_conversation_with_sdp`
    hardcoded `callInvitation.callModalities: ["Audio"]`, so a group
    call or meeting join could never ask for video. New
    `join_conversation_with_sdp_video(http, controller, params, sdp,
    video)` sends `["Audio","Video"]` when `video` is set (reuses
    `accepted_call_modalities`); the body moved into the pure
    `join_conversation_payload(params, sdp, video)` so it can be
    pinned without network. `join_conversation_with_sdp` keeps its
    signature and delegates with `false` (no behavior change). Test
    pinned in `ostmac-core` (`group_join_payload_carries_video`). NOT
    live-verified against a tenant.
71. [minor] `src/calling/signaling.rs` — **join with explicit call
    modalities (callfix lane)**. §70's join could only say `["Audio"]`
    or `["Audio","Video"]`, tied to the camera. A live group call /
    meeting join receives video with the camera off too (its offer's
    main video goes `a=recvonly`), and receiving a screen share needs
    the `ScreenViewer` modality that `create_echo_call` /
    `create_1to1_call` already declare. New pure
    `join_call_modalities(video, screen_viewer)` (`Audio` [+ `Video`]
    [+ `ScreenViewer`]), `join_conversation_payload_with_modalities(params,
    sdp, &[&str])` and async `join_conversation_with_modalities(http,
    controller, params, sdp, &[&str])`. `join_conversation_payload` and
    `join_conversation_with_sdp_video` keep their signatures and delegate
    with `accepted_call_modalities(video)` (no behavior change for
    existing callers; `call_test.rs` untouched). The screen share receive
    m-line itself (`applicationsharing-video`, own ICE / SRTP, recvonly)
    is built in `ostmac-core` (`calls.rs` `share_offer_section`, answer
    split `live.rs` `split_share_section`), as are PLI keyframe requests
    and the decoder-safe receive queue; candidates to upstream with this
    entry once live-verified. Tests pinned in `ostmac-core`
    (`group_join_payload_carries_video` ScreenViewer body,
    `share_leg_offer_answer_split_and_camera_off` modality choice). NOT
    live-verified against a tenant.
72. [feature] `src/api/apps.rs` (new), `src/api/mod.rs`,
    `src/api/client.rs` — **Teams app catalog client (apphost-b1
    lane)**. Reads the apps-platform middle tier the Teams web shell
    uses: `GET {mt}/beta/users/apps/entitlements` (installed),
    `POST {mt}/beta/users/apps/aggregatedEntitlements?appbarview=userpinned`
    (app bar order) and `POST {mt}/beta/users/apps/batchedDefinitions`
    (manifests, 50 ids per call). New `TeamsClient::middle_tier_url()`
    (`region_gtms.middleTier`, default `.../api/mt/amer`) and
    `mt_get`/`mt_post` (Bearer Teams AAD token + `X-Skypetoken`, the
    shell's `mtAuthWithSkypeXTokenResource`). Typed `AppManifest`
    (id, name, description, developer, icons, accent, `staticTabs`
    contentUrl/websiteUrl/entityId/scopes, `configurableTabs` +
    legacy `galleryTabs`, `webApplicationInfo {id, resource}`,
    `validDomains`), `AppEntitlement`, `AppCatalog`; async
    `app_catalog_data(client)` (pinned view best effort, falls back to
    entitlement pin flags). Parsers are wrapper-agnostic (collect any
    object with `appId` / an id plus a manifest marker) because the
    response wrappers are INFERRED from the shell bundles. Tests:
    `definitions_parse_manifest_fields`,
    `entitlements_and_pinned_parse_any_wrapper`, `urls_and_bodies`
    (fixture JSON). Read-only. NOT live-verified against a tenant
    (request bodies for aggregatedEntitlements/batchedDefinitions are
    INFERRED).
73. [feature] `src/auth/oauth.rs` — **token broker: any scope +
    nested app auth (apphost-b1 lane)**. The core minted fixed scopes
    only (skype, ic3, graph, recorder). New pure
    `normalize_scopes` (resource → `<resource>/.default`, scopes kept,
    dedup), `scope_grant_form`, `naa_redirect_uri`
    (`brk-multihub://<host>`), `naa_grant_form` (refresh-token grant
    on the nested client id with `brk_client_id` = Teams client,
    `brk_redirect_uri`/`redirect_uri`), `post_token_grant` (sends
    `Origin` for NAA; errors carry the AAD code + first description
    line only), and async `token_for_scope_for(profile, scopes)` /
    `naa_token_for(profile, client_id, scopes, origin)` with an
    in-memory per (profile, client, scopes) cache (refetch under 5 min
    left) and `clear_grants_for(profile)`. `TokenGrant`'s `Debug`
    never prints the token; nothing is logged. Rotated refresh tokens
    are not persisted (same as the other `acquire_*` grants). Tests
    (`broker_tests`): `scopes_normalize`, `grant_forms`,
    `naa_grant_posts_brokered_form_and_parses` and
    `grant_error_reports_code_not_secrets` (local HTTP stub),
    `grant_cache_expiry_and_clear`. NOT live-verified: the brokered
    NAA grant is INFERRED from the MSAL/Teams hub protocol (AAD may
    require a hub allow-list).
74. [feature] `src/api/apps.rs`, `src/api/mod.rs`, `src/api/tabs.rs`
    — **app store, search, personal install, tab entity ids
    (apphost-b2 lane)**. `AppManifest` gains `full_description`,
    `has_bot` (`bots`), `has_messaging_extension`
    (`composeExtensions`/`inputExtensions`), `permissions` (manifest
    `permissions` + `authorization.permissions.resourceSpecific[].name`),
    `categories` (`categories`/`category`) and developer
    `website_url`/`privacy_url`/`terms_of_use_url`. New read-only
    `app_store_data` (`GET {mt}/beta/users/apps/store`) and
    `app_search_data` (`GET {mt}/beta/users/apps/search?query=`), with
    lenient `parse_store_apps` (id + name + a listing marker) and
    `parse_store_sections` (titled shelves of app objects or ids).
    `install_app_for_user` is a REMOTE WRITE: Graph
    `POST /me/teamwork/installedApps` with
    `teamsApp@odata.bind` = `/appCatalogs/teamsApps/{id}` (documented
    Graph API; needs `TeamsAppInstallation.ReadWriteSelfForUser`, not
    known to be in the Teams-client Graph token). `TabInfo` gains
    `entity_id` from the tab configuration. Test:
    `store_parse_sections_detail_fields_and_install_body`. NOT
    live-verified: store/search response shapes and query parameter
    are INFERRED from the shell bundles; install never exercised.
75. [bug] `src/api/schedule.rs` — **draft slot 403 is an empty slot,
    not a failed week (shiftlive lane)**. Live 2026-09-28 (member
    account, the only team with Shifts): the `sharedShift` /
    `sharedTimeOff` range queries answer 200, but `draftShift` /
    `draftTimeOff` answer 403 Forbidden "Sorry, you don't have the
    permission to filter on draft information." (only schedule
    managers may filter drafts). `list_shifts_range_data` /
    `list_timesoffs_range_data` propagated it, so the whole week
    failed and the Shifts pane showed "Couldn't Load Shifts". New
    `draft_slot_forbidden(slot, err)`: a draft-slot `HTTP 403` yields
    no rows; shared-slot failures and every other status still fail.
    Test: `draft_slot_403_is_empty_not_fatal`. Live-verified
    read-only after the fix: 85 shifts / 4 time off / 13 reasons.
76. [fix] `src/api/apps.rs`, `src/auth/oauth.rs` — **live app catalog
    shape + working nested app auth (applive lane)**. Verified live
    2026-09-28 (read-only). Catalog: `aggregatedEntitlements` answers
    `{type, value: {userEntitlements: {<id>: [{id, state,
    isAppBarPinned, appBarOrder, …}]}, definitions: {<appId>:
    manifest}, userEntitlementsHash}}`; items are keyed `id`, not
    `appId`, so the §72 parsers found 0 entitlements, 0 pinned and never
    asked for definitions. `parse_entitlements` now reads the
    `userEntitlements` container (else any `appId` object);
    `parse_pinned` keeps only pinned items (isAppBarPinned /
    isUserPinned / isAdminPinned) sorted by `appBarOrder`;
    `app_catalog_data` takes entitlements, pin order and manifests from
    that one query and asks batchedDefinitions only for ids it left out.
    `GET beta/users/apps/entitlements` is not the installed list (a few
    copilot/extension definitions) and is no longer called.
    `batchedDefinitions` wants a bare JSON array of ids (`{"appIds":…}`
    returns `[]`). Live: 84 entitlements, 11 pinned, 84 manifests
    (28 with static tabs) in ~1 s; batchedDefinitions resolved 12/12
    channel-tab apps. NAA (§73): the brokered grant failed AADSTS9002326
    (any `Origin` header: a native client's refresh token cannot be
    redeemed cross-origin) and AADSTS50011 (`brk_redirect_uri` must be
    the hub's own redirect). Now `brk_redirect_uri` =
    `HUB_REDIRECT_URI` (`…/oauth2/nativeclient`), `redirect_uri` =
    `brk-multihub://<app host>`, no `Origin`; live grant for Planner's
    client returns a token whose `appid` is Planner's own client. Store
    `GET beta/users/apps/store` and `search` answer 405 (method/shape
    still unknown; not changed). Tests:
    `aggregated_view_yields_entitlements_pinned_order_and_manifests`,
    `urls_and_bodies`, `grant_forms`,
    `naa_grant_posts_brokered_form_and_parses` (updated).

77. [feature] `src/api/client.rs`, `src/api/files.rs` — **request
    deadlines + request observer (noload lane)**. The shared reqwest
    client had no timeout, so one stalled request hung a section load
    indefinitely. `shared_http()` now sets `connect_timeout` 10s;
    every `TeamsClient` API call carries a whole-request deadline
    (`DEFAULT_REQUEST_TIMEOUT` 30s; reqwest 0.11 has no idle read
    timeout), overridable per client via `with_timeout(None|Some)`.
    Uploads (`graph_put_bytes`, `drive_session_put`) are connect-only;
    inline media gets `MEDIA_TIMEOUT` 60s; content downloads move to
    the new `graph_get_download` (connect-only). New
    `set_request_observer(fn(method, url, status, ms))`: called once
    per request after the response head (status 0 = transport failure
    / timeout) so a host can log latency without touching call sites.

78. [fix] `src/auth/oauth.rs`, `src/api/tabs.rs`, `src/api/apps.rs`,
    `src/api/mod.rs` — **NAA id token, tab app ids, team apps, site
    values (apphost-b3 lane)**. Verified live 2026-09-28 (read-only).
    NAA (§73/§76): the brokered grant asked for `<scopes>
    offline_access` only, so AAD returned no id token and the host
    replied `id_token: ""`; MSAL.js rejects that (nullOrEmptyToken),
    and Planner retried GetToken (26 in 32 s) and showed "couldn't load
    your settings". New `naa_scope` adds `openid profile
    offline_access` (deduplicated); `TokenGrant` gains `id_token`
    (Debug prints its length only); `post_token_grant` parses it. Live
    after: Planner 9 GetToken, 39 GETs, tasks and plans render. Tabs:
    Graph v1.0 `teamsTab` has no `teamsAppId`, so every live tab had
    no app id; both tab reads now use `?$expand=teamsApp` and take
    `teamsApp.id`. New read-only `installed_apps_path` /
    `parse_installed_app_ids` / `team_app_definitions_data` (Graph
    `GET /teams/{id}/installedApps?$expand=teamsAppDefinition`, then
    batchedDefinitions for those ids plus caller ids) and
    `sharepoint_sites_data` (`GET /sites/root`, `/me/drive`,
    `/groups/{id}/sites/root`, `$select=webUrl`, each best effort) for
    the `{teamSiteDomain}`/`{teamSitePath}`/`{mySiteDomain}` tab
    placeholders. Tests: `installed_apps_parse_ids_and_path`,
    `app_id_from_expanded_teams_app`, `grant_forms` (naa_scope; Debug
    hides id_token).
79. [feature] `src/api/chat.rs`, `src/api/mod.rs` — **chat mute, hide
    and folders (chatmenu lane)**. Mute: chat service `PUT
    {svc}/v1/users/ME/conversations/{id}/properties?name=alerts` body
    `{"alerts":"false"|"true"}` ("false" = muted; the property is read
    back in the conversation list) via `alerts_url` / `alerts_body` /
    `set_chat_muted_with_client`. Hide: Graph `POST
    /chats/{id}/hideForUser` / `unhideForUser` with a
    `teamworkUserIdentity` body (`hide_chat_path` / `hide_chat_body` /
    `set_chat_hidden_with_client`). Folders, read-only: `GET
    teams.microsoft.com/api/csa/api/v1/teams/users/me/conversationFolders`
    (`supportsAdditionalSystemGeneratedFolders`, `supportsSliceItems`)
    with a `chatsvcagg.teams.microsoft.com/.default` bearer;
    `parse_conversation_folders` names system folders by type
    (Favorites). Folder GET verified live 2026-09-28 (read-only); the
    mute PUT and hide POST are not exercised live (no live writes).
    Tests: `chatmenu_tests` (request shapes, alerts parse, folder
    parse).

80. [feature] `src/api/chat.rs`, `src/api/mod.rs`, `src/api/client.rs`
    — **chat folder move** (chatlist2 lane). New pure
    `folder_move_actions` (from a raw `conversationFolders` payload:
    `RemoveItem` from every non-system folder holding the chat except
    the target, `AddItem` to the target; blank target = out of every
    folder; system views and unknown ids refused) and
    `folder_move_body` (`{folderHierarchyVersion, actions:[{action,
    folderId, itemId}]}`), plus `conversation_folder_move_with_client`:
    fresh folder GET for version + membership, one `POST` to the same
    `conversationFolders` URL with the chatsvcagg bearer and
    `Authentication: skypetoken=…`, then the returned (or re-read)
    folders must show the chat in the target. `TeamsClient::skype_token`
    is now `pub(crate)` for that header. Verified live 2026-09-28 with
    one round trip on the self chat only (into Favorites, verified,
    back out, verified; folder counts restored). Test:
    `chatmenu_tests::folder_move_request_shape`.

81. [fix] `src/api/files.rs`, `src/api/chat.rs`, `src/api/tabs.rs`,
    `src/api/mod.rs` — **chat Files tab + chat tabs** (chattabs lane).
    The Teams web Graph token has no `Chat.Read`, so
    `/me/chats/{id}/messages` is 403 and `list_chat_files_data_opts`
    fell through to the channel-folder scan, whose "No joined team
    contains channel" error was shown for every chat. New
    `is_chat_id` (`48:`, or `19:` ending `@thread.v2`,
    `@unq.gbl.spaces`, `@thread.skype`): chat ids read shared files
    from the chat service first (`chat_file_refs_data`: message
    `properties.files` over up to `CHAT_FILE_PAGES` backward pages of
    `CHAT_FILES_PAGE_SIZE`, deleted messages/files skipped, deduped by
    object URL), resolve each through `/shares/{u!…}/driveItem` (share
    URL, then object URL; unresolved refs kept as `shared_from_ref`),
    fall back to the Graph message route, and never take the channel
    scan. Message reads are GETs; the consumption horizon is untouched.
    Tabs: `TabInfo` gains `app_name` (teamsApp displayName) and
    `teams_url` (tab webUrl); new `chat_tabs_path`, `parse_tabs`,
    `list_chat_tabs_data` (`GET /chats/{id}/tabs?$expand=teamsApp`,
    `19:` ids only; live 200). Tests:
    `files::…::chat_scope_never_takes_the_channel_scan`,
    `chat_files_tests::file_refs_from_chat_service_page`,
    `tabs::…::chat_tabs_parse_name_and_teams_link`.

82. [feature] `src/api/teams.rs`, `src/api/mod.rs` — **channel edit and
    delete** (teamsync lane). Pure `channel_path` and
    `update_channel_body` (`displayName` only when non-blank,
    `description` trimmed, `""` clears it), plus
    `update_channel_data` (one Graph `PATCH
    /teams/{t}/channels/{c}`, refuses an empty body) and
    `delete_channel_data` (one Graph `DELETE` on the same path). Both
    check ids with `check_id` before any request. Never exercised
    against the live tenant; unit tests use shapes only. Test:
    `tests::channel_edit_delete_path_and_body`.
    Same lane: `tests/e2e_read.sh`, `tests/e2e_trouter.sh` and
    `tests/e2e_echo123.sh` (the only scripts that write: self-chat
    sends and a self-call) now exit 0 with a SKIP unless
    `OST_E2E_LIVE_WRITES=1` is set.

83. [fix] `src/api/files.rs`, `src/api/chat.rs` — **message file chips
    via the chat service + bot 1:1 fixtures** (chatrows lane).
    `list_message_files_data` (timeline file chips past the Shared
    list's first page) read Graph `/me/chats/{c}/messages/{m}`: 403
    without `Chat.Read`. Chat ids now read the chat service: new
    `chat_message_file_refs_data` GETs the single message
    (`message_url`), else walks at most `CHAT_FILE_PAGES` backward
    history pages until the page reaching the message (ids are arrival
    ms, `page_reaches`); `message_file_refs` pulls that message's
    `properties.files`. Refs resolve through the §81 shares path, now
    shared as `resolve_file_refs`. `is_chat_id` also takes bare bot
    MRI chats (`28:`). GETs only; consumption horizon untouched.
    Tests: `chat_files_tests::message_file_refs_single_and_page`,
    `tests::bot_one_to_one_chats_list_like_teams` (live-shaped
    `19:{oid}_{botApp}@unq.gbl.spaces` and legacy `28:` rows list as
    1:1s named after the bot), `chat_scope_never_takes_the_channel_scan`.

84. [feature] `src/api/chat.rs`, `src/api/files.rs`, `src/api/mod.rs` —
    **server-side pinned chat messages + chat-service file send**
    (chatrows lane). Nothing read Teams' own pins: new
    `chat_pinned_messages_data` GETs the chat-service thread
    (`thread_pins_url`: `/v1/threads/{id}?view=msnp24Equivalent`) and
    parses it tolerantly (`parse_thread_pins`: every `properties` key
    containing "pinned", value a JSON string, array, or comma-separated
    ids; objects take `messageId|id` + optional pinnedBy/pinnedTime/
    sender/content — the shape is undocumented), falling back to Graph
    `GET /chats/{id}/pinnedMessages?$expand=message`
    (`parse_graph_pins`; needs Chat.Read, 403 on the Teams web token).
    `pick_pins` fixes precedence (non-empty thread → Graph → empty
    thread → chat-service error). Thread pins missing sender/preview
    are filled from their chat-service message (`message_url`,
    `fill_pin_from_message`). `chat_unpin_message_with_client` = Graph
    `DELETE /chats/{id}/pinnedMessages/{pinId}`. GETs only on read;
    consumption horizon untouched. `upload_to_chat` now posts the file
    message through the chat service first (`chat_service_file_body`:
    `properties.files` JSON string of one `http://schema.skype.com/File`
    entry, the shape `parse_chat_file_refs` reads back) and falls back
    to the Graph reference post. Tests: `pinned_tests::*` (thread
    properties as JSON string and array, CSV, Graph payload, Graph 403
    precedence), `chat_file_send_tests::chat_service_file_body_round_trips_through_the_reader`.

85. [fix] `src/api/chat.rs`, `src/api/files.rs`, `src/api/mod.rs`,
    `src/trouter/mod.rs`, `src/trouter/registrar.rs` — **reliable sends
    and live chat pushes** (sendfix lane; code comments tag it §106).
    (a) Idempotent posts: `send_message_with_client_id`,
    `reply_message_with_client_id`, `thread_reply_with_client_id` carry a
    caller-owned `clientmessageid` (`new_client_message_id`, 19 digits)
    and return `SentMessage` (server id from `Location` or
    `OriginalArrivalTime`, `sent_id_from_response`);
    `find_message_by_client_id` verifies a timed-out post by reading
    the newest page (`MessageInfo.client_message_id` now parsed).
    Chat file sends: `upload_file_data_idem` threads one client id
    through `upload_to_chat`; a retry (`verify_first`) skips the post
    when the id already landed; a failed chat-service post is verified
    before the Graph fallback. (b) Trouter: `3:::` data frames (the
    HTTP-over-WS pushes) were printed and dropped — `data_frame_event`
    now decodes them (body top-level or under `data`, object or string,
    gzip+base64 by header or fallback, `cp`/`gp` wrappers) and publishes
    chat-service events to `event_hub`. Registration: the CDL entry used
    the consumer template `TeamsCDLWebWorker_2.6` with transport context
    `TFL` and a random registration id; no messaging push ever reached
    the socket (live: 90 s sniff + own post into a 1:1, zero `3:::`
    frames). Now business template `TeamsCDLWebWorker_2.1`, empty
    context, `registrationId` = the socket epid
    (`register_with_endpoint`), `user.activity` active after the
    handshake, and a CDL re-registration with `TeamsCDLWebWorker_1.9` on
    the first `trouter.message_loss` (`register_cdl`), matching the
    purple-teams business client. Live after the change: an own post
    arrived as a `3:::` `/messaging` frame 1.16 s after the POST.
    (c) 1:1 open: `POST /me/chats` is not a Graph create endpoint (405)
    and Graph `POST /chats` needs Chat.Create (403 on the Teams web
    token), so every live 1:1 open/quick message failed.
    `create_one_to_one_chat_data` now resolves both AAD ids, derives
    `19:<lo>_<hi>@unq.gbl.spaces` (`one_to_one_thread_id`; 38/38 live
    1:1 ids have this shape), probes `/v1/threads/{id}` and, only on
    404, creates the unique-roster 1:1 on the chat service
    (`one_to_one_thread_body`: `uniquerosterthread` + `fixedRoster`; the
    answered id must equal the derived one). Tests:
    `sendfix_tests::*` (chat.rs: client id shape, receipt id parse,
    page lookup, 1:1 id ordering; trouter: plain/gzip/`data`/object/
    `cp`/`gp` bodies, non-chat frames skipped).

86. [fix] `src/api/client.rs`, `src/api/chat.rs`, `src/api/files.rs`,
    `src/api/mod.rs` — **Graph calls the Teams web token cannot use**
    (graphsweep lane; code comments tag it §GRAPHSWEEP). The app signs
    in with the Teams web client; its Graph token's decoded `scp` (35
    names, 09-28) has no Presence.*, Chat.Read/ReadBasic/ReadWrite/
    Create, ChatMember.*, OnlineMeetings.*, Team.Create,
    ChannelSettings.*, Channel.Delete.All,
    TeamsAppInstallation.*ForUser or TeamworkTag.*. Live: `/chats/{id}/
    members`, `/chats/{id}/pinnedMessages`, `/me/chats/{id}/messages`,
    `/users/{id}/presence`, `/me/presence`, `/me/onlineMeetings` all 403.
    (a) `create_group_chat_data` creates the group thread on the chat
    service (`POST /v1/threads`, `thread_create_url`,
    `group_chat_create_body`: `8:orgid:` members, all `Admin`,
    `threadType: chat`, optional topic; id from `Location`,
    `created_thread_id`) instead of Graph `POST /chats`; UPNs resolve via
    Graph `/users/{ref}?$select=id` (granted). (b)
    `list_chat_members_data` reads only the chat-service roster (no
    Graph attempt) and fills blank names from Graph `/users/{oid}`
    (`fill_member_names`, User.ReadBasic.All; live roster 2/2 blank).
    (c) `chat_pinned_messages_data` drops the Graph `pinnedMessages`
    fallback; `chat_unpin_message_with_client` fails without network.
    (d) `list_chat_files_data_opts` drops the Graph
    `/me/chats/{id}/messages` route (chats: chat service; others:
    channel files folder). (e) `graph_denied` refuses, before any
    network and with a plain reason, the routes whose permission is not
    granted and that have no wired Teams-service equivalent: create
    team, edit/delete channel, add an app for yourself, hide a chat,
    find a meeting by ID. (f) `list_message_files_data` reads every
    non-channel id on the chat service (`message_files_via_chat_service`);
    Graph `/me/chats/{c}/messages/{m}` (Chat.Read) is never called.
    Tests: `client::tests::graph_denied_table`,
    `denied_route_fails_before_network`,
    `files::tests::message_files_route_off_graph_chats`,
    `roster_name_tests::roster_blank_names_fill_from_users`, ostmac-core
    `core_a_group_chat_body_and_member_normalization`.
87. [fix] `src/api/client.rs`, `src/api/teams.rs`, `src/api/apps.rs`,
    `src/api/chat.rs`, `src/api/mod.rs` — **Teams-service routes for the
    writes §86 refused** (graphsweep lane; comments tag §GRAPHSWEEP3).
    Request shapes come from the Teams web client's own code (public CDN
    chunks `services-teams-and-channels`, `services-apps-platform`, chat
    service transport, and the CDL shared-worker resolvers, 09-29); none
    was sent live (writes limited to one test message). (a)
    `TeamsClient::mt_send_json` — any-method JSON call on the middle tier
    with the existing MT auth (AAD bearer + X-Skypetoken), optional
    `x-ms-client-caller`. (b) `create_team_data` → `POST
    {mt}/beta/teams/create`, body `displayName`, `description` ("" when
    blank), `accessType` 1 (Private; web enum None 0/Private 1/Secret
    2/Public 3), `isTenantWide`/`validationRequired` false; group id from
    `value.siteInfo.groupId` (`created_team_ids`); read back via Graph
    `fetch_team_with_channels`, degrading to id + name. The Graph
    template body, owner bind and operation poll are no longer used by
    the create path. (c) `update_channel_data` → `PATCH
    {mt}/beta/teams/{teamThreadId}/channels/{channelId}` with
    `displayName`/`description`; `delete_channel_data` → `DELETE` same
    URL with the channel descriptor subset `delete_channel_body` (INFERRED
    minimal body); General channel (id = team thread id) refused
    pre-network. Team thread id from Graph `GET
    /teams/{id}?$select=internalId` (`team_thread_id`, Team.ReadBasic.All).
    (d) `install_app_for_user` → middle-tier batchedDefinitions read, then
    `POST {mt}/beta/users/apps/entitlements` with the definition as body
    and caller `apps-platform-service-meta-os-installApp` (web
    `createAppEntitlement`, Personal scope). (e) `set_chat_hidden_with_client`
    → chat service `PUT /v1/users/ME/conversations/{id}/properties?name=`
    `unpinnedTime` (hide: now ms; unhide: null) then, on hide,
    `historyHiddenTime` (same stamp as string), as the web
    `setChatVisibility` resolver does; signature drops user/tenant ids.
    `graph_denied` keeps every Graph route shut. Not switched: find
    meeting by ID (web client has no code→thread REST lookup; the only
    middle-tier call, `GET beta/meetings/identifiers`, returns a tenant
    id; §GRAPH2 superseded the old "keep opening the `/meet/{id}?p=`
    link" fallback: the app now shows an error and never opens it). Tests: `teams::tests::team_create_goes_to_middle_tier_with_web_client_body`,
    `channel_edit_delete_middle_tier_shapes`, `apps::tests::store_parse_sections_detail_fields_and_install_body`,
    `chat::chatmenu_tests::hide_request_shape`.
89. [feat] `src/api/tags.rs` (new), `src/api/client.rs`, `src/api/mod.rs`,
    `src/api/fake_transport.rs` + `src/api/write_fakes.rs` (test-only) —
    **Teams tags read from the CSA service; fake-transport tests for the
    §87 writes** (graph2 lane, comments tag §GRAPH2). (a) `tags::
    my_tag_cards_data` → `GET {csa}/teams/users/me/teams/tagCards?tagType=
    Team&pageSize=500` with the skype-token bearer `csa_get` already uses
    (URL, query keys and page size from the web client's shared worker
    `getTeamsTagCards`). INFERRED, not live: the `Team` tag type value,
    the response shape and whether the list is only the user's own tags.
    `parse_tag_cards` is strict: an unreadable answer or a non-empty list
    with no nameable card is an error, never "no tags"; a card's
    `isMember`/`isCurrentUserMember`/`isUserMember` false drops it. Graph
    `/teams/{id}/tags` stays refused (TeamworkTag.Read). ostmac-core
    exposes it as `ostmac_catchup_tags`. (b) `TeamsClient::csa_base`,
    `graph_base` (and test-only `for_test`) let unit tests point every
    service root at a loopback fake; production values are unchanged
    consts (the `graphBase`/`csaBase` overrides compile only under
    `cfg(test)`). (c) `write_fakes` runs create team, edit channel, delete
    channel (body INFERRED), add app for yourself and hide/unhide chat
    end to end against `fake_transport::Fake`, asserting method, path,
    auth headers (AAD+X-Skypetoken on the middle tier, skype token only on
    the chat service, Graph token only on Graph reads, no token crossing
    services) and JSON body. Tests: `write_fakes::*` (11), `tags::tests::*`
    (5), ostmac-core `catchup_tags::tests::names_are_lowercased_sorted_and_deduped`.
    Also: §87's old "keep opening the `/meet/{id}?p=` link" fallback is
    superseded — the app no longer opens it (see Swift
    `MeetingsViewModel.joinByMeetingID`).


88. [feature] `src/api/team_settings.rs` (new), `src/api/mod.rs` —
    **team member permissions + General channel id** (chanmenu lane).
    `team_settings_data` runs two independent read-only Graph GETs:
    `GET /teams/{id}` (`memberSettings.allowDeleteChannels` /
    `allowCreateUpdateChannels`) and `GET /teams/{id}/primaryChannel`
    (the General channel id). One failing leaves its fields `None`
    (unknown); only both failing is an error. Pure helpers
    `team_path`, `primary_channel_path`, `parse_member_settings`,
    `parse_primary_channel_id`; ids checked before any request. Not
    exercised live (stored Graph token stale at the time); allowlist
    row is `unproven`. Tests: `team_settings::tests::*` (5). Host side
    (ostmac-core, not vendored): `team_settings_json` /
    `ostmac_team_settings`, and realtime now treats a
    `ThreadActivity/*` system message as a tree-refresh signal
    (`realtime::tests::thread_activity_system_message_is_a_tree_signal`).

90. [fix/feature] `src/api/files.rs`, `src/api/chat.rs`,
    `src/api/client.rs`, `src/api/media.rs`, `src/api/fake_transport.rs`
    (test-only), `src/api/write_fakes.rs` (test-only),
    `docs/specs/tui.txt` — **FIXPACK lane**.
    (a) files.rs: chat AND channel file posts share
    `post_file_message_idem`: the chat-service post carries the caller's
    `clientmessageid`; a Retry looks the id up first (`verify_first`); a
    failed post is looked up by id (three tries when the failure is
    ambiguous) before anything else. The Graph reference post runs only
    when the server answered HTTP 4xx AND the id is proven absent;
    timeout / 5xx / a failed lookup is an error ("Retry checks first"),
    never a second post. Pure `file_post_next` / `is_definite_rejection`.
    (b) chat.rs: untitled 1:1 mate names for chat-list paging resolve six
    at a time (`resolve_mates_cached`, `buffer_unordered`), cache hits
    need no whoami or network, and names persist per profile in
    `mates-<config stem>.json` beside the config (14 day TTL, best-effort
    write). Before: one whoami plus a sequential roster + history read
    per untitled 1:1 on every page (4-5 s a page live).
    (c) client.rs/media.rs: `media_get_head` / `fetch_media_head_data`
    read the first N bytes of a media URL with HTTP `Range`, same auth as
    `media_get`, whole-request deadline; the body is read only up to N.
    The result is a PREFIX (host side must never cache it as the file).
    (d) test-only: `Fake` answers a `@location:<url>\n` body prefix as a
    Location header; new fake-transport tests for group chat create
    round trip, unpin bailing before any request, pins never touching
    Graph, the F1 post/verify matrix, mate batching/persistence, and the
    range probe. (e) `docs/specs/tui.txt`: one demo name replaced with a
    Western name (also needs a public-snapshot republish + upstream PR).
    Host side (ostmac-core, not vendored): `media_head_json` /
    `ostmac_media_head` (never cached), five rustc warnings removed.
    Tests: `file_post_idem_tests` (3), `file_post_idem_fake_tests` (6),
    `write_fakes` (+4), `mate_batch_tests` (3), `head_tests` (2).

## Upstream PRs, wave 9 (2026-09-25 R10 audit; base 0892144; origin/main still 0892144)

No-file wave. `git diff 307d221..db62ed7 -- rust/ost` is empty (wave-8
ledger commit → main tip); no unmerged `lanes/*` branch carries an
ost diff vs main. Ledger §§1–52 map 1:1 onto open PRs #5–#50
(#38 CLOSED same-team duplicate of #39, wave-6 note; all others
OPEN, verified via `gh pr list` this wave).

Filed: none. Held: none.

Standing out-of-scope (no action):
- §13 [LOCAL-ONLY, do not upstream] (TUI drop).
- `SharedFile.attachment_id` (unledgered om-inline-docs eTag mining;
  wave-6 note; stays out of PRs until ledgered).

Gate (FIXPACK pass, 2026-09-29): `cargo test --release --lib` in vendored
`rust/ost` green (lib 373/0; bin, imgfix probe and doc runs not repeated
this pass), `rust/ostmac-core` lib 224/0. Older counts (lib 257, core
222-230) predate the §85-§89 test additions.
