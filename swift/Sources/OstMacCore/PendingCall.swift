// PendingCall.swift — P4 split: verbatim move from CallHistory.swift.
import Foundation

/// In-flight call: ringing snapshot + optional connect mark. In-memory
/// only — a relaunch mid-call still finalizes from the slot snapshot.
struct PendingCall: Equatable {
    var peer: String
    var peerName: String
    var thread: String
    var dir: String
    var ringingAt: Date
    var connectedAt: Date?
}
