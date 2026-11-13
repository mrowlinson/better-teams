// MeetingLobby.swift — organizer side of the meeting lobby (MEETFIX-B).
//
// The core's roster lists people waiting in the lobby apart from the
// call (`ostmac_call_roster` → `lobby`). `MeetingLobbyModel` keeps that
// list for the call's People inspector, reports new arrivals (the app
// posts a "<name> is waiting in the lobby" banner with Admit), and sends
// Admit / Admit All / Deny through the core (`ostmac_call_lobby_*`,
// blocking network → off the main actor). Only organizer / presenter
// joins get the admit links; an attendee's attempt fails with `no_link`.
import COstMac
import Foundation
import UserNotifications

/// One person waiting in the meeting lobby (`ostmac_call_roster` `lobby`).
public struct CallLobbyParticipant: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Row / banner name ("Guest" when the roster gave none).
    public var displayName: String { name.isEmpty ? "Guest" : name }
}

struct LobbyActionResult: Decodable { let ok: Bool }

/// Lobby control seam: the core in the app, a fake in tests.
public protocol MeetingLobbyControl: Sendable {
    func admit(id: String, name: String) throws
    func admitAll() throws
    func deny(id: String, name: String) throws
}

/// The core's lobby control (blocks on the network; call off-main).
public struct RustLobbyControl: MeetingLobbyControl {
    public init() {}
    public func admit(id: String, name: String) throws { _ = try RustCore.callLobbyAdmit(id: id, name: name) }
    public func admitAll() throws { _ = try RustCore.callLobbyAdmitAll() }
    public func deny(id: String, name: String) throws { _ = try RustCore.callLobbyDeny(id: id, name: name) }
}

extension RustCore {
    static func callLobbyAdmit(id: String, name: String) throws -> LobbyActionResult {
        try id.withCString { i in
            try name.withCString { n in try call(ostmac_call_lobby_admit(i, n), as: LobbyActionResult.self) }
        }
    }

    static func callLobbyAdmitAll() throws -> LobbyActionResult {
        try call(ostmac_call_lobby_admit_all(), as: LobbyActionResult.self)
    }

    static func callLobbyDeny(id: String, name: String) throws -> LobbyActionResult {
        try id.withCString { i in
            try name.withCString { n in try call(ostmac_call_lobby_deny(i, n), as: LobbyActionResult.self) }
        }
    }
}

/// Lobby list + admit/deny for the active meeting call (main actor).
@MainActor
public final class MeetingLobbyModel: ObservableObject {
    /// Waiting people, roster order.
    @Published public private(set) var waiting: [CallLobbyParticipant] = []
    /// Ids with an Admit / Deny in flight (their buttons disable).
    @Published public private(set) var pending: Set<String> = []
    /// Last failed action (cleared by the next success).
    @Published public private(set) var lastError: String?
    /// New arrival (not seen before this call): the app posts the banner.
    public var onArrival: ((CallLobbyParticipant) -> Void)?
    private var seen: Set<String> = []
    private let control: MeetingLobbyControl

    public init(control: MeetingLobbyControl = RustLobbyControl()) {
        self.control = control
    }

    /// One roster poll's lobby list.
    public func update(_ list: [CallLobbyParticipant]) {
        if list != waiting { waiting = list }
        let ids = Set(list.map(\.id))
        pending.formIntersection(ids)
        for p in list where !seen.contains(p.id) {
            seen.insert(p.id)
            onArrival?(p)
        }
        // Someone who left and waits again announces again.
        seen.formIntersection(ids)
    }

    public func admit(_ p: CallLobbyParticipant) async {
        await run(ids: [p.id]) { c in try c.admit(id: p.id, name: p.name) }
    }

    public func deny(_ p: CallLobbyParticipant) async {
        await run(ids: [p.id]) { c in try c.deny(id: p.id, name: p.name) }
    }

    public func admitAll() async {
        await run(ids: waiting.map(\.id)) { c in try c.admitAll() }
    }

    /// Admit by id (the banner's Admit action); unknown ids are ignored.
    public func admit(id: String) async {
        guard let p = waiting.first(where: { $0.id == id }) else { return }
        await admit(p)
    }

    private func run(ids: [String], _ op: @escaping @Sendable (MeetingLobbyControl) throws -> Void) async {
        guard !ids.isEmpty else { return }
        pending.formUnion(ids)
        let control = self.control
        let result: Result<Void, Error> = await Task.blocking { Result { try op(control) } }.value
        switch result {
        case .success:
            lastError = nil
        case .failure(let e):
            // Failed: the row stays and its buttons come back.
            pending.subtract(ids)
            lastError = String(describing: e)
        }
    }
}

/// LOBBY banner: "<name> is waiting in the lobby" with Admit (and a
/// click that shows the call). Pure builders; the app posts them.
public enum MeetingLobbyInfo {
    public static let categoryID = "OM_LOBBY"
    public static let admitActionID = "OM_LOBBY_ADMIT"
    public static let admitTitle = "Admit"
    public static let participantIDKey = "OMLobbyParticipantID"

    public static func requestID(participantID: String) -> String { "lobby-\(participantID)" }

    public static var category: UNNotificationCategory {
        let admit = UNNotificationAction(identifier: admitActionID, title: admitTitle, options: [])
        return UNNotificationCategory(identifier: categoryID, actions: [admit], intentIdentifiers: [], options: [])
    }

    public static func title(for p: CallLobbyParticipant) -> String {
        "\(p.displayName) is waiting in the lobby"
    }

    public static func makeContent(_ p: CallLobbyParticipant) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title(for: p)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = categoryID
        content.threadIdentifier = "lobby"
        content.userInfo = [participantIDKey: p.id]
        return content
    }
}
