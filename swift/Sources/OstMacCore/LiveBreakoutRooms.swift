// LiveBreakoutRooms.swift — BREAKOUT-BUILD: live rooms management over
// the RE-mapped MiddleTier REST (lane rebreakout, STATIC-MAPPED).
// BreakoutRoomsStore stays the demo local planner; this store drives the
// sheet's live path when the meeting + token allow it (CallSection passes
// a non-nil store exactly then). Every mutation round-trips the server:
// the store reloads the list after each write and surfaces failures as
// visible errors, never as fake local state.
import COstMac
import Combine
import Foundation

/// The five-part meeting coordinates every breakout URL embeds.
/// Key style matches the core's `MeetingCoords` JSON (snake_case).
public struct BreakoutCoords: Codable, Sendable, Equatable, Hashable {
    public var tenantID: String
    public var organizerID: String
    public var threadID: String
    public var messageID: String
    public var additionalMessageID: String?

    private enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case organizerID = "organizer_id"
        case threadID = "thread_id"
        case messageID = "message_id"
        case additionalMessageID = "additional_message_id"
    }

    public init(tenantID: String, organizerID: String, threadID: String,
                messageID: String, additionalMessageID: String? = nil) {
        self.tenantID = tenantID
        self.organizerID = organizerID
        self.threadID = threadID
        self.messageID = messageID
        self.additionalMessageID = additionalMessageID
    }

    public var jsonString: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Demo/evidence coords (never sent live: the demo transport answers).
    public static let demo = BreakoutCoords(
        tenantID: "demo-tenant", organizerID: "demo-organizer",
        threadID: "19:demo_standup@thread.v2", messageID: "1")
}

/// One live room participant (core `BreakoutParticipant` JSON).
public struct LiveBreakoutParticipant: Codable, Sendable, Equatable {
    public var mri: String?
    public var upn: String?
    public var objectID: String?

    private enum CodingKeys: String, CodingKey {
        case mri, upn, objectID = "objectId"
    }

    public init(mri: String? = nil, upn: String? = nil, objectID: String? = nil) {
        self.mri = mri
        self.upn = upn
        self.objectID = objectID
    }

    /// Stable seat key: mri first, then upn, then object id.
    public var seatKey: String { mri ?? upn ?? objectID ?? "?" }

    /// Matches a roster row by any of its ids.
    public func matches(rosterID: String) -> Bool {
        rosterID == mri || rosterID == upn || rosterID == objectID
    }
}

/// One live room (core `BreakoutRoomInfo` JSON).
public struct LiveBreakoutRoom: Codable, Sendable, Equatable, Identifiable {
    public var roomName: String
    public var coordinates: BreakoutCoords?
    public var participants: [LiveBreakoutParticipant]
    public var restrictChatAccess: Bool
    public var isOpened: Bool

    private enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case coordinates
        case participants
        case restrictChatAccess = "restrict_chat_access"
        case isOpened = "is_opened"
    }

    public init(roomName: String, coordinates: BreakoutCoords? = nil,
                participants: [LiveBreakoutParticipant] = [],
                restrictChatAccess: Bool = false, isOpened: Bool = false) {
        self.roomName = roomName
        self.coordinates = coordinates
        self.participants = participants
        self.restrictChatAccess = restrictChatAccess
        self.isOpened = isOpened
    }

    /// Server thread id (stable per room); falls back to the name for
    /// rooms the server never gave coords (never live, but keeps demo
    /// fixtures Identifiable).
    public var id: String { coordinates?.threadID ?? roomName }
}

/// Live room settings (core `RoomSettings` JSON, snake_case).
public struct LiveBreakoutSettings: Codable, Sendable, Equatable {
    public var allowChoose: Bool?
    public var roomDuration: String?
    public var allowJoinBack: Bool?
    public var allowMoveAuto: Bool?
    /// Managers the server named (opaque JSON each; the store echoes
    /// them back on save so an edit never wipes the organizer's list).
    public var managersJSON: String

