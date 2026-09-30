// MeetingRecapStore.swift — RECAP2: one meeting's recap for the unified
// viewer (chat Recap tab, Recaps app, Calendar Recap button).
//
// A `MeetingRecapViewModel` per meeting reads its parts independently
// (recording, transcript, notes, intelligent recap), each with its own
// state, so one failing part never hides the others. Models are cached
// per meeting (`MeetingRecapStore`): switching away and back shows what
// was read, with no reload flash. Reads run off the main thread through
// a `MeetingRecapTransport` (live: core FFI; tests/demo: fakes).
import Combine
import Foundation

/// The reads behind one meeting's recap. Blocking; called off-main.
/// Throwing means the read FAILED; nil/empty means it succeeded and
/// found nothing.
public protocol MeetingRecapTransport: Sendable {
    /// Recap references in the meeting chat (bounded history walk).
    func sources(threadID: String) throws -> MeetingRecapSources
    /// A playable recording for a stored file (organizer's
    /// OneDrive/SharePoint): a stream URL, or drive + item for download.
    func recording(_ target: MeetingFileTarget) throws -> RecordingItem
    /// The recording file's transcript bytes (Teams transcript JSON or
    /// VTT); nil when the file has none.
    func transcript(_ target: MeetingFileTarget) throws -> Data?
    /// Meeting notes as read-only text; nil when the notes are a Loop
    /// page address with no content read (they open in the window).
    func notesText(_ notes: MeetingNotesRef) throws -> String?
    /// The intelligent recap; nil when the tenant/license provides none.
    func intelligentRecap(threadID: String, fileURL: String?) throws -> MeetingAIRecap?
}

/// User-facing copy (titles state the condition).
public enum MeetingRecapCopy {
    public static let noRecording = "This meeting wasn\u{2019}t recorded."
    public static let recordingFailed = "The recording for this meeting didn\u{2019}t finish."
    public static let noTranscript = "This meeting has no transcript."
    public static let noNotes = "This meeting has no meeting notes."
    /// The chat named no meeting (no identity in its properties or its
    /// transcript messages): the artifacts service could not be asked, so
    /// the recording, transcript and notes are unknown, never "none".
    public static let noIdentityError = "no meeting identity"
    public static let noIdentity =
        "Teams didn\u{2019}t say which meeting this chat belongs to, so Better Teams can\u{2019}t tell whether it has a recording, transcript or notes. Try again."
    /// The transcript file was read but is in no format Better Teams knows.
    public static let transcriptUnreadable = "Better Teams couldn\u{2019}t read this transcript\u{2019}s format."
    /// Teams posted a transcript for the meeting, but named no file this
    /// app can read: never "no transcript".
    public static let transcriptUnlocated =
        "Teams has a transcript for this meeting, but didn\u{2019}t say where it\u{2019}s stored. Try again later."
    public static let noAIRecap = "Intelligent recap isn\u{2019}t available for this meeting."
    public static let filesOnlyNotes = "Meeting notes are kept with the meeting chat, which this recording isn\u{2019}t linked to."
    public static let filesOnlyAIRecap = "Intelligent recap isn\u{2019}t available for this recording."

    /// A failed read as the viewer words it. 401/403 name the cause;
    /// never "none", and never the raw URL or response body.
    public static func failure(_ error: Error) -> String {
        let raw: String
        if case CoreCallError.failed(let m) = error { raw = m } else { raw = String(describing: error) }
        let lower = raw.lowercased()
        if raw == noIdentityError { return noIdentity }
        let status = FriendlyError.httpStatus(in: raw) ?? (lower.contains("401 unauthorized") ? 401 : nil)
        switch status {
        case 401: return "Your Teams sign-in has expired. Sign in again, then try again."
        case 403: return "Teams didn\u{2019}t allow Better Teams to read this (access denied)."
        case 404: return "Teams couldn\u{2019}t find this item (it may have been moved or deleted)."
        default: break
        }
        if lower.contains("not signed in") || lower.contains("token refresh failed") || lower.contains("no token") {
            return "You\u{2019}re not signed in to Teams. Sign in, then try again."
        }
        let friendly = FriendlyError.message(raw)
        if friendly != raw { return friendly }
        return "Teams couldn\u{2019}t read this part of the recap. Try again."
    }
}

