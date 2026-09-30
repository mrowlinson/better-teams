// MeetingRecapCore.swift — RECAP2 live transport: core FFI calls.
//
// Separate file (merge hygiene). Blocking FFI + network; the view model
// runs these off the main thread. Every call returns `{ok:false,error}`
// on a failed read (thrown here as `CoreCallError`), never an empty
// success, so a 401/403 reaches the viewer as an error.
import COstMac
import Foundation

public struct CoreMeetingRecapTransport: MeetingRecapTransport {
    public init() {}

    struct SourcesResponse: Decodable {
        let ok: Bool
        let messages: [MeetingRecapParse.RawMessage]
        let pages: Int?
        let complete: Bool?
        let collab: Collab?
    }

    /// Meeting-artifacts read: `{ok:true,resources}` or `{ok:false,error}`
    /// (absent when the chat names no meeting identity).
    struct Collab: Decodable {
        let ok: Bool
        let resources: [MeetingRecapParse.ArtifactResource]?
        let error: String?
    }

    struct RecordingResponse: Decodable {
        let ok: Bool
        let item: RecordingItem
    }

    struct TranscriptResponse: Decodable {
        let ok: Bool
        let found: Bool
        let content: String?
    }

    struct NotesResponse: Decodable {
        let ok: Bool
        let html: String?
    }

    struct AIResponse: Decodable {
        let ok: Bool
        let available: Bool
        let notes: [String]?
        let follow_ups: [String]?
        let reason: String?
    }

    public func sources(threadID: String) throws -> MeetingRecapSources {
        let r = try threadID.withCString { try RustCore.call(ostmac_meeting_recap_sources($0), as: SourcesResponse.self) }
        return Self.sources(from: r)
    }

    /// The core's answer → sources. No artifacts read (the chat named no
    /// meeting) is an unknown, like a failed one: never "none".
    static func sources(from r: SourcesResponse) -> MeetingRecapSources {
        let chat = MeetingRecapParse.sources(from: r.messages, pages: r.pages, complete: r.complete)
        let failed: String?
        if let c = r.collab {
            failed = c.ok ? nil : (c.error ?? "meeting artifacts read failed")
        } else {
            failed = MeetingRecapCopy.noIdentityError
        }
        return MeetingRecapParse.merge(chat, artifacts: r.collab?.resources ?? [], artifactsError: failed)
    }

    public func recording(_ target: MeetingFileTarget) throws -> RecordingItem {
        try target.json.withCString { try RustCore.call(ostmac_meeting_recap_recording($0), as: RecordingResponse.self) }.item
    }

    public func transcript(_ target: MeetingFileTarget) throws -> Data? {
        let r = try target.json.withCString {
            try RustCore.call(ostmac_meeting_recap_transcript($0), as: TranscriptResponse.self)
        }
        guard r.found, let c = r.content, !c.isEmpty else { return nil }
        return Data(c.utf8)
    }

    public func notesText(_ notes: MeetingNotesRef) throws -> String? {
        let r = try notes.json.withCString { try RustCore.call(ostmac_meeting_recap_notes($0), as: NotesResponse.self) }
        return r.html.map { LoopNotesText.plain(fromHTML: $0) }
    }

    public func intelligentRecap(threadID: String, fileURL: String?) throws -> MeetingAIRecap? {
        let r = try threadID.withCString { t in
            try (fileURL ?? "").withCString { f in
                try RustCore.call(ostmac_meeting_recap_ai(t, f), as: AIResponse.self)
            }
        }
        guard r.available else { return MeetingAIRecap(notes: [], followUps: [], unavailableReason: r.reason) }
        return MeetingAIRecap(notes: r.notes ?? [], followUps: r.follow_ups ?? [], unavailableReason: r.reason)
    }
}