    private enum CodingKeys: String, CodingKey {
        case allowChoose = "allow_users_to_select_breakout_room"
        case roomDuration = "room_duration"
        case allowJoinBack = "allow_join_back_to_main_meeting"
        case allowMoveAuto = "allow_move_participants_automatically"
        case managersJSON = "managers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowChoose = try c.decodeIfPresent(Bool.self, forKey: .allowChoose)
        roomDuration = try c.decodeIfPresent(String.self, forKey: .roomDuration)
        allowJoinBack = try c.decodeIfPresent(Bool.self, forKey: .allowJoinBack)
        allowMoveAuto = try c.decodeIfPresent(Bool.self, forKey: .allowMoveAuto)
        // Managers ride heterogeneous JSON: keep the raw array text.
        if let raw = try? c.decode([LosslessAnyJSON].self, forKey: .managersJSON),
           let data = try? JSONEncoder().encode(raw) {
            managersJSON = String(decoding: data, as: UTF8.self)
        } else {
            managersJSON = "[]"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(allowChoose, forKey: .allowChoose)
        try c.encodeIfPresent(roomDuration, forKey: .roomDuration)
        try c.encodeIfPresent(allowJoinBack, forKey: .allowJoinBack)
        try c.encodeIfPresent(allowMoveAuto, forKey: .allowMoveAuto)
        let raw = (try? JSONDecoder().decode([LosslessAnyJSON].self, from: Data(managersJSON.utf8))) ?? []
        try c.encode(raw, forKey: .managersJSON)
    }