/// One meeting's recap parts.
@MainActor
public final class MeetingRecapViewModel: ObservableObject {
    /// Downloads a drive file (drive, item, dest) → written path (the
    /// Recaps list's transcript files).
    public typealias FileDownload = @Sendable (String, String, String) throws -> String

    /// Meeting chat thread (nil: a drive recording/transcript with no
    /// known meeting chat).
    public let threadID: String?
    public let title: String
    /// Drive files for this meeting (Recaps list), used when the chat
    /// names none.
    public private(set) var fileRecording: RecordingItem?
    public private(set) var fileTranscript: TranscriptItem?

    @Published public private(set) var sources: RecapPart<MeetingRecapSources> = .loading
    @Published public private(set) var recording: RecapPart<RecordingItem> = .loading
    @Published public private(set) var transcript: RecapPart<[TranscriptCue]> = .loading
    @Published public private(set) var notes: RecapPart<MeetingNotesContent> = .loading
    @Published public private(set) var aiRecap: RecapPart<MeetingAIRecap> = .loading

    private let transport: any MeetingRecapTransport
    private let download: FileDownload
    private var started = false
    private var generation = 0

    public init(threadID: String?, title: String, fileRecording: RecordingItem? = nil,
                fileTranscript: TranscriptItem? = nil, transport: any MeetingRecapTransport,
                download: @escaping FileDownload) {
        self.threadID = threadID
        self.title = title
        self.fileRecording = fileRecording
        self.fileTranscript = fileTranscript
        self.transport = transport
        self.download = download
    }

    /// First read (idempotent: what is read stays, no reload flash).
    public func load() {
        guard !started else { return }
        started = true
        reload()
    }

    /// Re-read everything that failed (the viewer's Try Again). A failed
    /// artifacts read (what the failed parts rest on) reads again first.
    public func retry() {
        if sources.isFailed {
            reload()
            return
        }
        guard let s = sources.value else { return }
        if s.artifactsError != nil, let threadID {
            rereadSources(threadID)
            return
        }
        if recording.isFailed { recording = .loading; readRecording(s, generation) }
        if transcript.isFailed { transcript = .loading; readTranscript(s, generation) }
        if notes.isFailed { notes = .loading; readNotes(s, generation) }
        if aiRecap.isFailed { aiRecap = .loading; readAIRecap(s, generation) }
    }

    /// Drive files matched after the recap opened (the Recaps lists
    /// landed later): a part that read as absent reads again with them.
    public func updateFiles(recording: RecordingItem?, transcript: TranscriptItem?) {
        guard recording != fileRecording || transcript != fileTranscript else { return }
        fileRecording = recording
        fileTranscript = transcript
        guard let s = sources.value else { return }
        if case .absent = self.recording, recording != nil { readRecording(s, generation) }
        if case .absent = self.transcript, transcript != nil {
            self.transcript = .loading
            readTranscript(s, generation)
        }
    }

    /// The Recaps drive lists' failed reads (a recap with no meeting
    /// chat): the part the failed list would have named is unknown.
    public private(set) var recordingsListError: String?
    public private(set) var transcriptsListError: String?

    public func updateListErrors(recordings: String?, transcripts: String?) {
        guard recordings != recordingsListError || transcripts != transcriptsListError else { return }
        recordingsListError = recordings
        transcriptsListError = transcripts
        guard threadID == nil, let s = sources.value else { return }
        if recording.value == nil { readRecording(s, generation) }
        if transcript.value == nil {
            transcript = .loading
            readTranscript(s, generation)
        }
    }

    /// True while any part is still reading.
    public var isLoading: Bool {
        [sources == .loading, recording == .loading, transcript == .loading, notes == .loading,
         aiRecap == .loading].contains(true)
    }

    private func reload() {
        generation += 1
        let gen = generation
        sources = .loading
        recording = .loading
        transcript = .loading
        notes = .loading
        aiRecap = .loading
        guard let threadID else {
            apply(sources: .none, gen)
            return
        }
        let transport = transport
        Task {
            let result = await Task.blocking { Result { try transport.sources(threadID: threadID) } }.value
            guard gen == generation else { return }
            switch result {
            // A failed (or impossible) artifacts read leaves each part it
            // rests on failed, never "none" (readRecording/-Transcript/-Notes);
            // the intelligent recap reads by thread on its own.
            case .success(let s): apply(sources: s, gen)
            case .failure(let e):
                // The chat couldn't be read: every part is unknown, so every
                // part shows the failure (never "none").
                let m = MeetingRecapCopy.failure(e)
                sources = .failed(m)
                recording = .failed(m)
                transcript = .failed(m)
                notes = .failed(m)
                aiRecap = .failed(m)
            }
        }
    }

