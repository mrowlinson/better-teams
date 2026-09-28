// ReadCore.swift — R14 om-later-b4: B4 reads moved from Rust FFI to
// Swift (Graph/URLSession). Exact port of the ostmac-core backing fns +
// ost::api projections; same envelopes, same error codes, same query
// shapes. Blocking network: call off the main thread (same contract as
// the old blocking FFI).
import Foundation

// MARK: - Sync GET seam (tests inject stubs; zero live network)

/// One sync GET result.
struct ReadHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

protocol ReadFetcher: Sendable {
    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse
}

/// URLSession-backed sync GET (semaphore bridge; production use).
struct URLSessionReadFetcher: ReadFetcher {
    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let request = req  // immutable copy for the concurrent closure
        return try SyncBridge.run {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return ReadHTTPResponse(status: status, data: data)
        }
    }
}

/// Sync-over-async bridge (callers already run off-main; same blocking
/// contract the FFI `block_on` had).
enum SyncBridge {
    private final class Box<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    static func run<T: Sendable>(
        _ op: @Sendable @escaping () async throws -> T
    ) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                box.value = .success(try await op())
            } catch {
                box.value = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try box.value!.get()
    }
}

/// Injected seams for one read call.
struct ReadContext {
    var store: any TokenStore
    var http: any ReadFetcher
    var refresher: any TokenRefreshFetcher
    var now: @Sendable () -> UInt64
}

// MARK: - CoreReads (moved B4 symbols)

/// Swift-native implementations of the moved B4 reads. Same response
/// models as the old FFI; failures throw `CoreCallError.failed` with the
/// same `code: detail` message the envelope decode produced.
public enum CoreReads {
    static let graphBase = "https://graph.microsoft.com/v1.0"

    // MARK: public entry points (production seams)

    public static func whoami() throws -> WhoamiResponse {
        try whoami(profile: CoreLocal.activeProfileID(), ctx: production())
    }

    public static func whoami(profile: String) throws -> WhoamiResponse {
        try whoami(profile: profile, ctx: production())
    }

    public static func presence() throws -> PresenceResponse {
        try presence(ctx: production())
    }

    public static func teams() throws -> TeamsResponse {
        try teams(ctx: production())
    }

    public static func meetings(limit: Int32 = 20) throws -> MeetingsResponse {
        try meetings(limit: limit, ctx: production())
    }

    static func production() throws -> ReadContext {
        let store = try PersistentTokenStore(
            blob: KeychainTokenStore(), configDir: nil
        )
        return ReadContext(
            store: store, http: URLSessionReadFetcher(),
            refresher: URLSessionTokenFetcher(), now: { TokenStatus.nowSecs() }
        )
    }

    // MARK: whoami cache (mirrors Rust whoami_cache: per-profile slot)

    private static let cacheLock = NSLock()
    private static var cache: [String: WhoamiResponse] = [:]

