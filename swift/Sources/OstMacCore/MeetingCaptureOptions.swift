// MeetingCaptureOptions.swift — MEETINGS-PLUS: the meeting's server
// capture toggles (recording / transcription / auto-record), read and
// written the way Teams writes meeting options.
//
// Graph: `GET/PATCH /communications/onlineMeetings/{id}` with
// `allowRecording` / `allowTranscription` / `recordAutomatically` (scope
// `OnlineMeetings.ReadWrite`, NOT granted to the Teams token — live reads
// 403; the store surfaces the live-disabled reason and demo values).
// This complements meetrecord's in-call recorder-bot legs (which drive
// the live call): these toggles are the meeting's persisted options.
import COstMac
import Combine
import Foundation

/// The meeting's persisted server capture toggles. Every field is
/// optional: nil = the server named no value (shown as unknown, never
/// as off).
public struct MeetingCaptureOptions: Codable, Sendable, Equatable {
    public var allowRecording: Bool?
    public var allowTranscription: Bool?
    public var recordAutomatically: Bool?

    private enum CodingKeys: String, CodingKey {
        case allowRecording = "allow_recording"
        case allowTranscription = "allow_transcription"
        case recordAutomatically = "record_automatically"
    }

    public init(allowRecording: Bool? = nil, allowTranscription: Bool? = nil,
                recordAutomatically: Bool? = nil) {
        self.allowRecording = allowRecording
        self.allowTranscription = allowTranscription
        self.recordAutomatically = recordAutomatically
    }

    /// PATCH body: only the set fields (Graph names), nil = untouched.
    public var patchBody: String {
        var o: [String: Bool] = [:]
        if let v = allowRecording { o["allowRecording"] = v }
        if let v = allowTranscription { o["allowTranscription"] = v }
        if let v = recordAutomatically { o["recordAutomatically"] = v }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8),
                      as: UTF8.self)
    }
}

/// The reads/writes behind the toggles. Blocking; called off-main.
public protocol MeetingCaptureTransport: Sendable {
    func load(meetingID: String) throws -> MeetingCaptureOptions
    func save(meetingID: String, options: MeetingCaptureOptions) throws -> MeetingCaptureOptions
}

/// Live transport: core FFI (Graph). A scope 403 throws — the store
/// words it as the disabled reason.
public struct CoreMeetingCaptureTransport: MeetingCaptureTransport {
    public init() {}

    struct Response: Decodable {
        let ok: Bool
        let options: MeetingCaptureOptions?
    }

    public func load(meetingID: String) throws -> MeetingCaptureOptions {
        let r = try meetingID.withCString {
            try RustCore.call(ostmac_meeting_capture_get($0), as: Response.self)
        }
        guard r.ok, let o = r.options else {
            throw CoreCallError.failed("capture options read failed")
        }
        return o
    }

    public func save(meetingID: String, options: MeetingCaptureOptions) throws -> MeetingCaptureOptions {
        let body = options.patchBody
        let r = try meetingID.withCString { id in
            try body.withCString {
                try RustCore.call(ostmac_meeting_capture_set(id, $0), as: Response.self)
            }
        }
        guard r.ok, let o = r.options else {
            throw CoreCallError.failed("capture options write failed")
        }
        return o
    }
}

/// Demo transport: fixed values (tests + captures); saves echo.
public struct DemoMeetingCaptureTransport: MeetingCaptureTransport {
    public var options: MeetingCaptureOptions
    public init(options: MeetingCaptureOptions = MeetingCaptureOptions(
        allowRecording: true, allowTranscription: true, recordAutomatically: false)) {
        self.options = options
    }
    public func load(meetingID _: String) throws -> MeetingCaptureOptions { options }
    public func save(meetingID _: String, options: MeetingCaptureOptions) throws -> MeetingCaptureOptions {
        options
    }
}

public enum MeetingCaptureDemo {
    public static let options = MeetingCaptureOptions(
        allowRecording: true, allowTranscription: true, recordAutomatically: false)
}

/// One meeting's server capture toggles.
@MainActor
public final class MeetingCaptureStore: ObservableObject {
    @Published public private(set) var options: MeetingCaptureOptions?
    @Published public private(set) var loading = true
    @Published public private(set) var error: String?
    @Published public private(set) var saving = false

    /// Why the live path is disabled (missing `OnlineMeetings.ReadWrite`).
    public static let liveDisabledReason =
        "Teams didn’t allow Better Teams to change recording options (access denied). " +
        "The meeting organizer can change them in Teams."

    private let meetingID: String
    private let transport: any MeetingCaptureTransport
    private var started = false

    public init(meetingID: String, transport: any MeetingCaptureTransport) {
        self.meetingID = meetingID
        self.transport = transport
    }

    public func load() {
        guard !started else { return }
        started = true
        reload()
    }

    public func reload() {
        loading = true
        error = nil
        let id = meetingID
        let t = transport
        Task {
            let next = await Task.blocking { Result { try t.load(meetingID: id) } }.value
            self.loading = false
            switch next {
            case let .success(o): self.options = o
            case let .failure(e): self.error = Self.word(e)
            }
        }
    }

    public func save(_ options: MeetingCaptureOptions) {
        saving = true
        error = nil
        let id = meetingID
        let t = transport
        Task {
            let next = await Task.blocking { Result { try t.save(meetingID: id, options: options) } }.value
            self.saving = false
            switch next {
            case let .success(o): self.options = o
            case let .failure(e): self.error = Self.word(e)
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
