// MeetingAttendance.swift — MEETINGS-PLUS: one online meeting's
// attendance report, read the way Teams reads it.
//
// Graph: `GET /me/onlineMeetings/{id}/attendanceReports` (first report)
// then `GET …/{reportId}/attendanceRecords` (scope `OnlineMeetings.Read`,
// NOT granted to the Teams token — live reads 403; the store surfaces
// the live-disabled reason instead of an empty list). FAIL≠ABSENCE: a
// failed read is `failed` (401/403 name the cause); an empty report is
// `empty` only after a read SUCCEEDED and found no rows.
import COstMac
import Combine
import Foundation

/// One attendee's presence in the report.
public struct AttendanceEntry: Codable, Sendable, Equatable, Identifiable {
    public let displayName: String
    public let role: String
    public let joinDT: String?
    public let leaveDT: String?
    public let durationSecs: UInt64

    public var id: String { "\(displayName)◊\(joinDT ?? "?")" }

    public init(displayName: String, role: String, joinDT: String? = nil,
                leaveDT: String? = nil, durationSecs: UInt64 = 0) {
        self.displayName = displayName
        self.role = role
        self.joinDT = joinDT
        self.leaveDT = leaveDT
        self.durationSecs = durationSecs
    }

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case role, joinDT = "join_dt", leaveDT = "leave_dt", durationSecs = "duration_secs"
    }

    /// "0:43", "12:05", "1:02:03" (hours only when non-zero).
    public var durationLabel: String { Self.durationLabel(durationSecs) }

    public static func durationLabel(_ secs: UInt64) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "2:00 PM – 2:30 PM" or fallback when the server names no times.
    public var spanLabel: String {
        switch (joinDT, leaveDT) {
        case let (j?, l?): "\(Self.clock(j)) – \(Self.clock(l))"
        case let (j?, nil): "\(Self.clock(j)) – …"
        default: "Time unknown"
        }
    }

    /// ISO-8601 clock ("14:30") or the raw string when unparseable.
    static func clock(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return iso }
        let c = DateFormatter()
        c.locale = Locale(identifier: "en_US")
        c.setLocalizedDateFormatFromTemplate("j:mm")
        return c.string(from: d)
    }
}

/// The reads behind one meeting's attendance. Blocking; called off-main.
public protocol MeetingAttendanceTransport: Sendable {
    func attendance(meetingID: String) throws -> [AttendanceEntry]
}

/// Live transport: core FFI (Graph). A scope 403 throws, like every
/// other core read — the store words it as the disabled reason.
public struct CoreMeetingAttendanceTransport: MeetingAttendanceTransport {
    public init() {}

    struct Response: Decodable {
        let ok: Bool
        let entries: [AttendanceEntry]?
    }

    public func attendance(meetingID: String) throws -> [AttendanceEntry] {
        let r = try meetingID.withCString {
            try RustCore.call(ostmac_meeting_attendance($0), as: Response.self)
        }
        guard r.ok, let entries = r.entries else {
            throw CoreCallError.failed("attendance read failed")
        }
        return entries
    }
}

/// Demo transport: fixed Western-name fixture (tests + captures).
public struct DemoMeetingAttendanceTransport: MeetingAttendanceTransport {
    public init() {}
    public func attendance(meetingID _: String) throws -> [AttendanceEntry] {
        MeetingAttendanceDemo.entries
    }
}

public enum MeetingAttendanceDemo {
    public static let entries = [
        AttendanceEntry(displayName: "Ava Stone", role: "presenter",
                        joinDT: "2026-11-19T14:00:00Z", leaveDT: "2026-11-19T14:30:45Z",
                        durationSecs: 1845),
        AttendanceEntry(displayName: "Liam Carter", role: "attendee",
                        joinDT: "2026-11-19T14:02:00Z", leaveDT: "2026-11-19T14:28:00Z",
                        durationSecs: 1560),
        AttendanceEntry(displayName: "Mia Novak", role: "attendee",
                        joinDT: "2026-11-19T14:10:00Z", durationSecs: 0),
    ]
}

/// Attendance report state for one meeting.
public enum MeetingAttendanceState: Equatable, Sendable {
    case loading
    case loaded([AttendanceEntry])
    /// The read succeeded and the meeting filed no report (yet).
    case empty
    /// The read failed (401/403 name the cause, with retry).
    case failed(String)
}

/// One meeting's attendance report. Demo transport never touches the
/// network; the live transport surfaces a scope 403 as the disabled
/// reason (the toggle section below shares the same wording).
@MainActor
public final class MeetingAttendanceStore: ObservableObject {
    @Published public private(set) var state: MeetingAttendanceState = .loading

    /// Why the live path is disabled (missing `OnlineMeetings.Read`).
    public static let liveDisabledReason =
        "Teams didn’t allow Better Teams to read attendance (access denied). " +
        "The meeting organizer can see the report in Teams."

    private let meetingID: String
    private let transport: any MeetingAttendanceTransport
    private var started = false

    public init(meetingID: String, transport: any MeetingAttendanceTransport) {
        self.meetingID = meetingID
        self.transport = transport
    }

    public func load() {
        guard !started else { return }
        started = true
        reload()
    }

    public func reload() {
        state = .loading
        let id = meetingID
        let t = transport
        Task {
            let rows = await Task.blocking { Result { try t.attendance(meetingID: id) } }.value
            switch rows {
            case let .success(r): self.state = r.isEmpty ? .empty : .loaded(r)
            case let .failure(e): self.state = .failed(Self.word(e))
            }
        }
    }

    /// A scope 403 reads as the disabled reason (the organizer path);
    /// anything else keeps the recap copy (401, offline, unknown). Pure.
    nonisolated static func word(_ error: Error) -> String {
        let raw: String
        if case CoreCallError.failed(let m) = error { raw = m } else { raw = String(describing: error) }
        if raw.contains("403") { return liveDisabledReason }
        return MeetingRecapCopy.failure(error)
    }
}
