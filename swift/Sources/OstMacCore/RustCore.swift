// RustCore.swift — thin Swift wrapper over the ostmac-core C ABI.
import COstMac
import Foundation

public enum RustCore {
    /// Swift-native (R12 ffi-move-now B0; was `ostmac_version`).
    public static func version() -> String {
        CoreLocal.version()
    }

    /// Swift-native (R12 ffi-move-now B0; was `ostmac_init`).
    public static func initialize() -> Int32 { CoreLocal.initialize() }

    /// Swift-native (R12 ffi-move-now B0; was `ostmac_status`).
    public static func status() throws -> StatusResponse {
        try CoreLocal.status()
    }

    // MARK: - Account profiles (d1-accounts)

    /// Auth status for one account profile (no active switch).
    /// Swift-native (R12 ffi-move-now B0; was `ostmac_status_for`).
    public static func status(profile: String) throws -> StatusResponse {
        try CoreLocal.status(profile: profile)
    }

    /// Switch the core's active account profile. Every profile-agnostic
    /// path (clients, trouter, legacy entry points) follows it.
    public static func profileSet(_ profile: String) throws -> ProfileResponse {
        try profile.withCString { ptr in
            try call(ostmac_profile_set(ptr), as: ProfileResponse.self)
        }
    }

    /// Current active profile id (pure core read, no network).
    /// Swift-native (R12 ffi-move-now B0; was `ostmac_profile_active`).
    public static func profileActive() throws -> ProfileResponse {
        try CoreLocal.profileActive()
    }

    /// Device-code start for one account profile (polled tokens land there).
    /// Swift-native (R14 om-later-b18 B18; was `ostmac_device_start_for`).
    public static func deviceStart(profile: String) throws -> DeviceStart {
        try SyncBridge.run {
            try await DeviceAuth.deviceStart(
                profile: profile, store: DeviceAuth.productionStore(),
                fetcher: URLSessionTokenFetcher()
            )
        }
    }

    /// Browser-capture start for one account profile.
    public static func browserStart(profile: String) throws -> AuthCodeStart {
        try profile.withCString { ptr in
            try call(ostmac_authcode_start_for(ptr), as: AuthCodeStart.self)
        }
    }

    /// Current user for one account profile (no active switch).
    /// Swift-native (R14 om-later-b4 B4; was `ostmac_whoami_for`).
    public static func whoami(profile: String) throws -> WhoamiResponse {
        try CoreReads.whoami(profile: profile)
    }

    /// Refresh one account profile's tokens (no active switch).
    public static func refresh(profile: String) throws -> RefreshResponse {
        try profile.withCString { ptr in
            try call(ostmac_refresh_for(ptr), as: RefreshResponse.self)
        }
    }

    /// Sign one account profile out (clears its tokens, deletes a
    /// non-default profile file; other profiles untouched).
    public static func signOut(profile: String) throws -> SignOutResponse {
        // Swift whoami slot follows the Rust clear (success or fail: the
        // FFI always ran the core clear first).
        defer {
            CoreReads.whoamiCacheClear(profile: profile)
            // B18: pending device sessions lived in Rust (`retain` in
            // `sign_out_json_for`); they live in Swift now. B19 must
            // preserve this line when sign-out itself moves.
            DeviceAuth.Sessions.drop(profile: profile)
        }
        return try profile.withCString { ptr in
            try call(ostmac_sign_out_for(ptr), as: SignOutResponse.self)
        }
    }

    /// Swift-native (R14 om-later-b18 B18; was `ostmac_device_start`).
    public static func deviceStart() throws -> DeviceStart {
        try deviceStart(profile: CoreLocal.activeProfileID())
    }

    /// Swift-native (R14 om-later-b18 B18; was `ostmac_device_poll`).
    public static func devicePoll(session: String) throws -> DevicePoll {
        // Tokens may land (profile untracked here): drop all Swift slots.
        defer { CoreReads.whoamiCacheClearAll() }
        return try SyncBridge.run {
            try await DeviceAuth.devicePoll(
                session: session, store: DeviceAuth.productionStore(),
                fetcher: URLSessionTokenFetcher()
            )
        }
    }