    static func cached(profile: String) -> WhoamiResponse? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[TomlConfig.normalize(profile)]
    }

    /// Test seam (mirrors Rust `whoami_cache_store`).
    static func whoamiCacheStore(profile: String, value: WhoamiResponse) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[TomlConfig.normalize(profile)] = value
    }

    /// Drop one profile's slot (sign-out / new sign-in there).
    public static func whoamiCacheClear(profile: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeValue(forKey: TomlConfig.normalize(profile))
    }

    /// Drop all slots (auth events whose profile is untracked here).
    public static func whoamiCacheClearAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeAll()
    }

    // MARK: token plumbing (mirrors TeamsClient::new_for_profile)

    /// Fresh Graph Bearer [REDACTED] `code` on every failure (mirrors the
    /// Rust bail strings, including the login hint).
    static func graphToken(
        profile: String, code: String, ctx: ReadContext
    ) throws -> String {
        let slots = try ensureFresh(profile: profile, code: code, ctx: ctx)
        guard let g = slots.graphToken else {
            throw CoreCallError.failed(
                "\(code): No Graph token. Run 'teams-cli login' first."
            )
        }
        if g.isExpired(now: ctx.now()) {
            throw CoreCallError.failed(
                "\(code): Graph token expired. Run 'teams-cli login'."
            )
        }
        return g.token
    }

    /// Skype token for the native chat stack. Like Rust, skype expiry
    /// alone never triggers a refresh (only AAD/graph do) — an expired
    /// skype slot fails the read.
    static func skypeToken(
        profile: String, code: String, ctx: ReadContext
    ) throws -> (String, TokenSlots) {
        let slots = try ensureFresh(profile: profile, code: code, ctx: ctx)
        guard let s = slots.skypeToken else {
            throw CoreCallError.failed(
                "\(code): No Skype token. Run 'teams-cli login' first."
            )
        }
        if s.isExpired(now: ctx.now()) {
            throw CoreCallError.failed(
                "\(code): Skype token expired. Run 'teams-cli login'."
            )
        }
        return (s.token, slots)
    }

    /// Refresh-on-expiry (mirrors `TeamsClient::new_for_profile`) and
    /// return the reloaded slots.
    static func ensureFresh(
        profile: String, code: String, ctx: ReadContext
    ) throws -> TokenSlots {
        let name = TomlConfig.normalize(profile)
        var slots = ctx.store.load(profile: name)
        let now = ctx.now()
        let accessBad = slots.accessToken.map { $0.isExpired(now: now) } ?? true
        let graphBad = slots.graphToken.map { $0.isExpired(now: now) } ?? true
        if accessBad || graphBad {
            guard let rt = slots.refreshToken, !rt.isEmpty else {
                throw CoreCallError.failed(
                    "\(code): Token expired and no refresh token. Run 'teams-cli login'."
                )
            }
            let ok: Bool
            do {
                ok = try SyncBridge.run {
                    try await TokenRefresh.refresh(
                        profile: name, store: ctx.store,
                        fetcher: ctx.refresher, now: ctx.now
                    )
                }
            } catch {
                throw CoreCallError.failed(
                    "\(code): Token refresh failed: \(error). Run 'teams-cli login'."
                )
            }
            guard ok else {
                throw CoreCallError.failed(
                    "\(code): No refresh token available. Run 'teams-cli login'."
                )
            }
            slots = ctx.store.load(profile: name)
        }
        return slots
    }

    // MARK: Graph GET (mirrors client::graph_get + check_response)

    static func graphGET(
        _ path: String, code: String, token: String, http: any ReadFetcher
    ) throws -> Data {
        guard let url = URL(string: graphBase + path) else {
            throw CoreCallError.failed("\(code): bad Graph path \(path)")
        }
        let resp: ReadHTTPResponse
        do {
            resp = try http.get(
                url: url, headers: ["Authorization": "Bearer \(token)"]
            )
        } catch {
            throw CoreCallError.failed("\(code): GET \(url) failed: \(error)")
        }
        if resp.status == 401 {
            throw CoreCallError.failed(
                "\(code): 401 Unauthorized for \(url). Token may be invalid -- run 'teams-cli login'."
            )
        }
        if !(200 ... 299).contains(resp.status) {
            let body = String(data: resp.data, encoding: .utf8) ?? ""
            throw CoreCallError.failed(
                "\(code): HTTP \(resp.status) for \(url): \(body)"
            )
        }
        return resp.data
    }

    // MARK: whoami (GET /me, cached)

    private struct MePayload: Decodable {
        let id: String
        let displayName: String?
        let mail: String?
    }

    static func whoami(profile: String, ctx: ReadContext) throws -> WhoamiResponse {
        if let hit = cached(profile: profile) { return hit }
        let token = try graphToken(profile: profile, code: "whoami", ctx: ctx)
        let data = try graphGET("/me", code: "whoami", token: token, http: ctx.http)
        let me: MePayload
        do {
            me = try JSONDecoder().decode(MePayload.self, from: data)
        } catch {
            throw CoreCallError.failed("whoami: Failed to parse /me response: \(error)")
        }
        // Same envelope as the retired Rust `whoami_envelope`.
        var obj: [String: Any] = [
            "ok": true, "id": me.id,
            "display_name": me.displayName ?? "User",
        ]
        obj["mail"] = me.mail ?? NSNull()
        let out = try decodeOrThrow(
            WhoamiResponse.self,
            from: CoreLocal.statusJSONData(obj)
        )
        whoamiCacheStore(profile: profile, value: out)
        return out
    }

    // MARK: presence (GET /me/presence)

    private struct PresencePayload: Decodable {
        let availability: String
        let activity: String
    }

    static func presence(ctx: ReadContext) throws -> PresenceResponse {
        let token = try graphToken(
            profile: CoreLocal.activeProfileID(), code: "presence", ctx: ctx
        )
        let data = try graphGET(
            "/me/presence", code: "presence", token: token, http: ctx.http
        )
        let p: PresencePayload
        do {
            p = try JSONDecoder().decode(PresencePayload.self, from: data)
        } catch {
            throw CoreCallError.failed(
                "presence: Failed to parse presence response: \(error)"
            )
        }
        return PresenceResponse(
            ok: true, availability: p.availability, activity: p.activity
        )
    }

    // MARK: teams (GET /me/joinedTeams + per-team channels)

    private struct TeamsPayload: Decodable {
        struct Team: Decodable {
            let id: String
            let displayName: String?
        }
        let value: [Team]
    }

    private struct ChannelsPayload: Decodable {
        struct Channel: Decodable {
            let id: String
            let displayName: String?
            let description: String?
            let membershipType: String?
            let webUrl: String?
        }
        let value: [Channel]
    }

    static func teams(ctx: ReadContext) throws -> TeamsResponse {
        let token = try graphToken(
            profile: CoreLocal.activeProfileID(), code: "teams", ctx: ctx
        )
        let data = try graphGET(
            "/me/joinedTeams", code: "teams", token: token, http: ctx.http
        )
        let teams: TeamsPayload
        do {
            teams = try JSONDecoder().decode(TeamsPayload.self, from: data)
        } catch {
            throw CoreCallError.failed(
                "teams: Failed to parse joinedTeams response: \(error)"
            )
        }
        var items: [TeamItem] = []
        for team in teams.value {
            // Channels failure degrades to an empty list (Rust parity).
            let channels = (try? graphGET(
                "/teams/\(team.id)/channels", code: "teams",
                token: token, http: ctx.http
            ))
                .flatMap { try? JSONDecoder().decode(ChannelsPayload.self, from: $0) }
                .map { payload in
                    payload.value.map { ch in
                        TeamChannel(
                            channelId: ch.id, name: ch.displayName ?? ch.id,
                            description: ch.description,
                            membershipType: ch.membershipType,
                            webUrl: ch.webUrl
                        )
                    }
                } ?? []
            items.append(TeamItem(
                teamId: team.id, name: team.displayName ?? team.id,
                channels: channels
            ))
        }
        return TeamsResponse(ok: true, teams: items)
    }

    // MARK: meetings (GET calendarView, next 7 days)

    static func unixToISO8601(_ secs: UInt64) -> String {
        let days = Int64(secs / 86_400)
        let rem = secs % 86_400
        let (y, m, d) = civilFromDays(days + 719_468)
        func pad(_ v: UInt64, _ w: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(pad(UInt64(y), 4))-\(pad(UInt64(m), 2))-\(pad(UInt64(d), 2))" +
            "T\(pad(rem / 3600, 2)):\(pad((rem % 3600) / 60, 2)):\(pad(rem % 60, 2))Z"
    }

    /// Days since 0000-03-01 → (year, month, day). Hinnant's algorithm
    /// (verbatim port of the ost helper; inputs are non-negative).
    static func civilFromDays(_ z: Int64) -> (Int64, UInt32, UInt32) {
        let era = z / 146_097
        let doe = UInt64(z % 146_097)
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = Int64(yoe) + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = UInt32(doy - (153 * mp + 2) / 5 + 1)
        let m = UInt32(mp < 10 ? mp + 3 : mp - 9)
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Percent-encode a query value (Graph datetimes carry `:`).
    static func encodeParam(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for b in s.utf8 {
            if (0x30 ... 0x39).contains(b) || (0x41 ... 0x5A).contains(b)
                || (0x61 ... 0x7A).contains(b)
                || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x7E
            {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Build the `calendarView` path for `[now, now+days]` (verbatim port).
    static func calendarViewPath(now: UInt64, days: UInt64, limit: Int) -> String {
        let start = unixToISO8601(now)
        let end = unixToISO8601(now + days * 86_400)
        return "/me/calendar/calendarView?startDateTime=\(encodeParam(start))" +
            "&endDateTime=\(encodeParam(end))&$top=\(limit)" +
            "&$orderby=start/dateTime" +
            "&$select=id,subject,isOnlineMeeting,onlineMeeting,start,end,organizer,webLink,isOrganizer"
    }

    private struct CalendarViewPayload: Decodable {
        struct DateTimeZone: Decodable {
            let dateTime: String?
            let timeZone: String?
        }
        struct OnlineMeeting: Decodable {
            let joinUrl: String?
        }
        struct EmailAddress: Decodable {
            let name: String?
            let address: String?
        }
        struct Organizer: Decodable {
            let emailAddress: EmailAddress?
        }
        struct Event: Decodable {
            let id: String
            let subject: String?
            let isOnlineMeeting: Bool?
            let onlineMeeting: OnlineMeeting?
            let start: DateTimeZone?
            let end: DateTimeZone?
            let organizer: Organizer?
            let webLink: String?
            let isOrganizer: Bool?
        }
        let value: [Event]
    }

    /// Parse one Graph `calendarView` payload (verbatim port of
    /// `parse_calendar_view` + `meeting_info`).
    static func parseCalendarView(_ data: Data) throws -> [MeetingItem] {
        let resp: CalendarViewPayload
        do {
            resp = try JSONDecoder().decode(CalendarViewPayload.self, from: data)
        } catch {
            throw CoreCallError.failed(
                "meetings: Failed to parse calendarView response: \(error)"
            )
        }
        return resp.value.map { e in
            let join = e.onlineMeeting?.joinUrl.flatMap { u in
                u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : u
            }
            let subject = (e.subject ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? "(no subject)" : e.subject!
            return MeetingItem(
                meetingId: e.id, subject: subject,
                start: e.start?.dateTime, end: e.end?.dateTime,
                joinURL: join,
                organizer: e.organizer?.emailAddress?.name,
                organizerEmail: e.organizer?.emailAddress?.address.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                },
                isOrganizer: e.isOrganizer ?? false,
                isOnline: e.isOnlineMeeting ?? false
            )
        }
    }

    static func meetings(limit: Int32, ctx: ReadContext) throws -> MeetingsResponse {
        let lim = limit <= 0 ? 20 : Int(limit)
        let token = try graphToken(
            profile: CoreLocal.activeProfileID(), code: "meetings", ctx: ctx
        )
        let path = calendarViewPath(now: ctx.now(), days: 7, limit: lim)
        let data = try graphGET(path, code: "meetings", token: token, http: ctx.http)
        return MeetingsResponse(ok: true, meetings: try parseCalendarView(data))
    }

    // MARK: chats (native chat stack: CSA → chatsvcagg → chat service)

    static let csaConversations =
        "https://teams.microsoft.com/api/csa/api/v1/teams/users/ME/conversations"
    static let defaultChatService = "https://amer.ng.msg.teams.microsoft.com"
    static let defaultChatsvcagg = "https://chatsvcagg.teams.microsoft.com"
    static let csaClientVersion = "1416/1.0.0.2024050301"

    public static func chats(limit: Int32 = 20) throws -> ChatsResponse {
        try chats(limit: limit, ctx: production())
    }

    /// Chat list for one account profile (gap-g1 background poll: the
    /// inactive accounts' tokens load by profile, no active flip). Nil =
    /// the active profile (same as `chats(limit:)`).
    public static func chats(limit: Int32 = 20, profile: String?) throws -> ChatsResponse {
        try chats(limit: limit, profile: profile, ctx: production())
    }

    /// Region base URLs from the stored gtms JSON (verbatim port of
    /// `chat_service_url` / `chatsvcagg_url`; unparseable → defaults).
    static func regionGTMS(_ slots: TokenSlots) -> [String: String] {
        guard let raw = slots.regionGtms,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
              as? [String: String]
        else { return [:] }
        return obj
    }

    static func chatServiceURL(_ slots: TokenSlots) -> String {
        regionGTMS(slots)["chatService"] ?? defaultChatService
    }

    static func chatsvcaggURL(_ slots: TokenSlots) -> String {
        regionGTMS(slots)["chatServiceAggregator"] ?? defaultChatsvcagg
    }

    /// Checked GET with explicit headers (mirrors `check_response`).
    static func checkedGET(
        _ urlString: String, code: String,
        headers: [String: String], http: any ReadFetcher
    ) throws -> Data {
        guard let url = URL(string: urlString) else {
            throw CoreCallError.failed("\(code): bad URL \(urlString)")
        }
        let resp: ReadHTTPResponse
        do {
            resp = try http.get(url: url, headers: headers)
        } catch {
            throw CoreCallError.failed("\(code): GET \(url) failed: \(error)")
        }
        if resp.status == 401 {
            throw CoreCallError.failed(
                "\(code): 401 Unauthorized for \(url). Token may be invalid -- run 'teams-cli login'."
            )
        }
        if !(200 ... 299).contains(resp.status) {
            let body = String(data: resp.data, encoding: .utf8) ?? ""
            throw CoreCallError.failed(
                "\(code): HTTP \(resp.status) for \(url): \(body)"
            )
        }
        return resp.data
    }

    static func csaGET(
        _ urlString: String, code: String,
        skype: String, http: any ReadFetcher
    ) throws -> Data {
        try checkedGET(
            urlString, code: code,
            headers: [
                "Authorization": "Bearer \(skype)",
                "x-ms-client-version": csaClientVersion,
            ],
            http: http
        )
    }

    static func chatGET(
        _ urlString: String, code: String,
        skype: String, http: any ReadFetcher
    ) throws -> Data {
        try checkedGET(
            urlString, code: code,
            headers: ["Authentication": "skypetoken=\(skype)"],
            http: http
        )
    }

    private struct ChatConversationsPayload: Decodable {
        struct ThreadProps: Decodable {
            let topic: String?
            let lastjoinat: String?
            let members: String?
        }
        struct NativeMsg: Decodable {
            let id: String?
            let composetime: String?
            let originalarrivaltime: String?
            let imdisplayname: String?
            let content: String?
            let messagetype: String?
            let from: String?
        }
        struct Conversation: Decodable {
            let id: String?
            let threadProperties: ThreadProps?
            let lastMessage: NativeMsg?
        }
        let conversations: [Conversation]?
    }

    private struct ThreadMembersPayload: Decodable {
        struct Member: Decodable {
            let id: String?
        }
        let members: [Member]?
    }

    private struct ChatMessagesPayload: Decodable {
        struct Msg: Decodable {
            let id: String?
            let composetime: String?
            let originalarrivaltime: String?
            let imdisplayname: String?
            let content: String?
            let messagetype: String?
            let from: String?
        }
        let messages: [Msg]?
    }

    static func chats(limit: Int32, profile: String? = nil, ctx: ReadContext) throws -> ChatsResponse {
        let lim = limit <= 0 ? 20 : Int(limit)
        let profile = profile ?? CoreLocal.activeProfileID()
        let (skype, slots) = try skypeToken(
            profile: profile, code: "chats", ctx: ctx
        )
        let svc = chatServiceURL(slots)
        let agg = chatsvcaggURL(slots)
        // Three strategies, first success wins (verbatim order); the
        // last error propagates when all fail.
        var lastError: Error?
        let attempts: [(String, [String: String])] = [
            (
                "\(csaConversations)?view=mychats&pageSize=\(lim)",
                [
                    "Authorization": "Bearer \(skype)",
                    "x-ms-client-version": csaClientVersion,
                ]
            ),
            (
                "\(agg)/api/v2/users/ME/conversations?view=mychats&pageSize=\(lim)",
                ["Authentication": "skypetoken=\(skype)"]
            ),
            (
                "\(svc)/v1/users/ME/conversations?view=mychats&pageSize=\(lim)",
                ["Authentication": "skypetoken=\(skype)"]
            ),
        ]
        var data = Data()
        for (urlString, headers) in attempts {
            do {
                data = try checkedGET(
                    urlString, code: "chats",
                    headers: headers, http: ctx.http
                )
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        let payload: ChatConversationsPayload
        do {
            payload = try JSONDecoder().decode(
                ChatConversationsPayload.self, from: data
            )
        } catch {
            throw CoreCallError.failed(
                "chats: Failed to parse conversations response: \(error)"
            )
        }
        let conversations = payload.conversations ?? []
        var items: [ChatItem] = []
        var needsMate: [(chat: Int, conv: Int)] = []
        for (ci, conv) in conversations.enumerated() {
            let id = conv.id ?? ""
            if id.isEmpty { continue }
            let topicMissing = (conv.threadProperties?.topic ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if topicMissing, isOneToOneID(id) {
                needsMate.append((items.count, ci))
            }
            let msg = conv.lastMessage
            let preview = msg?.content.map {
                truncatePreview(stripHTML($0))
            }
            items.append(ChatItem(
                chatId: id,
                name: conversationName(topic: conv.threadProperties?.topic, mate: nil, sender: msg?.imdisplayname, chatID: id),
                is_group: id.contains("thread") || id.contains("meeting"),
                last_message_time: msg?.originalarrivaltime ?? msg?.composetime,
                last_message_sender: msg?.imdisplayname,
                last_message_preview: preview
            ))
        }
        // Second pass: 1:1 mate names. Any failure keeps the first-pass
        // name — the list never fails here.
        if !needsMate.isEmpty,
           let me = try? whoami(profile: profile, ctx: ctx)
        {
            for (chatIdx, convIdx) in needsMate {
                let chatID = items[chatIdx].chatId
                if let mate = resolveMateName(
                    chatID: chatID, selfOID: me.id,
                    skype: skype, svc: svc, ctx: ctx
                ) {
                    let conv = conversations[convIdx]
                    let renamed = conversationName(
                        topic: conv.threadProperties?.topic, mate: mate,
                        sender: conv.lastMessage?.imdisplayname, chatID: chatID
                    )
                    let old = items[chatIdx]
                    items[chatIdx] = ChatItem(
                        chatId: old.chatId, name: renamed,
                        is_group: old.is_group,
                        last_message_time: old.last_message_time,
                        last_message_sender: old.last_message_sender,
                        last_message_preview: old.last_message_preview
                    )
                }
            }
        }
        return ChatsResponse(ok: true, chats: items)
    }

    /// Mate display name for a 1:1 chat (verbatim port of
    /// `resolve_mate_name`): exactly one non-self roster MRI with at
    /// least one message, else nil.
    static func resolveMateName(
        chatID: String, selfOID: String,
        skype: String, svc: String, ctx: ReadContext
    ) -> String? {
        guard let membersData = try? chatGET(
            "\(svc)/v1/threads/\(chatID)/members", code: "chats",
            skype: skype, http: ctx.http
        ),
            let members = try? JSONDecoder().decode(
                ThreadMembersPayload.self, from: membersData
            )
        else { return nil }
        let mates = (members.members ?? []).compactMap(\.id)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !mriIsSelf($0, selfOID: selfOID) }
        guard mates.count == 1 else { return nil }
        let mate = mates[0].lowercased()
        guard let pageData = try? chatGET(
            "\(svc)/v1/users/ME/conversations/\(chatID)/messages?pageSize=25",
            code: "chats", skype: skype, http: ctx.http
        ),
            let page = try? JSONDecoder().decode(
                ChatMessagesPayload.self, from: pageData
            )
        else { return nil }
        // Wire is newest-first; oldest-first, then newest match wins.
        for msg in (page.messages ?? []).reversed() {
            let msgtype = msg.messagetype ?? ""
            guard messageTypeKept(msgtype) else { continue }
            let sender = (msg.imdisplayname ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "?" : msg.imdisplayname!
            let mri = mriFromUserLink(msg.from)
            guard mri.lowercased() == mate else { continue }
            guard !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sender != "?"
            else { continue }
            let body = splitReplyQuote(msg.content ?? "")
            let text = stripHTML(body)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasImage(msg.content ?? "")
                || hasCardPayload(msg.content ?? "")
            else { continue }
            return sender
        }
        return nil
    }

    // MARK: chat naming + text (verbatim ports from ost chat.rs)

    /// 1:1-shaped thread ids (`19:…@unq.…`).
    static func isOneToOneID(_ chatID: String) -> Bool {
        chatID.hasPrefix("19:") && !chatID.contains("@thread")
            && !chatID.contains("meeting")
    }

    /// Display name: topic → mate → last sender → system label.
    static func conversationName(
        topic: String?, mate: String?, sender: String?, chatID: String
    ) -> String {
        if let topic,
           !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return topic
        }
        if let mate,
           !mate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return mate
        }
        if let sender,
           !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sender
        }
        return systemLabelFor(chatID)
    }

    /// Human label for a chat with no topic, mate, or sender.
    static func systemLabelFor(_ chatID: String) -> String {
        if chatID.hasPrefix("48:") {
            let rest = String(chatID.dropFirst(3))
            guard let first = rest.first else { return "[System chat]" }
            return first.uppercased() + rest.dropFirst()
        }
        if chatID.contains("meeting") { return "[Meeting chat]" }
        if chatID.contains("@thread") { return "[Group chat]" }
        if chatID.hasPrefix("19:") { return "[Direct message]" }
        return "[Chat]"
    }

    /// Block-level tags yield one pending space; inline tags vanish.
    static let blockTags: Set<String> = [
        "p", "div", "br", "section", "article", "header", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl",
        "dt", "dd", "table", "tr", "td", "th", "blockquote", "pre", "hr",
    ]

    static func tagName(_ body: String) -> String {
        let b = body.hasPrefix("/") ? String(body.dropFirst()) : body
        let end = b.firstIndex(where: { $0.isWhitespace || $0 == "/" })
            ?? b.endIndex
        return String(b[..<end])
    }

    /// Spacing-aware HTML strip (verbatim port of `strip_html`).
    static func stripHTML(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var tag = ""
        var inTag = false
        var pendingSpace = false
        for ch in html {
            if inTag {
                if ch == ">" {
                    inTag = false
                    if blockTags.contains(tagName(tag).lowercased()) {
                        pendingSpace = true
                    }
                    tag = ""
                } else {
                    tag.append(ch)
                }
            } else if ch == "<" {
                inTag = true
            } else {
                if pendingSpace {
                    pendingSpace = false
                    if !result.isEmpty,
                       !(result.last?.isWhitespace ?? false),
                       !ch.isWhitespace
                    {
                        result.append(" ")
                    }
                }
                result.append(ch)
            }
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Preview cut: byte length > 80 → cut at the last char boundary
    /// at byte offset ≤ 77 + "..." (verbatim port).
    static func truncatePreview(_ text: String) -> String {
        guard text.utf8.count > 80 else { return text }
        var end = text.startIndex
        var offset = 0
        for idx in text.indices {
            if offset <= 77 {
                end = idx
            } else {
                break
            }
            offset += text[idx].utf8.count
        }
        return String(text[..<end]) + "..."
    }

    /// Sender MRI from a message `from` user link (verbatim port).
    static func mriFromUserLink(_ from: String?) -> String {
        // components (not split): a trailing "/" yields "" like rsplit.
        let seg = (from ?? "").components(separatedBy: "/").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if seg.isEmpty { return "" }
        return seg.removingPercentEncoding ?? seg
    }

    /// True when `mri` is the signed-in user (verbatim port).
    static func mriIsSelf(_ mri: String, selfOID: String) -> Bool {
        if selfOID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || mri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        let m = mri.lowercased()
        let o = selfOID.lowercased()
        return m == o || m.hasSuffix(o)
    }

    static func messageTypeKept(_ messagetype: String) -> Bool {
        if !messagetype.contains("Text"), !messagetype.contains("RichText") {
            return false
        }
        if messagetype.contains("Media_"), !messagetype.contains("Media_Card") {
            return false
        }
        return true
    }

    static func hasCardPayload(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("<attachment")
            || lower.contains("o365connector")
            || lower.contains("adaptivecard")
            || lower.contains("messagecard")
            || lower.contains("application/vnd.microsoft")
    }

    static func hasImage(_ html: String) -> Bool {
        html.lowercased().contains("<img")
    }

    /// Split the `<quote>` block; returns the reply body (verbatim port
    /// of `split_reply_quote`, id discarded — chats list needs no parent).
    static func splitReplyQuote(_ content: String) -> String {
        guard let open = content.range(of: "<quote") else { return content }
        let rest = content[open.lowerBound...]
        guard let tagEnd = rest.firstIndex(of: ">") else { return content }
        let afterTag = rest[rest.index(after: tagEnd)...]
        guard let close = afterTag.range(of: "</quote>") else { return content }
        return String(content[..<open.lowerBound]) + String(afterTag[close.upperBound...])
    }
}
