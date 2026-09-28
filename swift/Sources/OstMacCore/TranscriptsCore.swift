// TranscriptsCore.swift — om-transcripts-build lane: transcripts FFI calls.
//
// Separate from RustCore.swift (merge hygiene: this lane's calls live
// in this file). Uses the shared internal `RustCore.call` decoder.
import COstMac
import Foundation

/// Transcripts core calls. Blocking FFI + network; callers run these
/// off the main thread (see `TranscriptsViewModel`).
public enum TranscriptsCore {
    /// Every meeting transcript, newest first.
    public static func list(limit: Int32 = 50) throws -> TranscriptsResponse {
        try RustCore.call(ostmac_transcripts_list(limit), as: TranscriptsResponse.self)
    }

    /// One transcripts search window.
    public static func search(query: String, limit: Int32 = 50) throws -> TranscriptsSearchResponse {
        try query.withCString { ptr in
            try RustCore.call(
                ostmac_transcripts_search(ptr, limit),
                as: TranscriptsSearchResponse.self)
        }
    }
}