    public static func refresh() throws -> RefreshResponse {
        try call(ostmac_refresh(), as: RefreshResponse.self)
    }

    public static func signOut() throws -> SignOutResponse {
        defer {
            CoreReads.whoamiCacheClear(profile: CoreLocal.activeProfileID())
            DeviceAuth.Sessions.drop(profile: CoreLocal.activeProfileID())
        }
        return try call(ostmac_sign_out(), as: SignOutResponse.self)
    }

    /// Browser-capture start (auth-code + PKCE, no network): returns the
    /// session + authorize URL to load in the webview.
    public static func browserStart() throws -> AuthCodeStart {
        try call(ostmac_authcode_start(), as: AuthCodeStart.self)
    }

    /// Browser-capture complete: exchanges the intercepted callback URL
    /// for tokens (state verified in core). Blocking FFI (network): call
    /// off the main thread.
    public static func browserComplete(session: String, callback: String) throws -> AuthCodeComplete {
        // Tokens land (profile untracked here): drop all Swift slots.
        defer { CoreReads.whoamiCacheClearAll() }
        return try session.withCString { sPtr in
            try callback.withCString { cPtr in
                try call(ostmac_authcode_complete(sPtr, cPtr), as: AuthCodeComplete.self)
            }
        }
    }

    /// Drop one pending browser session (cancel path; never throws fatally).
    public static func browserCancel(session: String) throws -> AuthCodeCancel {
        try session.withCString { ptr in
            try call(ostmac_authcode_cancel(ptr), as: AuthCodeCancel.self)
        }
    }

    /// Swift-native (R14 om-later-b4 B4; was `ostmac_whoami`).
    public static func whoami() throws -> WhoamiResponse {
        try CoreReads.whoami()
    }

    /// Swift-native (R14 om-later-b4 B4; was `ostmac_chats`).
    /// `profile` nil = active profile; gap-g1 passes inactive ids.
    public static func chats(limit: Int32 = 20, profile: String? = nil) throws -> ChatsResponse {
        try CoreReads.chats(limit: limit, profile: profile)
    }

    /// Swift-native (R14 om-later-b4 B4; was `ostmac_teams`).
    public static func teams() throws -> TeamsResponse {
        try CoreReads.teams()
    }

    /// Create one standard channel in a team (nil/blank description is
    /// dropped by core). Blocking FFI (network): call off the main thread.
    public static func channelCreate(
        teamID: String, name: String, description: String? = nil
    ) throws -> ChannelCreateResponse {
        try teamID.withCString { idPtr in
            try name.withCString { namePtr in
                try withOptionalCString(description) { descPtr in
                    try call(
                        ostmac_channel_create(idPtr, namePtr, descPtr),
                        as: ChannelCreateResponse.self)
                }
            }
        }
    }

    /// Create (or re-open) a 1:1 chat with one user ref, AAD id or
    /// UPN (om-lt5-person11: person-pick opens 1:1). Blocking FFI
    /// (network): call off the main thread.
    public static func chatCreateOneToOne(user: String) throws -> ChatCreateResponse {
        try user.withCString { ptr in
            try call(ostmac_chat_create_one_to_one(ptr), as: ChatCreateResponse.self)
        }
    }

    public static func teamMembers(teamID: String) throws -> TeamMembersResponse {
        try teamID.withCString { ptr in
            try call(ostmac_team_members(ptr), as: TeamMembersResponse.self)
        }
    }

    public static func teamMemberAdd(teamID: String, user: String, owner: Bool = false) throws -> TeamMemberAddResponse {
        try teamID.withCString { teamPtr in
            try user.withCString { userPtr in
                try call(ostmac_team_member_add(teamPtr, userPtr, owner ? 1 : 0), as: TeamMemberAddResponse.self)
            }
        }
    }

    /// Join one team by id (self-enroll, blocking FFI: call off main thread).
    public static func teamJoin(teamID: String) throws -> TeamJoinResponse {
        try teamID.withCString { ptr in
            try call(ostmac_team_join(ptr), as: TeamJoinResponse.self)
        }
    }

    /// Search public (joinable) teams by name (blocking FFI + network:
    /// call off the main thread). Joined teams are included.
    public static func teamSearch(query: String, limit: Int32 = 25) throws -> PublicTeamsResponse {
        try query.withCString { ptr in
            try call(ostmac_team_search(ptr, limit), as: PublicTeamsResponse.self)
        }
    }