    /// Sources again (the artifacts read failed before): parts already
    /// shown stay (no flash); the others read again.
    private func rereadSources(_ threadID: String) {
        let gen = generation
        let transport = transport
        if recording.value == nil { recording = .loading }
        if transcript.value == nil { transcript = .loading }
        if notes.value == nil { notes = .loading }
        if aiRecap.value == nil { aiRecap = .loading }
        Task {
            let result = await Task.blocking { Result { try transport.sources(threadID: threadID) } }.value
            guard gen == generation else { return }
            switch result {
            case .success(let s):
                sources = .loaded(s)
                if recording.value == nil { readRecording(s, gen) }
                if transcript.value == nil { readTranscript(s, gen) }
                if notes.value == nil { readNotes(s, gen) }
                if aiRecap.value == nil { readAIRecap(s, gen) }
            case .failure(let e):
                let m = MeetingRecapCopy.failure(e)
                if recording.value == nil { recording = .failed(m) }
                if transcript.value == nil { transcript = .failed(m) }
                if notes.value == nil { notes = .failed(m) }
                if aiRecap.value == nil { aiRecap = .failed(m) }
            }
        }
    }

    private func apply(sources s: MeetingRecapSources, _ gen: Int) {
        sources = .loaded(s)
        readRecording(s, gen)
        readTranscript(s, gen)
        readNotes(s, gen)
        readAIRecap(s, gen)
    }

    private func readRecording(_ s: MeetingRecapSources, _ gen: Int) {
        guard let target = s.playable?.target else {
            if let r = fileRecording {
                recording = .loaded(r)
            } else if !s.recordings.isEmpty {
                recording = .absent(MeetingRecapCopy.recordingFailed)
            } else if let e = s.artifactsError ?? (threadID == nil ? recordingsListError : nil) {
                // Teams names the recording through the artifacts service
                // (a chat-less recap: the drive list): when that read
                // failed, "not recorded" is unproven.
                recording = .failed(MeetingRecapCopy.failure(CoreCallError.failed(e)))
            } else {
                recording = .absent(MeetingRecapCopy.noRecording)
            }
            return
        }
        let transport = transport
        Task {
            let r = await Task.blocking { Result { try transport.recording(target) } }.value
            guard gen == generation else { return }
            switch r {
            case .success(let item): recording = .loaded(item)
            case .failure(let e): recording = .failed(MeetingRecapCopy.failure(e))
            }
        }
    }

    private func readTranscript(_ s: MeetingRecapSources, _ gen: Int) {
        let file = s.transcriptTarget
        let fallback = fileTranscript
        // Teams posted a transcript message: "no transcript" would
        // contradict Teams.
        let teamsHasOne = !s.transcripts.isEmpty
        guard file != nil || fallback != nil else {
            if let e = s.artifactsError ?? (threadID == nil ? transcriptsListError : nil) {
                transcript = .failed(MeetingRecapCopy.failure(CoreCallError.failed(e)))
            } else if teamsHasOne {
                transcript = .failed(MeetingRecapCopy.transcriptUnlocated)
            } else {
                transcript = .absent(MeetingRecapCopy.noTranscript)
            }
            return
        }
        let transport = transport
        let download = download
        Task {
            let r = await Task.blocking { () -> Result<[TranscriptCue]?, Error> in
                Result {
                    if let file, let data = try transport.transcript(file) {
                        return try TeamsTranscriptJSON.parseStrict(data)
                    }
                    if let t = fallback, let drive = t.drive_id, !drive.isEmpty {
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("recap-\(t.id.replacingOccurrences(of: "/", with: "_")).vtt").path
                        let path = try download(drive, t.id, dest)
                        let data = try Data(contentsOf: URL(fileURLWithPath: path))
                        return try TeamsTranscriptJSON.parseStrict(data)
                    }
                    return nil
                }
            }.value
            guard gen == generation else { return }
            switch r {
            case .success(let cues?) where !cues.isEmpty: transcript = .loaded(cues)
            case .success where teamsHasOne: transcript = .failed(MeetingRecapCopy.transcriptUnlocated)
            case .success: transcript = .absent(MeetingRecapCopy.noTranscript)
            case .failure(let e) where e is TranscriptFormatError:
                transcript = .failed(MeetingRecapCopy.transcriptUnreadable)
            case .failure(let e): transcript = .failed(MeetingRecapCopy.failure(e))
            }
        }
    }