    public init(allowChoose: Bool? = nil, roomDuration: String? = nil,
                allowJoinBack: Bool? = nil, allowMoveAuto: Bool? = nil,
                managersJSON: String = "[]") {
        self.allowChoose = allowChoose
        self.roomDuration = roomDuration
        self.allowJoinBack = allowJoinBack
        self.allowMoveAuto = allowMoveAuto
        self.managersJSON = managersJSON
    }
}

/// Faithful lenient JSON value (settings managers passthrough:
/// decode + re-encode must not corrupt the organizer's list).
public indirect enum LosslessAnyJSON: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null
    case array([LosslessAnyJSON])
    case object([String: LosslessAnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) { self = .number(n) } else if (try? c.decodeNil()) == true {
            self = .null
        } else if let a = try? c.decode([LosslessAnyJSON].self) { self = .array(a) } else if let o = try? c.decode([String: LosslessAnyJSON].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case .null: try c.encodeNil()
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

/// One assignable user (core assignee JSON).
public struct LiveBreakoutAssignee: Codable, Sendable, Equatable {
    public var email: String?
    public var mri: String?
    public var membership: String?

    public init(email: String? = nil, mri: String? = nil, membership: String? = nil) {
        self.email = email
        self.mri = mri
        self.membership = membership
    }
}

/// The reads/writes behind the live rooms sheet. Blocking; called off-main.
public protocol LiveBreakoutTransport: Sendable {
    func list(coords: BreakoutCoords) throws -> [LiveBreakoutRoom]
    func create(coords: BreakoutCoords, count: Int, preconfigurationJSON: String,
                settingsJSON: String?) throws -> [LiveBreakoutRoom]
    func addRoom(coords: BreakoutCoords, name: String, participantsJSON: String) throws -> LiveBreakoutRoom
    func updateRoom(coords: BreakoutCoords, name: String, participantsJSON: String,
                    restrictChat: Bool) throws -> LiveBreakoutRoom
    func deleteRoom(coords: BreakoutCoords) throws
    func deleteAll(coords: BreakoutCoords) throws
    func assign(coords: BreakoutCoords, roomsJSON: String, total: Int?) throws -> [LiveBreakoutRoom]
    func openRooms(coords: BreakoutCoords, roomsJSON: String, newTimerFlow: Bool,
                   total: Int?) throws
    func closeRooms(coords: BreakoutCoords, roomsJSON: String, total: Int?) throws
    func getSettings(coords: BreakoutCoords) throws -> LiveBreakoutSettings
    func putSettings(coords: BreakoutCoords, settingsJSON: String) throws -> LiveBreakoutSettings
    func assignees(coords: BreakoutCoords) throws -> [LiveBreakoutAssignee]
    func announce(coords: BreakoutCoords, roomThreadIDs: [String], message: String) throws
}

/// Live transport: core FFI dispatcher (`ostmac_breakout_call`).
/// Failures throw with the core's detail — the store words auth
/// failures as the disabled reason.
public struct CoreLiveBreakoutTransport: LiveBreakoutTransport {
    public init() {}

    struct RoomsResponse: Decodable {
        let ok: Bool
        let rooms: [LiveBreakoutRoom]?
    }
    struct RoomResponse: Decodable {
        let ok: Bool
        let room: LiveBreakoutRoom?
    }
    struct SettingsResponse: Decodable {
        let ok: Bool
        let settings: LiveBreakoutSettings?
    }
    struct AssigneesResponse: Decodable {
        let ok: Bool
        let assignees: [LiveBreakoutAssignee]?
    }
    struct AckResponse: Decodable {
        let ok: Bool
    }

    private func argsData(_ build: (inout [String: Any]) -> Void) -> String {
        var o: [String: Any] = [:]
        build(&o)
        let data = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func fragment(_ json: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? []
    }

    private func call<R: Decodable>(op: String, coords: BreakoutCoords, args: String, as: R.Type) throws -> R {
        try op.withCString { o in
            try coords.jsonString.withCString { c in
                try args.withCString { a in
                    try RustCore.call(ostmac_breakout_call(o, c, a), as: R.self)
                }
            }
        }
    }

    public func list(coords: BreakoutCoords) throws -> [LiveBreakoutRoom] {
        let r: RoomsResponse = try call(op: "list", coords: coords, args: "{}", as: RoomsResponse.self)
        guard r.ok, let rooms = r.rooms else { throw CoreCallError.failed("rooms read failed") }
        return rooms
    }

    public func create(coords: BreakoutCoords, count: Int, preconfigurationJSON: String,
                       settingsJSON: String?) throws -> [LiveBreakoutRoom] {
        let args = argsData {
            $0["count"] = count
            $0["preconfiguration"] = fragment(preconfigurationJSON)
            if let s = settingsJSON { $0["settings"] = fragment(s) }
        }
        let r: RoomsResponse = try call(op: "create", coords: coords, args: args, as: RoomsResponse.self)
        guard r.ok, let rooms = r.rooms else { throw CoreCallError.failed("rooms create failed") }
        return rooms
    }

    public func addRoom(coords: BreakoutCoords, name: String, participantsJSON: String) throws -> LiveBreakoutRoom {
        let args = argsData {
            $0["name"] = name
            $0["participants"] = fragment(participantsJSON)
        }
        let r: RoomResponse = try call(op: "add", coords: coords, args: args, as: RoomResponse.self)
        guard r.ok, let room = r.room else { throw CoreCallError.failed("room add failed") }
        return room
    }

    public func updateRoom(coords: BreakoutCoords, name: String, participantsJSON: String,
                           restrictChat: Bool) throws -> LiveBreakoutRoom {
        let args = argsData {
            $0["name"] = name
            $0["participants"] = fragment(participantsJSON)
            $0["restrict_chat_access"] = restrictChat
        }
        let r: RoomResponse = try call(op: "update", coords: coords, args: args, as: RoomResponse.self)
        guard r.ok, let room = r.room else { throw CoreCallError.failed("room update failed") }
        return room
    }

    public func deleteRoom(coords: BreakoutCoords) throws {
        let r: AckResponse = try call(op: "delete", coords: coords, args: "{}", as: AckResponse.self)
        guard r.ok else { throw CoreCallError.failed("room delete failed") }
    }

    public func deleteAll(coords: BreakoutCoords) throws {
        let r: AckResponse = try call(op: "delete-all", coords: coords, args: "{}", as: AckResponse.self)
        guard r.ok else { throw CoreCallError.failed("rooms delete failed") }
    }

    public func assign(coords: BreakoutCoords, roomsJSON: String, total: Int?) throws -> [LiveBreakoutRoom] {
        let args = argsData {
            $0["rooms"] = fragment(roomsJSON)
            if let t = total { $0["total_participants"] = t }
        }
        let r: RoomsResponse = try call(op: "assign", coords: coords, args: args, as: RoomsResponse.self)
        guard r.ok, let rooms = r.rooms else { throw CoreCallError.failed("rooms assign failed") }
        return rooms
    }

    public func openRooms(coords: BreakoutCoords, roomsJSON: String, newTimerFlow: Bool,
                          total: Int?) throws {
        let args = argsData {
            $0["rooms"] = fragment(roomsJSON)
            $0["new_timer_flow"] = newTimerFlow
            if let t = total { $0["total_participants"] = t }
        }
        let r: AckResponse = try call(op: "open", coords: coords, args: args, as: AckResponse.self)
        guard r.ok else { throw CoreCallError.failed("rooms open failed") }
    }

    public func closeRooms(coords: BreakoutCoords, roomsJSON: String, total: Int?) throws {
        let args = argsData {
            $0["rooms"] = fragment(roomsJSON)
            if let t = total { $0["total_participants"] = t }
        }
        let r: AckResponse = try call(op: "close", coords: coords, args: args, as: AckResponse.self)
        guard r.ok else { throw CoreCallError.failed("rooms close failed") }
    }

    public func getSettings(coords: BreakoutCoords) throws -> LiveBreakoutSettings {
        let r: SettingsResponse = try call(op: "get-settings", coords: coords, args: "{}",
                                           as: SettingsResponse.self)
        guard r.ok, let s = r.settings else { throw CoreCallError.failed("settings read failed") }
        return s
    }

    public func putSettings(coords: BreakoutCoords, settingsJSON: String) throws -> LiveBreakoutSettings {
        let args = argsData { $0["settings"] = fragment(settingsJSON) }
        let r: SettingsResponse = try call(op: "put-settings", coords: coords, args: args,
                                           as: SettingsResponse.self)
        guard r.ok, let s = r.settings else { throw CoreCallError.failed("settings write failed") }
        return s
    }

    public func assignees(coords: BreakoutCoords) throws -> [LiveBreakoutAssignee] {
        let r: AssigneesResponse = try call(op: "assignees", coords: coords, args: "{}",
                                            as: AssigneesResponse.self)
        guard r.ok, let list = r.assignees else { throw CoreCallError.failed("assignees read failed") }
        return list
    }

    public func announce(coords: BreakoutCoords, roomThreadIDs: [String], message: String) throws {
        let args = argsData {
            $0["room_thread_ids"] = roomThreadIDs
            $0["message"] = message
        }
        let r: AckResponse = try call(op: "announce", coords: coords, args: args, as: AckResponse.self)
        guard r.ok else { throw CoreCallError.failed("announce failed") }
    }
}

/// Pure request preview (`ostmac_breakout_request`, no network): the
/// exact method + URL + body an op would send. Tests pin the Swift→core
/// wiring through it.
public enum BreakoutRequestPreview {
    public struct Preview: Decodable {
        public let ok: Bool
        public let op: String?
        public let method: String?
        public let url: String?
    }

    public static func preview(op: String, coords: BreakoutCoords, argsJSON: String) throws -> Preview {
        try op.withCString { o in
            try coords.jsonString.withCString { c in
                try argsJSON.withCString { a in
                    try RustCore.call(ostmac_breakout_request(o, c, a), as: Preview.self)
                }
            }
        }
    }
}

/// Demo transport: an in-memory rooms plan answering the full op set
/// (tests + captures + evidence seeds). Lock-guarded: the store calls
/// it from blocking-task threads.
public final class DemoLiveBreakoutTransport: LiveBreakoutTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [LiveBreakoutRoom]
    private var settings: LiveBreakoutSettings
    private var announced: [(threads: [String], message: String)] = []

    public init(rooms: [LiveBreakoutRoom] = [], settings: LiveBreakoutSettings = LiveBreakoutSettings()) {
        self.rooms = rooms
        self.settings = settings
    }

    /// Deterministic 4-room plan over fixture coords (captures + tests).
    public static func seeded() -> DemoLiveBreakoutTransport {
        let mk = { (i: Int) -> LiveBreakoutRoom in
            LiveBreakoutRoom(
                roomName: "Room \(i)",
                coordinates: BreakoutCoords(
                    tenantID: "demo-tenant", organizerID: "demo-organizer",
                    threadID: "19:demo_room\(i)@thread.v2", messageID: String(i)),
                participants: [], restrictChatAccess: false, isOpened: false)
        }
        return DemoLiveBreakoutTransport(rooms: [mk(1), mk(2), mk(3), mk(4)])
    }

    private func withRooms<T>(_ f: (inout [LiveBreakoutRoom]) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try f(&rooms)
    }

    public func announceLog() -> [(threads: [String], message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return announced
    }

    public func list(coords _: BreakoutCoords) throws -> [LiveBreakoutRoom] {
        withRooms { $0 }
    }

    public func create(coords: BreakoutCoords, count: Int, preconfigurationJSON _: String,
                       settingsJSON _: String?) throws -> [LiveBreakoutRoom] {
        let n = min(max(1, count), 50)
        return withRooms { rooms in
            rooms = (1...n).map { i in
                LiveBreakoutRoom(
                    roomName: "Room \(i)",
                    coordinates: BreakoutCoords(
                        tenantID: coords.tenantID, organizerID: coords.organizerID,
                        threadID: "19:demo_room\(i)@thread.v2", messageID: String(i)))
            }
            return rooms
        }
    }

    public func addRoom(coords: BreakoutCoords, name: String,
                        participantsJSON _: String) throws -> LiveBreakoutRoom {
        withRooms { rooms in
            let room = LiveBreakoutRoom(
                roomName: name,
                coordinates: BreakoutCoords(
                    tenantID: coords.tenantID, organizerID: coords.organizerID,
                    threadID: "19:demo_added\(rooms.count + 1)@thread.v2",
                    messageID: String(rooms.count + 1)))
            rooms.append(room)
            return room
        }
    }

    public func updateRoom(coords: BreakoutCoords, name: String, participantsJSON: String,
                           restrictChat: Bool) throws -> LiveBreakoutRoom {
        let parts = decodeParts(participantsJSON)
        return try withRooms { rooms in
            guard let i = rooms.firstIndex(where: { $0.coordinates?.threadID == coords.threadID }) else {
                throw CoreCallError.failed("room update failed")
            }
            rooms[i].roomName = name
            rooms[i].participants = parts
            rooms[i].restrictChatAccess = restrictChat
            return rooms[i]
        }
    }

    public func deleteRoom(coords: BreakoutCoords) throws {
        withRooms { $0.removeAll { $0.coordinates?.threadID == coords.threadID } }
    }

    public func deleteAll(coords _: BreakoutCoords) throws {
        withRooms { $0 = [] }
    }

    public func assign(coords _: BreakoutCoords, roomsJSON _: String,
                       total _: Int?) throws -> [LiveBreakoutRoom] {
        withRooms { $0 }
    }

    public func openRooms(coords _: BreakoutCoords, roomsJSON: String, newTimerFlow _: Bool,
                          total _: Int?) throws {
        let threads = decodeThreads(roomsJSON)
        withRooms { rooms in
            for i in rooms.indices where threads.contains(rooms[i].coordinates?.threadID ?? "") {
                rooms[i].isOpened = true
            }
        }
    }

    public func closeRooms(coords _: BreakoutCoords, roomsJSON: String, total _: Int?) throws {
        let threads = decodeThreads(roomsJSON)
        withRooms { rooms in
            for i in rooms.indices where threads.contains(rooms[i].coordinates?.threadID ?? "") {
                rooms[i].isOpened = false
            }
        }
    }

    public func getSettings(coords _: BreakoutCoords) throws -> LiveBreakoutSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func putSettings(coords _: BreakoutCoords, settingsJSON: String) throws -> LiveBreakoutSettings {
        lock.lock()
        defer { lock.unlock() }
        if let data = settingsJSON.data(using: .utf8),
           let v = try? JSONDecoder().decode(LiveBreakoutSettings.self, from: data) {
            // Managers echo: a write naming none keeps the stored list.
            var next = v
            if next.managersJSON == "[]" { next.managersJSON = settings.managersJSON }
            settings = next
        }
        return settings
    }

    public func assignees(coords _: BreakoutCoords) throws -> [LiveBreakoutAssignee] {
        MeetingDemoRoster.assignees
    }

    public func announce(coords _: BreakoutCoords, roomThreadIDs: [String], message: String) throws {
        lock.lock()
        defer { lock.unlock() }
        announced.append((roomThreadIDs, message))
    }

    private func decodeParts(_ json: String) -> [LiveBreakoutParticipant] {
        (try? JSONDecoder().decode([LiveBreakoutParticipant].self, from: Data(json.utf8))) ?? []
    }

    private func decodeThreads(_ json: String) -> [String] {
        struct C: Decodable {
            let threadID: String?
            let thread_id: String?
        }
        return ((try? JSONDecoder().decode([C].self, from: Data(json.utf8))) ?? [])
            .compactMap { $0.threadID ?? $0.thread_id }
    }
}

/// Demo assignees matching the evidence roster (`CallEvidence.roster`,
/// same MRIs, so the demo assign flow resolves names exactly like
/// live).
public enum MeetingDemoRoster {
    public static let assignees: [LiveBreakoutAssignee] = [
        LiveBreakoutAssignee(email: "ava.lindqvist@example.com", mri: "8:orgid:ava",
                             membership: "member"),
        LiveBreakoutAssignee(email: "hannah.clarke@example.com", mri: "8:orgid:hannah",
                             membership: "member"),
        LiveBreakoutAssignee(email: "tom.becker@example.com", mri: "8:orgid:tom",
                             membership: "member"),
        LiveBreakoutAssignee(email: "megan.harper@example.com", mri: "8:orgid:megan",
                             membership: "member"),
    ]
}

/// One meeting's LIVE rooms, over MiddleTier REST. Main-actor
/// (SwiftUI-owned). Every mutation round-trips the server and reloads
/// the list: the UI never shows a write the server refused.
@MainActor
public final class LiveBreakoutRoomsStore: ObservableObject {
    public static let maxRooms = 50
    public static let defaultCount = 4

    @Published public private(set) var rooms: [LiveBreakoutRoom] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var working = false
    @Published public private(set) var settings: LiveBreakoutSettings?
    @Published public private(set) var assignees: [LiveBreakoutAssignee] = []
    /// Organizer/manager gate (MT refuses writes from anyone else; the
    /// refusal surfaces as an error and the sheet stays honest).
    @Published public var canManage = true

    public let coords: BreakoutCoords
    private let transport: any LiveBreakoutTransport
    private var started = false

    public init(coords: BreakoutCoords, transport: any LiveBreakoutTransport) {
        self.coords = coords
        self.transport = transport
    }

    /// A plan exists server-side (rooms were created and not ended).
    public var isActive: Bool { !rooms.isEmpty }

    public var openCount: Int { rooms.filter(\.isOpened).count }

    public func room(for participantID: String) -> LiveBreakoutRoom? {
        rooms.first { $0.participants.contains { $0.matches(rosterID: participantID) } }
    }

    public func room(id: String) -> LiveBreakoutRoom? {
        rooms.first { $0.id == id }
    }

    /// Roster ids with no room.
    public func unassigned(rosterIDs: [String]) -> [String] {
        rosterIDs.filter { room(for: $0) == nil }
    }

    /// First paint: rooms + settings + assignees.
    public func load() {
        guard !started else { return }
        started = true
        loading = true
        error = nil
        let c = coords
        let t = transport
        Task {
            let next = await Task.blocking {
                Result { (try t.list(coords: c), try t.getSettings(coords: c), try t.assignees(coords: c)) }
            }.value
            self.loading = false
            switch next {
            case let .success((rooms, settings, assignees)):
                self.rooms = rooms
                self.settings = settings
                self.assignees = assignees
            case let .failure(e):
                self.error = Self.word(e)
            }
        }
    }

    public func reload() {
        loading = true
        error = nil
        let c = coords
        let t = transport
        Task {
            let next = await Task.blocking { Result { try t.list(coords: c) } }.value
            self.loading = false
            switch next {
            case let .success(rooms): self.rooms = rooms
            case let .failure(e): self.error = Self.word(e)
            }
        }
    }

    /// Run a write, then reload the list (the server is the truth).
    private func write(_ what: String, _ f: @escaping (any LiveBreakoutTransport, BreakoutCoords) throws -> Void) {
        working = true
        error = nil
        let c = coords
        let t = transport
        Task {
            let next = await Task.blocking {
                Result {
                    try f(t, c)
                    return try t.list(coords: c)
                }
            }.value
            self.working = false
            switch next {
            case let .success(rooms): self.rooms = rooms
            case let .failure(e): self.error = Self.word(e, what: what)
            }
        }
    }

    /// Create the plan (count clamps to 1...maxRooms). Automatic deals
    /// roster seats round-robin into the preconfiguration; manual sends
    /// empty rooms.
    public func create(count: Int, mode: BreakoutAssignMode, roster: [MeetingParticipant]) {
        let n = min(max(1, count), Self.maxRooms)
        var pre: [[String: Any]] = (1...n).map { ["roomName": "Room \($0)", "participants": []] }
        if mode == .automatic, !roster.isEmpty {
            for (i, p) in roster.enumerated() {
                var list = pre[i % n]["participants"] as? [[String: String]] ?? []
                list.append(wireParticipant(for: p))
                pre[i % n]["participants"] = list
            }
        }
        let preJSON = jsonString(pre)
        write("create") { t, c in
            let rooms = try t.create(coords: c, count: n, preconfigurationJSON: preJSON, settingsJSON: nil)
            // The demo transport ignores preconfiguration bodies;
            // adopt its answer either way (live returns the real plan).
            _ = rooms
        }
    }

    /// Assign (or move) one roster seat to a room (full-roster PUT).
    public func assign(_ participant: MeetingParticipant, to roomID: String) {
        guard let target = room(id: roomID), let targetCoords = target.coordinates else {
            error = "That room has no Teams coordinates yet — reload and try again."
            return
        }
        var parts = target.participants
        if !parts.contains(where: { $0.matches(rosterID: participant.id) }) {
            let wire = wireParticipant(for: participant)
            parts.append(LiveBreakoutParticipant(mri: wire["mri"], upn: wire["upn"]))
        }
        let body = jsonString(parts.map { Self.wireDict($0) })
        let name = target.roomName
        // Seats are single-homed: pull the seat from every other room first.
        let others = rooms.filter { $0.id != roomID && $0.room(for: participant.id) }
        write("assign") { t, _ in
            for other in others {
                guard let oc = other.coordinates else { continue }
                let rest = other.participants.filter { !$0.matches(rosterID: participant.id) }
                let restJSON = Self.jsonStringStatic(rest.map { Self.wireDict($0) })
                _ = try t.updateRoom(coords: oc, name: other.roomName, participantsJSON: restJSON,
                                     restrictChat: other.restrictChatAccess)
            }
            _ = try t.updateRoom(coords: targetCoords, name: name, participantsJSON: body,
                                 restrictChat: target.restrictChatAccess)
        }
    }

    /// Remove one seat from whatever room holds it (full-roster PUT).
    public func unassign(_ participantID: String) {
        guard let holder = room(for: participantID), let hc = holder.coordinates else { return }
        let rest = holder.participants.filter { !$0.matches(rosterID: participantID) }
        let body = jsonString(rest.map { Self.wireDict($0) })
        let name = holder.roomName
        write("remove") { t, _ in
            _ = try t.updateRoom(coords: hc, name: name, participantsJSON: body,
                                 restrictChat: holder.restrictChatAccess)
        }
    }

    /// Open/close one room.
    public func setOpen(_ roomID: String, _ open: Bool) {
        guard let target = room(id: roomID), let rc = target.coordinates else {
            error = "That room has no Teams coordinates yet — reload and try again."
            return
        }
        let one = "[\(rc.jsonString)]"
        let total = rooms.reduce(0) { $0 + $1.participants.count }
        if open {
            write("open") { t, c in try t.openRooms(coords: c, roomsJSON: one, newTimerFlow: false, total: total) }
        } else {
            write("close") { t, c in try t.closeRooms(coords: c, roomsJSON: one, total: total) }
        }
    }

    public func openAll() {
        let all = Self.coordsArrayString(rooms.compactMap(\.coordinates))
        let total = rooms.reduce(0) { $0 + $1.participants.count }
        write("open") { t, c in try t.openRooms(coords: c, roomsJSON: all, newTimerFlow: false, total: total) }
    }

    public func closeAll() {
        let all = Self.coordsArrayString(rooms.compactMap(\.coordinates))
        let total = rooms.reduce(0) { $0 + $1.participants.count }
        write("close") { t, c in try t.closeRooms(coords: c, roomsJSON: all, total: total) }
    }

    /// End rooms server-side (delete-all), then clear local state.
    public func reset() {
        write("end") { t, c in try t.deleteAll(coords: c) }
    }

    /// Save the two organizer-facing settings (choose-room + duration);
    /// managers echo back untouched.
    public func saveSettings(allowChoose: Bool?, roomDuration: String?) {
        let managers = settings?.managersJSON ?? "[]"
        var o: [String: Any] = [:]
        if let v = allowChoose { o["allow_users_to_select_breakout_room"] = v }
        if let d = roomDuration, !d.isEmpty { o["room_duration"] = d }
        o["managers"] = (try? JSONSerialization.jsonObject(with: Data(managers.utf8))) ?? []
        if let join = settings?.allowJoinBack { o["allow_join_back_to_main_meeting"] = join }
        if let move = settings?.allowMoveAuto { o["allow_move_participants_automatically"] = move }
        let body = jsonString(o)
        working = true
        error = nil
        let c = coords
        let t = transport
        Task {
            let next = await Task.blocking { Result { try t.putSettings(coords: c, settingsJSON: body) } }.value
            self.working = false
            switch next {
            case let .success(s): self.settings = s
            case let .failure(e): self.error = Self.word(e, what: "settings")
            }
        }
    }

    /// Announce a message into rooms (thread ids; empty = all rooms is
    /// NOT sent — the caller names rooms).
    public func announce(_ message: String, roomIDs: [String]) {
        let threads = roomIDs.compactMap { room(id: $0)?.coordinates?.threadID }
        guard !threads.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        error = nil
        let c = coords
        let t = transport
        Task {
            let next = await Task.blocking {
                Result { try t.announce(coords: c, roomThreadIDs: threads, message: message) }
            }.value
            self.working = false
            if case let .failure(e) = next { self.error = Self.word(e, what: "announce") }
        }
    }

    // MARK: - participant mapping

    /// The wire participant for a roster seat: the assignee record when
    /// one matches (mri/email), else the raw roster id as mri (the
    /// core's P() fills what it can; the server decides the rest).
    /// Pure over the loaded assignees, so tests pin it.
    public func wireParticipant(for p: MeetingParticipant) -> [String: String] {
        if let hit = assignees.first(where: { $0.mri == p.id || $0.email == p.id }) {
            var o: [String: String] = [:]
            if let m = hit.mri { o["mri"] = m }
            if let e = hit.email { o["upn"] = e }
            return o
        }
        return ["mri": p.id]
    }

    private func jsonString(_ o: Any) -> String {
        Self.jsonStringStatic(o)
    }

    private static func jsonStringStatic(_ o: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// Participant write dict with nils dropped (JSONSerialization
    /// rejects nil values; the core fills gaps per the P() map).
    private static func wireDict(_ p: LiveBreakoutParticipant) -> [String: String] {
        var o: [String: String] = [:]
        if let m = p.mri { o["mri"] = m }
        if let u = p.upn { o["upn"] = u }
        if let id = p.objectID { o["objectId"] = id }
        return o
    }

    /// Coords array JSON (Codable structs need the encoder, not
    /// JSONSerialization).
    private static func coordsArrayString(_ coords: [BreakoutCoords]) -> String {
        String(decoding: (try? JSONEncoder().encode(coords)) ?? Data("[]".utf8), as: UTF8.self)
    }

    // MARK: - error wording

    /// Auth failures read as the disabled reason; writes name their verb.
    /// Pure.
    nonisolated static func word(_ error: Error, what: String? = nil) -> String {
        let raw: String
        if case CoreCallError.failed(let m) = error { raw = m } else { raw = String(describing: error) }
        if raw.contains("401") || raw.localizedCaseInsensitiveContains("no aad token") {
            return "Sign in to manage live breakout rooms."
        }
        if raw.contains("403") {
            return "Teams refused: only the organizer or a rooms manager can do that."
        }
        if let w = what { return "Couldn't \(w) the live rooms (\(raw))." }
        return "Couldn't load the live rooms (\(raw))."
    }
}

// MARK: - room seat lookup (tests + store)

private extension LiveBreakoutRoom {
    func room(for participantID: String) -> Bool {
        participants.contains { $0.matches(rosterID: participantID) }
    }
}