    /// Create one standard team (async Graph POST + poll, blocking FFI:
    /// call off the main thread; waits up to ~120s for the operation).
    /// Nil/blank description is dropped by core.
    public static func teamCreate(
        name: String, description: String? = nil
    ) throws -> TeamCreateResponse {
        try name.withCString { namePtr in
            try withOptionalCString(description) { descPtr in
                try call(
                    ostmac_team_create(namePtr, descPtr),
                    as: TeamCreateResponse.self)
            }
        }
    }

    /// One channel's pinned tabs, read-only (blocking FFI + network:
    /// call off the main thread).
    public static func tabs(channelID: String) throws -> TabsResponse {
        try channelID.withCString { ptr in
            try call(ostmac_tabs(ptr), as: TabsResponse.self)
        }
    }

    public static func teamMemberRemove(teamID: String, memberID: String) throws -> TeamMemberRemoveResponse {
        try teamID.withCString { teamPtr in
            try memberID.withCString { memberPtr in
                try call(ostmac_team_member_remove(teamPtr, memberPtr), as: TeamMemberRemoveResponse.self)
            }
        }
    }

    public static func messages(chatID: String, limit: Int32 = 50) throws -> MessagesResponse {
        try chatID.withCString { ptr in
            try call(ostmac_messages(ptr, limit), as: MessagesResponse.self)
        }
    }

    public static func messagesPage(chatID: String, pageToken: String, limit: Int32 = 50) throws -> MessagesResponse {
        try chatID.withCString { idPtr in
            try pageToken.withCString { tokPtr in
                try call(ostmac_messages_page(idPtr, tokPtr, limit), as: MessagesResponse.self)
            }
        }
    }

    /// Teams message search, one from/size window (blocking FFI + network:
    /// call off the main thread). `next_from` (nil when exhausted)
    /// chains the next window via `from`.
    public static func search(query: String, from: Int32 = 0, size: Int32 = 25) throws -> SearchResponse {
        try query.withCString { ptr in
            try call(ostmac_search(ptr, from, size), as: SearchResponse.self)
        }
    }

