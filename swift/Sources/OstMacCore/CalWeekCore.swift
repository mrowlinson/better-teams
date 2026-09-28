// CalWeekCore.swift — B1 calendar lane: RustCore week/schedule/cancel
// wrappers (blocking FFI + network: call off the main thread).
import COstMac
import Foundation

extension RustCore {
    /// Week-window meetings (`ostmac_cal_week`). `weekStart` is unix
    /// seconds at the week midnight; `days` defaults to the 7-day grid.
    public static func calWeek(
        weekStart: Int64, days: Int32 = 7, limit: Int32 = 50
    ) throws -> CalWeekResponse {
        try call(ostmac_cal_week(weekStart, days, limit), as: CalWeekResponse.self)
    }

    /// Schedule one meeting (`ostmac_cal_schedule`). `start`/`end` are
    /// Graph datetimes (`yyyy-MM-dd'T'HH:mm:ss`); `online` requests a
    /// Teams link. Needs `Calendars.ReadWrite`; a 403 throws with detail.
    public static func calSchedule(
        subject: String, start: String, end: String,
        timeZone: String, online: Bool
    ) throws -> CalEventResult {
        try subject.withCString { sPtr in
            try start.withCString { stPtr in
                try end.withCString { ePtr in
                    try timeZone.withCString { tzPtr in
                        try call(
                            ostmac_cal_schedule(
                                sPtr, stPtr, ePtr, tzPtr, online ? 1 : 0),
                            as: CalEventResult.self)
                    }
                }
            }
        }
    }

    /// Cancel one meeting (`ostmac_cal_cancel`).
    public static func calCancel(eventID: String) throws -> CalCancelResult {
        try eventID.withCString { ptr in
            try call(ostmac_cal_cancel(ptr), as: CalCancelResult.self)
        }
    }

    /// Resolve a typed meeting ID + passcode to the meeting's join URL
    /// (`ostmac_meeting_resolve_id`, core-c). Blocking FFI + network.
    public static func meetingResolveID(
        meetingID: String, passcode: String
    ) throws -> MeetingIDResolution {
        let raw: UnsafeMutablePointer<CChar>? = meetingID.withCString { idPtr in
            passcode.withCString { passPtr in
                ostmac_meeting_resolve_id(idPtr, passPtr)
            }
        }
        guard let raw else { throw CoreCallError.failed("null from core") }
        defer { ostmac_free(raw) }
        return try MeetingIDResolution.parse(
            Data(bytes: UnsafeRawPointer(raw), count: strlen(raw)))
    }
}
