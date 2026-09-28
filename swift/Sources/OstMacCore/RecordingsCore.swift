// RecordingsCore.swift — om-recordings lane: recordings FFI calls.
//
// Separate from RustCore.swift (merge hygiene: this lane's calls live
// in this file). Uses the shared internal `RustCore.call` decoder.
import COstMac
import Foundation

/// Recordings core calls. Blocking FFI + network; callers run these
/// off the main thread (see `RecordingsViewModel`).
public enum RecordingsCore {
    /// Every meeting recording, newest first.
    public static func list(limit: Int32 = 50) throws -> RecordingsResponse {
        try RustCore.call(ostmac_recordings_list(limit), as: RecordingsResponse.self)
    }

    /// One recordings search window.
    public static func search(query: String, limit: Int32 = 50) throws -> RecordingsSearchResponse {
        try query.withCString { ptr in
            try RustCore.call(
                ostmac_recordings_search(ptr, limit),
                as: RecordingsSearchResponse.self)
        }
    }
}