    public static func send(chatID: String, text: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try text.withCString { textPtr in
                try call(ostmac_send(idPtr, textPtr), as: SendResponse.self)
            }
        }
    }

    /// Add one emoji reaction to a message (om-reactions).
    /// Blocking FFI (network): call off the main thread.
    public static func react(chatID: String, messageID: String, emoji: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try emoji.withCString { ePtr in
                    try call(ostmac_react(idPtr, midPtr, ePtr), as: SendResponse.self)
                }
            }
        }
    }

    /// Edit one own message via core (blocking FFI: call off main thread).
    public static func edit(chatID: String, messageID: String, text: String) throws -> EditResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try text.withCString { textPtr in
                    try call(ostmac_edit(idPtr, midPtr, textPtr), as: EditResponse.self)
                }
            }
        }
    }

    /// Remove one emoji reaction from a message (om-reactions).
    /// Blocking FFI (network): call off the main thread.
    public static func removeReaction(chatID: String, messageID: String, emoji: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try emoji.withCString { ePtr in
                    try call(ostmac_react_remove(idPtr, midPtr, ePtr), as: SendResponse.self)
                }
            }
        }
    }

    /// Post one quote reply to a chat message. `parentSender`/`parentText`
    /// attribute the quote block (core truncates the snippet + falls back
    /// on blanks). Blocking FFI (network): call off the main thread.
    public static func reply(
        chatID: String, parentID: String,
        parentSender: String, parentText: String, text: String
    ) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try parentID.withCString { parentPtr in
                try parentSender.withCString { senderPtr in
                    try parentText.withCString { snippetPtr in
                        try text.withCString { textPtr in
                            try call(
                                ostmac_reply(idPtr, parentPtr, senderPtr, snippetPtr, textPtr),
                                as: SendResponse.self)
                        }
                    }
                }
            }
        }
    }

    /// Post one reply into a channel thread (core-a): lands in the reply
    /// chain under `rootID`, not as a new top-level post. Channel ids
    /// only (core rejects chats). Blocking FFI (network): off main.
    public static func threadReply(channelID: String, rootID: String, text: String) throws -> SendResponse {
        try channelID.withCString { idPtr in
            try rootID.withCString { rootPtr in
                try text.withCString { textPtr in
                    try call(ostmac_thread_reply(idPtr, rootPtr, textPtr), as: SendResponse.self)
                }
            }
        }
    }

    /// One chat's roster with owner roles (core-a). Blocking FFI
    /// (network): call off the main thread.
    public static func chatMembers(chatID: String) throws -> ChatMembersResponse {
        try chatID.withCString { ptr in
            try call(ostmac_chat_members(ptr), as: ChatMembersResponse.self)
        }
    }

    /// Create a group chat with `users` (AAD ids or UPNs; self is added
    /// by core) and an optional topic (core-a G5). Blocking FFI
    /// (network): call off the main thread.
    public static func chatCreateGroup(users: [String], topic: String?) throws -> ChatCreateResponse {
        let data = try JSONEncoder().encode(users)
        let json = String(decoding: data, as: UTF8.self)
        return try json.withCString { usersPtr in
            try withOptionalCString(topic) { topicPtr in
                try call(ostmac_chat_create_group(usersPtr, topicPtr), as: ChatCreateResponse.self)
            }
        }
    }

    /// Delete one own message via core (blocking FFI: call off main thread).
    public static func deleteMessage(chatID: String, messageID: String) throws -> DeleteResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try call(ostmac_delete(idPtr, midPtr), as: DeleteResponse.self)
            }
        }
    }

    /// Leave one group chat via core (blocking FFI: call off main thread).
    public static func leaveChat(chatID: String) throws -> LeaveResponse {
        try chatID.withCString { ptr in
            try call(ostmac_leave(ptr), as: LeaveResponse.self)
        }
    }

    /// Mark one conversation read up to a message (blocking FFI: call off
    /// the main thread). Empty ids throw via core's arg envelope.
    public static func markRead(chatID: String, messageID: String) throws -> MarkReadResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try call(ostmac_mark_read(idPtr, midPtr), as: MarkReadResponse.self)
            }
        }
    }

    /// Peer read positions for one thread (blocking FFI: call off main).
    public static func receipts(threadID: String) throws -> ReceiptsResponse {
        try threadID.withCString { ptr in
            try call(ostmac_receipts(ptr), as: ReceiptsResponse.self)
        }
    }

    /// One fetched inline image: decoded bytes + content type, if any.
    /// Blocking FFI (network): call off the main thread.
    public static func mediaFetch(url: String) throws -> (data: Data, contentType: String?) {
        let resp: MediaResponse = try url.withCString { ptr in
            try call(ostmac_media_fetch(ptr), as: MediaResponse.self)
        }
        guard let data = Data(base64Encoded: resp.data_base64) else {
            throw CoreCallError.failed("media: bad base64 from core")
        }
        return (data, resp.content_type)
    }

    /// OneDrive file search, one $top window (blocking FFI + network:
    /// call off the main thread). Rows reuse the Shared tab shape.
    public static func fileSearch(query: String, limit: Int32 = 25) throws -> FileSearchResponse {
        try query.withCString { ptr in
            try call(ostmac_file_search(ptr, limit), as: FileSearchResponse.self)
        }
    }

    /// Directory people search, one $top window (blocking FFI + network:
    /// call off the main thread). Rows reuse the roster shape.
    public static func peopleSearch(query: String, limit: Int32 = 25) throws -> PeopleSearchResponse {
        try query.withCString { ptr in
            try call(ostmac_people_search(ptr, limit), as: PeopleSearchResponse.self)
        }
    }

    public static func sharedFiles(chatID: String, limit: Int32 = 20, includeFolders: Bool = false) throws -> SharedFilesResponse {
        try chatID.withCString { ptr in
            if includeFolders {
                try call(ostmac_files_opts(ptr, limit, 1), as: SharedFilesResponse.self)
            } else {
                try call(ostmac_files(ptr, limit), as: SharedFilesResponse.self)
            }
        }
    }

    /// One folder's children by drive+item id (om-i5-folders): files AND
    /// subfolders, unfiltered. Blocking FFI (network): call off main.
    public static func sharedChildren(driveID: String, itemID: String, limit: Int32 = 50) throws -> SharedFileChildrenResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try call(ostmac_files_children(dPtr, iPtr, limit), as: SharedFileChildrenResponse.self)
            }
        }
    }

    /// Recently accessed files across OneDrive + SharePoint, one $top
    /// window (top10-files: unified Files surface's drive leg). Blocking
    /// FFI (network): call off the main thread.
    public static func driveRecents(limit: Int32 = 25) throws -> DriveRecentsResponse {
        try call(ostmac_files_recents(limit), as: DriveRecentsResponse.self)
    }

    public static func sharedUpload(chatID: String, path: String) throws -> SharedFileUploadResponse {
        try chatID.withCString { idPtr in
            try path.withCString { pathPtr in
                try call(ostmac_files_upload(idPtr, pathPtr), as: SharedFileUploadResponse.self)
            }
        }
    }

    /// Current upload-progress gauge (pure core read, no network).
    /// Poll while an upload spinner runs. Never blocks meaningfully,
    /// but still crosses FFI: call off the main thread like every wrapper.
    public static func sharedUploadProgress() throws -> UploadProgressResponse {
        try call(ostmac_files_upload_progress(), as: UploadProgressResponse.self)
    }

    public static func sharedDownload(driveID: String, itemID: String, dest: String) throws -> SharedFileDownloadResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try dest.withCString { destPtr in
                    try call(ostmac_files_download(dPtr, iPtr, destPtr), as: SharedFileDownloadResponse.self)
                }
            }
        }
    }

    /// View-only sharing link for one driveItem (Graph createLink).
    /// scope "organization" (default) or "anonymous". Blocking FFI
    /// (network): call off the main thread.
    public static func sharedLink(driveID: String, itemID: String, scope: String = "organization") throws -> SharedFileLinkResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try scope.withCString { sPtr in
                    try call(ostmac_files_link(dPtr, iPtr, sPtr), as: SharedFileLinkResponse.self)
                }
            }
        }
    }

    public static func sharedRename(driveID: String, itemID: String, newName: String) throws -> SharedFileManageResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try newName.withCString { nPtr in
                    try call(ostmac_files_rename(dPtr, iPtr, nPtr), as: SharedFileManageResponse.self)
                }
            }
        }
    }

    /// Version history for one driveItem, newest first (blocking FFI +
    /// network: call off the main thread).
    public static func fileVersions(driveID: String, itemID: String) throws -> FileVersionsResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try call(ostmac_file_versions(dPtr, iPtr), as: FileVersionsResponse.self)
            }
        }
    }

    /// Restore one version as current (blocking FFI + network).
    public static func fileVersionRestore(
        driveID: String, itemID: String, versionID: String
    ) throws -> FileVersionRestoreResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try versionID.withCString { vPtr in
                    try call(
                        ostmac_file_version_restore(dPtr, iPtr, vPtr),
                        as: FileVersionRestoreResponse.self)
                }
            }
        }
    }

    public static func sharedMove(driveID: String, itemID: String, destFolderID: String) throws -> SharedFileManageResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try destFolderID.withCString { fPtr in
                    try call(ostmac_files_move(dPtr, iPtr, fPtr), as: SharedFileManageResponse.self)
                }
            }
        }
    }

    /// Download one old version's content to dest (blocking FFI + network).
    public static func fileVersionDownload(
        driveID: String, itemID: String, versionID: String, dest: String
    ) throws -> SharedFileDownloadResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try versionID.withCString { vPtr in
                    try dest.withCString { destPtr in
                        try call(
                            ostmac_file_version_download(dPtr, iPtr, vPtr, destPtr),
                            as: SharedFileDownloadResponse.self)
                    }
                }
            }
        }
    }

    public static func sharedCopy(driveID: String, itemID: String, destFolderID: String, newName: String?) throws -> SharedFileCopyResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try destFolderID.withCString { fPtr in
                    if let name = newName, !name.isEmpty {
                        try name.withCString { nPtr in
                            try call(ostmac_files_copy(dPtr, iPtr, fPtr, nPtr), as: SharedFileCopyResponse.self)
                        }
                    } else {
                        try call(ostmac_files_copy(dPtr, iPtr, fPtr, nil), as: SharedFileCopyResponse.self)
                    }
                }
            }
        }
    }

    public static func sharedDelete(driveID: String, itemID: String) throws -> SharedFileDeleteResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try call(ostmac_files_delete(dPtr, iPtr), as: SharedFileDeleteResponse.self)
            }
        }
    }

    /// Swift-native (R14 om-later-b4 B4; was `ostmac_presence`).
    public static func presence() throws -> PresenceResponse {
        try CoreReads.presence()
    }

    public static func setPresence(status: String) throws -> PresenceResponse {
        try status.withCString { ptr in
            try call(ostmac_presence_set(ptr), as: PresenceResponse.self)
        }
    }

    public static func userPresence(id: String) throws -> UserPresenceResponse {
        try id.withCString { ptr in
            try call(ostmac_presence_user(ptr), as: UserPresenceResponse.self)
        }
    }

    public static func resolveMri(mri: String) throws -> ResolveMriResponse {
        try mri.withCString { ptr in
            try call(ostmac_resolve_mri(ptr), as: ResolveMriResponse.self)
        }
    }

    public static func reminders() throws -> RemindersResponse {
        try call(ostmac_reminders(), as: RemindersResponse.self)
    }

    public static func reminderTasks(listID: String, limit: Int32 = 50) throws -> ReminderTasksResponse {
        try listID.withCString { ptr in
            try call(ostmac_reminder_tasks(ptr, limit), as: ReminderTasksResponse.self)
        }
    }

    public static func reminderAdd(listID: String, title: String) throws -> ReminderTaskResult {
        try listID.withCString { idPtr in
            try title.withCString { titlePtr in
                try call(ostmac_reminder_add(idPtr, titlePtr), as: ReminderTaskResult.self)
            }
        }
    }

    public static func notebooks(groupID: String? = nil) throws -> NotebooksResponse {
        try withOptionalCString(groupID) { ptr in
            try call(ostmac_notes(ptr), as: NotebooksResponse.self)
        }
    }

    public static func noteSections(notebookID: String, groupID: String? = nil) throws -> NoteSectionsResponse {
        try notebookID.withCString { nbPtr in
            try withOptionalCString(groupID) { ptr in
                try call(ostmac_note_sections(nbPtr, ptr), as: NoteSectionsResponse.self)
            }
        }
    }

    public static func reminderDone(listID: String, taskID: String) throws -> ReminderTaskResult {
        try listID.withCString { idPtr in
            try taskID.withCString { taskPtr in
                try call(ostmac_reminder_done(idPtr, taskPtr), as: ReminderTaskResult.self)
            }
        }
    }

    /// Upcoming meetings (blocking network: call off main thread).
    /// Swift-native (R14 om-later-b4 B4; was `ostmac_meetings`).
    public static func meetings(limit: Int32 = 20) throws -> MeetingsResponse {
        try CoreReads.meetings(limit: limit)
    }

    /// Classify a pasted join string (pure parse, no network, no FFI).
    /// Swift-native (R12 ffi-move-now B1; was `ostmac_meeting_join_parse`).
    public static func meetingJoinParse(raw: String) throws -> JoinParseResponse {
        try CoreLocal.meetingJoinParse(raw: raw)
    }

    public static func notePage(pageID: String, groupID: String? = nil) throws -> NotePageResponse {
        try pageID.withCString { idPtr in
            try withOptionalCString(groupID) { ptr in
                try call(ostmac_note_page(idPtr, ptr), as: NotePageResponse.self)
            }
        }
    }

    public static func noteAppend(pageID: String, text: String, groupID: String? = nil) throws -> NoteAppendResponse {
        try pageID.withCString { idPtr in
            try text.withCString { textPtr in
                try withOptionalCString(groupID) { ptr in
                    try call(ostmac_note_append(idPtr, textPtr, ptr), as: NoteAppendResponse.self)
                }
            }
        }
    }

    /// Run `body` with a nullable C string (nil stays NULL for core).
    private static func withOptionalCString<T>(
        _ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
    }

    public static func trouterStart() -> Int32 { ostmac_trouter_start() }
    public static func trouterStop() -> Int32 { ostmac_trouter_stop() }

    public static func trouterPoll() throws -> TrouterPoll {
        try call(ostmac_trouter_poll(), as: TrouterPoll.self)
    }

    public static func trouterPollTyped() throws -> RealtimePoll {
        try call(ostmac_trouter_poll_typed(), as: RealtimePoll.self)
    }

    /// Blocking raw drain: waits up to `timeoutMs` for the first event
    /// (0 = poll without waiting). Blocking FFI: call off the main thread.
    public static func trouterPollWait(timeoutMs: UInt64 = 0) throws -> TrouterPoll {
        try call(ostmac_trouter_poll_wait(timeoutMs), as: TrouterPoll.self)
    }

    /// Blocking typed drain: waits up to `timeoutMs` for the first event
    /// (0 = poll without waiting). Blocking FFI: call off the main thread.
    public static func trouterPollTypedWait(timeoutMs: UInt64 = 0) throws -> RealtimePoll {
        try call(ostmac_trouter_poll_typed_wait(timeoutMs), as: RealtimePoll.self)
    }

    public static func callStatus() throws -> CallStatus {
        try call(ostmac_call_status(), as: CallStatus.self)
    }

    public static func callPlace(threadID: String, timeoutSecs: Int32 = 30) throws -> CallResult {
        try threadID.withCString { ptr in
            try call(ostmac_call_place(ptr, timeoutSecs), as: CallResult.self)
        }
    }

    public static func callEcho(timeoutSecs: Int32 = 30) throws -> CallResult {
        try call(ostmac_call_echo(timeoutSecs), as: CallResult.self)
    }

    /// Blocks up to `timeoutSecs` like callPlace; live media attaches on accept.
    public static func callPlaceLive(threadID: String, timeoutSecs: Int32 = 30) throws -> CallResult {
        try threadID.withCString { ptr in
            try call(ostmac_call_place_live(ptr, timeoutSecs), as: CallResult.self)
        }
    }

    /// 1:1 video call with live media (VIDEO1).
    public static func callPlaceLiveVideo(threadID: String, timeoutSecs: Int32 = 30) throws -> CallResult {
        try threadID.withCString { ptr in
            try call(ostmac_call_place_live_video(ptr, timeoutSecs), as: CallResult.self)
        }
    }

    public static func callEchoLive(timeoutSecs: Int32 = 30) throws -> CallResult {
        try call(ostmac_call_echo_live(timeoutSecs), as: CallResult.self)
    }

    public static func callAccept() throws -> CallResult {
        try call(ostmac_call_accept(), as: CallResult.self)
    }

    public static func callAcceptLive() throws -> CallResult {
        try call(ostmac_call_accept_live(), as: CallResult.self)
    }

    /// Accept the ringing call as a video call with live media (VIDEO1).
    public static func callAcceptLiveVideo() throws -> CallResult {
        try call(ostmac_call_accept_live_video(), as: CallResult.self)
    }

    public static func callEnd() throws -> CallResult {
        try call(ostmac_call_end(), as: CallResult.self)
    }

    public static func callRecordInject() throws -> CallResult {
        try call(ostmac_call_record_inject(), as: CallResult.self)
    }

    // Take ownership of a Rust-allocated C string, decode, free.
    // Bytes-direct (om-perf-poll-timers): one length-delimited copy
    // straight into Data. The old String(cString:)+data(using:.utf8)
    // round-trip scanned + allocated twice and re-encoded the UTF-8
    // the core already handed us (measured 28us -> 15us per 300KB,
    // medians, same-harness both-ways; see PERF-POLL-TIMERS-PROOF).
    // Invalid UTF-8 now surfaces as a DecodingError from the decoder
    // instead of trapping in String(cString:); the core only emits
    // valid UTF-8 (Rust String), so this path is unreachable live.
    static func call<T: Decodable>(
        _ raw: UnsafeMutablePointer<CChar>?, as type: T.Type
    ) throws -> T {
        guard let raw else { throw CoreCallError.failed("null from core") }
        defer { ostmac_free(raw) }
        let data = Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
        return try decodeOrThrow(type, from: data)
    }
}
