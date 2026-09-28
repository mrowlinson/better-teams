// CallsModel.swift — the Calls section's Recent list (UI-SPEC §6.5):
// the local call history (`CallHistoryStore`) plus missed calls the
// history never saw — the realtime missed-call rows in the Activity
// feed (core-a `Event/Call`, carrying `ActivityItem.callerID`). A feed
// row for a caller the history already has within
// `ActivityStore.missedCallWindow` is the same call and is dropped.
import Foundation
import OstMacCore

struct CallsRowModel: Identifiable, Equatable {
    /// Selection id: `rec:<record id>` or `act:<activity item id>`.
    let id: String
    /// The person: caller/peer id (MRI) when known, else the name.
    let personKey: String
    /// Caller/peer id (MRI) when known (presence, Call Back).
    let personID: String?
    let name: String
    let direction: CallDirection
    /// Unix seconds.
    let at: UInt64
    let durationSecs: UInt64
    /// Thread a call can be placed on ("" = none known).
    let thread: String

    var isMissed: Bool { direction == .missed }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(at)) }

    static let recordPrefix = "rec:"
    static let activityPrefix = "act:"

    /// Evidence alias (`calls/demo-person`, §11.3): the demo missed call
    /// from the realtime feed (caller id, no history record).
    static let demoPersonAlias = "demo-person"
    static let demoPersonID = activityPrefix + "missedCall:-:demo-missed"

    /// Newest first.
    static func rows(history: [CallRecord], activity: [ActivityItem]) -> [CallsRowModel] {
        var out = history.map { r in
            CallsRowModel(id: recordPrefix + r.id, personKey: key(r.peer, r.displayName),
                          personID: r.peer.isEmpty ? nil : r.peer, name: r.displayName, direction: r.direction,
                          at: r.startedAt, durationSecs: r.durationSecs, thread: r.thread)
        }
        for item in activity where item.kind == .missedCall {
            let caller = item.callerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let seen = history.contains { r in
                guard r.isMissed, !caller.isEmpty, r.peer.lowercased() == caller.lowercased() else { return false }
                let gap = r.startedAt > item.at ? r.startedAt - item.at : item.at - r.startedAt
                return gap <= ActivityStore.missedCallWindow
            }
            guard !seen else { continue }
            let name = item.actor.isEmpty ? item.chatName : item.actor
            out.append(CallsRowModel(id: activityPrefix + item.id, personKey: key(caller, name),
                                     personID: caller.isEmpty ? nil : caller, name: name, direction: .missed,
                                     at: item.at, durationSecs: 0, thread: item.chatID))
        }
        return out.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
    }

    private static func key(_ id: String, _ name: String) -> String {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "name:" + name : t.lowercased()
    }

    /// "Missed", "Incoming · 4:17", "Outgoing" (row + detail line).
    var detailLine: String {
        guard !isMissed, durationSecs > 0 else { return direction.label }
        return "\(direction.label) \u{00B7} \(CallRecord.durationLabel(durationSecs))"
    }

    /// Row symbol (§6.5): outgoing up-right, incoming/missed down-left.
    var symbol: String {
        direction == .outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
    }
}