    private func readNotes(_ s: MeetingRecapSources, _ gen: Int) {
        guard threadID != nil else {
            notes = .absent(MeetingRecapCopy.filesOnlyNotes)
            return
        }
        guard let ref = s.notes.last, let url = URL(string: ref.url) else {
            // Teams names the notes through the artifacts service: when
            // that read failed, "no notes" is unproven.
            if let e = s.artifactsError {
                notes = .failed(MeetingRecapCopy.failure(CoreCallError.failed(e)))
            } else {
                notes = .absent(MeetingRecapCopy.noNotes)
            }
            return
        }
        let title = ref.title ?? "Meeting notes"
        let transport = transport
        Task {
            let r = await Task.blocking { Result { try transport.notesText(ref) } }.value
            guard gen == generation else { return }
            switch r {
            case .success(let text): notes = .loaded(MeetingNotesContent(title: title, webURL: url, text: text))
            // The link is known even when the preview read fails: the
            // notes still open in the window; the failure shows beside it.
            case .failure(let e): notes = .failed(MeetingRecapCopy.failure(e))
            }
        }
    }

    private func readAIRecap(_ s: MeetingRecapSources, _ gen: Int) {
        guard let threadID else {
            aiRecap = .absent(MeetingRecapCopy.filesOnlyAIRecap)
            return
        }
        // The recording (drive ids when known) keys Teams' AI-notes query.
        let file = s.playable?.target.json
        let transport = transport
        Task {
            let r = await Task.blocking { Result { try transport.intelligentRecap(threadID: threadID, fileURL: file) } }.value
            guard gen == generation else { return }
            switch r {
            case .success(let recap?) where !recap.isEmpty: aiRecap = .loaded(recap)
            case .success(let recap): aiRecap = .absent(recap?.unavailableReason ?? MeetingRecapCopy.noAIRecap)
            case .failure(let e): aiRecap = .failed(MeetingRecapCopy.failure(e))
            }
        }
    }

    /// The notes link, when the chat names one (open in window even if
    /// the text preview failed).
    public var notesURL: URL? {
        sources.value?.notes.last.flatMap { URL(string: $0.url) }
    }
}

/// Recap view models per meeting (kept for the session: no reload
/// flash when the user comes back).
@MainActor
public final class MeetingRecapStore {
    public let transport: any MeetingRecapTransport
    private let download: MeetingRecapViewModel.FileDownload
    private var models: [String: MeetingRecapViewModel] = [:]
    private var order: [String] = []
    private let capacity = 24

    public init(transport: any MeetingRecapTransport,
                download: @escaping MeetingRecapViewModel.FileDownload) {
        self.transport = transport
        self.download = download
    }

    /// A meeting chat's recap (Recap tab, Calendar), with drive files
    /// matched by title as a fallback.
    public func model(threadID: String, title: String, fileRecording: RecordingItem? = nil,
                      fileTranscript: TranscriptItem? = nil) -> MeetingRecapViewModel {
        remember("thread:" + threadID) {
            MeetingRecapViewModel(threadID: threadID, title: title, fileRecording: fileRecording,
                                  fileTranscript: fileTranscript, transport: transport, download: download)
        }
    }

    /// A drive recording/transcript with no known meeting chat.
    public func model(fileRecording: RecordingItem?, fileTranscript: TranscriptItem?,
                      title: String) -> MeetingRecapViewModel {
        let key = "files:" + (fileRecording?.id ?? "-") + "|" + (fileTranscript?.id ?? "-")
        return remember(key) {
            MeetingRecapViewModel(threadID: nil, title: title, fileRecording: fileRecording,
                                  fileTranscript: fileTranscript, transport: transport, download: download)
        }
    }

    private func remember(_ key: String, _ make: () -> MeetingRecapViewModel) -> MeetingRecapViewModel {
        if let m = models[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return m
        }
        let m = make()
        models[key] = m
        order.append(key)
        if order.count > capacity {
            let drop = order.removeFirst()
            models[drop] = nil
        }
        return m
    }
}
