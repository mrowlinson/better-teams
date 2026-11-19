// BreakoutRoomsStore.swift — per-meeting breakout rooms (BREAKOUT).
// Teams parity, behavior only: create rooms, assign participants,
// open/close rooms, with state display. There is no public Graph API
// for rooms management (rooms are organizer/manager-driven in the
// Teams client): this store is the local room plan + open/close state
// over the meeting roster, with zero network writes. Rooms die with
// the call (the owning CallSession holds the store).
import Combine
import Foundation

/// One breakout room: stable id, display name, open state, assignees
/// in assignment order.
public struct BreakoutRoom: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var isOpen: Bool
    public var assigneeIDs: [String]

    public init(id: String, name: String, isOpen: Bool = false, assigneeIDs: [String] = []) {
        self.id = id
        self.name = name
        self.isOpen = isOpen
        self.assigneeIDs = assigneeIDs
    }
}

/// How new rooms get their first assignees.
public enum BreakoutAssignMode: String, Sendable, CaseIterable {
    case automatic
    case manual

    public var title: String {
        switch self {
        case .automatic: return "Assign automatically"
        case .manual: return "Assign manually"
        }
    }
}

/// Per-meeting room plan. Main-actor (SwiftUI-owned), like
/// MeetingRosterStore. All mutations are local; nothing here touches
/// the network (server-side rooms stay Teams-client-driven).
@MainActor
public final class BreakoutRoomsStore: ObservableObject {
    /// Teams cap: at most 50 rooms per meeting.
    public static let maxRooms = 50
    public static let defaultCount = 4

    /// Rooms in creation order; empty while no plan exists.
    @Published public private(set) var rooms: [BreakoutRoom] = []
    /// Organizer/manager gate (Teams only lets the organizer or an
    /// appointed manager run rooms). The session sets it; the sheet
    /// disables management while false.
    @Published public var canManage = true

    public nonisolated init() {}

    /// A plan exists (rooms were created and not ended).
    public var isActive: Bool { !rooms.isEmpty }

    /// Open rooms (the ones participants are in).
    public var openCount: Int { rooms.filter({ $0.isOpen }).count }

    /// Room holding a participant, if any.
    public func room(for participantID: String) -> BreakoutRoom? {
        rooms.first { $0.assigneeIDs.contains(participantID) }
    }

    /// Roster ids with no room (display derives this from the live
    /// roster, so leaves need no pruning here).
    public func unassigned(rosterIDs: [String]) -> [String] {
        let placed = Set(rooms.flatMap({ $0.assigneeIDs }))
        return rosterIDs.filter { !placed.contains($0) }
    }

    /// Create the plan, replacing any existing one. Count clamps to
    /// 1...maxRooms. Automatic deals roster ids round-robin; manual
    /// leaves everyone unassigned.
    public func create(count: Int, mode: BreakoutAssignMode, rosterIDs: [String] = []) {
        let n = min(max(1, count), Self.maxRooms)
        var fresh: [BreakoutRoom] = []
        for i in 1...n {
            fresh.append(BreakoutRoom(id: "room-" + String(i), name: "Room " + String(i)))
        }
        if mode == .automatic, !rosterIDs.isEmpty {
            for (i, pid) in rosterIDs.enumerated() {
                fresh[i % n].assigneeIDs.append(pid)
            }
        }
        rooms = fresh
    }

    /// Assign (or move) a participant to a room. Unknown rooms and
    /// blank ids are ignored.
    public func assign(_ participantID: String, to roomID: String) {
        let pid = participantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty, rooms.contains(where: { $0.id == roomID }) else { return }
        for i in rooms.indices {
            rooms[i].assigneeIDs.removeAll { $0 == pid }
            if rooms[i].id == roomID { rooms[i].assigneeIDs.append(pid) }
        }
    }

    /// Remove a participant from whatever room holds them.
    public func unassign(_ participantID: String) {
        for i in rooms.indices {
            rooms[i].assigneeIDs.removeAll { $0 == participantID }
        }
    }

    /// Open/close one room. Unknown ids are ignored.
    public func setOpen(_ roomID: String, _ open: Bool) {
        for i in rooms.indices where rooms[i].id == roomID {
            rooms[i].isOpen = open
        }
    }

    public func openAll() {
        for i in rooms.indices { rooms[i].isOpen = true }
    }

    public func closeAll() {
        for i in rooms.indices { rooms[i].isOpen = false }
    }

    /// End rooms: the plan is gone (call end uses the same path).
    public func reset() {
        rooms = []
    }
}
