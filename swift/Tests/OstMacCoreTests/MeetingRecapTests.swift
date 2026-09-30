// MeetingRecapTests.swift — RECAP2: the meeting recap read the way Teams
// reads it (meeting-chat recording/transcript messages → organizer's
// file → its transcript; Loop notes; intelligent recap), per source with
// a fake transport, plus the guard that a 401/403 never reads as "none".
import Foundation
import XCTest

@testable import OstMacCore

/// Fake transport: canned answers, or a thrown core error per read.
final class FakeRecapTransport: MeetingRecapTransport, @unchecked Sendable {
    var sourcesResult: Result<MeetingRecapSources, Error> = .success(.none)
    var recordingResult: Result<RecordingItem, Error> = .success(
        RecordingItem(id: "rec-1", name: "Budget Review.mp4", download_url: "https://contoso-my.sharepoint.com/dl"))
    var transcriptResult: Result<Data?, Error> = .success(nil)
    var notesResult: Result<String?, Error> = .success(nil)
    var aiResult: Result<MeetingAIRecap?, Error> = .success(nil)
    private let lock = NSLock()
    private(set) var calls: [String] = []

    private func log(_ s: String) {
        lock.lock()
        calls.append(s)
        lock.unlock()
    }

    func sources(threadID: String) throws -> MeetingRecapSources {
        log("sources"); return try sourcesResult.get()
    }
    func recording(_ target: MeetingFileTarget) throws -> RecordingItem {
        log("recording"); return try recordingResult.get()
    }
    func transcript(_ target: MeetingFileTarget) throws -> Data? {
        log("transcript"); return try transcriptResult.get()
    }
    private(set) var notesRefs: [MeetingNotesRef] = []
    func notesText(_ notes: MeetingNotesRef) throws -> String? {
        log("notes")
        lock.lock()
        notesRefs.append(notes)
        lock.unlock()
        return try notesResult.get()
    }
    func intelligentRecap(threadID: String, fileURL: String?) throws -> MeetingAIRecap? {
        log("ai"); return try aiResult.get()
    }
}

@MainActor
final class MeetingRecapTests: XCTestCase {
    static let file = "https://contoso-my.sharepoint.com/personal/tom_becker_contoso_com/Documents/Recordings/Budget%20Review-20260901_100000-Meeting%20Recording.mp4"
    static let notes = "https://contoso-my.sharepoint.com/personal/tom_becker_contoso_com/Documents/Meetings/Budget%20Review.loop"

    /// The chat service's recording message (shape of the live
    /// `RichText/Media_CallRecording` content: URIObject + RecordingContent).
    static let recordingXML = """
    <URIObject type="Video.2/CallRecording.1" uri="https://as-prod.asyncgw.teams.microsoft.com/v1/objects/0-wus-d1-abc" \
    url_thumbnail="https://as-prod.asyncgw.teams.microsoft.com/v1/objects/0-wus-d1-abc/views/thumbnail">\
    <Title>Budget Review</Title><Description/><a href="\(file)">Play</a>\
    <OriginalName v="Budget Review-20260901_100000-Meeting Recording.mp4"/>\
    <RecordingStatus status="Success" code="200"/>\
    <RecordingContent timestamp="2026-09-01T10:00:00.000Z" duration="1834.5">\
    <item type="amsVideo" uri="https://as-prod.asyncgw.teams.microsoft.com/v1/objects/0-wus-d1-abc"/>\
    <item type="onedriveForBusinessVideo" uri="\(file.replacingOccurrences(of: "&", with: "&amp;"))" driveId="b!drive" driveItemId="01ITEM"/>\
    </RecordingContent></URIObject>
    """

    static func messages(recordingStatus: String = "Success") -> [MeetingRecapParse.RawMessage] {
        [
            .init(id: "10", messagetype: "RichText/Media_CallRecording",
                  content: recordingXML.replacingOccurrences(of: "status=\"Success\"", with: "status=\"\(recordingStatus)\""),
                  composetime: "2026-09-01T10:31:00Z"),
            .init(id: "11", messagetype: "RichText/Media_CallTranscript",
                  content: "{\"scopeId\":\"s\",\"callId\":\"c\",\"storageId\":\"0-wus\"}",
                  composetime: "2026-09-01T10:32:00Z"),
            .init(id: "12", messagetype: "RichText/Html",
                  content: "<p>Notes: <a href=\"\(notes)\">Budget Review</a></p>", composetime: "2026-09-01T09:59:00Z"),
        ]
    }

    static let transcriptJSON = """
    {"entries":[
     {"speakerDisplayName":"Ava Lindqvist","startOffset":"00:00:01.5000000","endOffset":"00:00:04.0000000","text":"Let's start."},
     {"speakerDisplayName":"Tom Becker","startOffset":"00:01:02.0000000","endOffset":"00:01:09.2500000","text":"Numbers are in."},
     {"speakerDisplayName":"Tom Becker","startOffset":"01:00:00.0000000","endOffset":"01:00:02.0000000","text":"  "}
    ]}
    """

    func waitFor(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        // `timeout` is a hang ceiling only, raised to TestWait.hangCeiling.
        await TestWait.until(ceiling: max(timeout, TestWait.hangCeiling), interval: 0.02) { cond() }
    }

    func model(_ t: FakeRecapTransport, thread: String? = "19:meeting_abc@thread.v2",
               fileTranscript: TranscriptItem? = nil,
               download: @escaping MeetingRecapViewModel.FileDownload = { _, _, _ in throw CoreCallError.failed("no") })
        -> MeetingRecapViewModel {
        MeetingRecapViewModel(threadID: thread, title: "Budget Review", fileTranscript: fileTranscript,
                              transport: t, download: download)
    }

    // MARK: source 1 — meeting chat messages

    /// R4b: the recording length reads in every shape the message might
    /// carry it (plain seconds, clock, ISO 8601); junk stays nil.
    func testRecordingDurationParsesEveryShape() {
        for (raw, ms) in [("1834.5", 1_834_500), ("0:30:34.5", 1_834_500), ("00:30:34", 1_834_000),
                          ("30:34", 1_834_000), ("PT30M34.5S", 1_834_500), ("PT1H2M3S", 3_723_000)] {
            let xml = Self.recordingXML.replacingOccurrences(of: "duration=\"1834.5\"", with: "duration=\"\(raw)\"")
            let m = MeetingRecapParse.RawMessage(id: "d", messagetype: "RichText/Media_CallRecording",
                                                 content: xml, composetime: "2026-09-01T10:31:00Z")
            XCTAssertEqual(MeetingRecapParse.recording(m)?.duration_ms.map(Int.init), ms, raw)
        }
        for raw in ["", "abc", "0", "PT", "1:xx"] {
            XCTAssertNil(MeetingRecapParse.durationMillis(raw), raw)
        }
    }

    func testChatMessagesYieldOrganizerRecordingTranscriptAndNotes() {
        let s = MeetingRecapParse.sources(from: Self.messages())
        XCTAssertEqual(s.recordings.count, 1)
        let r = s.recordings[0]
        XCTAssertEqual(r.file_url, Self.file)
        XCTAssertEqual(r.status, "Success")
        XCTAssertEqual(r.duration_ms, 1_834_500)
        XCTAssertEqual(r.title, "Budget Review")
        XCTAssertTrue(r.isPlayable)
        XCTAssertEqual(r.drive_id, "b!drive")
        XCTAssertEqual(r.item_id, "01ITEM")
        XCTAssertEqual(s.transcripts.map(\.id), ["11"])
        // The transcript lives with the recording file.
        XCTAssertEqual(s.transcriptTarget, MeetingFileTarget(file_url: Self.file, drive_id: "b!drive", item_id: "01ITEM"))
        XCTAssertEqual(s.notes.map(\.url), [Self.notes])
    }

    func testRecordingRepostsCollapseToTheLatestStatus() {
        var msgs = Self.messages(recordingStatus: "Started")
        msgs.append(.init(id: "13", messagetype: "RichText/Media_CallRecording", content: Self.recordingXML,
                          composetime: "2026-09-01T10:40:00Z"))
        let s = MeetingRecapParse.sources(from: msgs)
        XCTAssertEqual(s.recordings.count, 1)
        XCTAssertEqual(s.recordings[0].status, "Success")
        XCTAssertEqual(s.playable?.id, "13")
    }

    func testFailedRecordingIsNotPlayable() {
        let s = MeetingRecapParse.sources(from: Self.messages(recordingStatus: "Failure"))
        XCTAssertNil(s.playable)
    }

    func testNotesLinksAreLoopFilesOnSharePointOrLoopPagesOnly() {
        XCTAssertTrue(MeetingRecapParse.isNotesURL(Self.notes))
        XCTAssertTrue(MeetingRecapParse.isNotesURL("https://loop.cloud.microsoft/p/abc"))
        XCTAssertFalse(MeetingRecapParse.isNotesURL("https://evil.example/x.loop"))
        XCTAssertFalse(MeetingRecapParse.isNotesURL("http://contoso.sharepoint.com/x.loop"))
        XCTAssertFalse(MeetingRecapParse.isNotesURL("https://contoso.sharepoint.com/x.docx"))
    }

    // MARK: source 2 — transcript (Teams JSON, VTT fallback)

    func testTeamsTranscriptJSONIsSpeakerAttributedAndTimed() {
        let cues = TeamsTranscriptJSON.parse(Data(Self.transcriptJSON.utf8))
        XCTAssertEqual(cues.count, 2) // blank text skipped
        XCTAssertEqual(cues[0].speaker, "Ava Lindqvist")
        XCTAssertEqual(cues[0].startMs, 1_500)
        XCTAssertEqual(cues[1].startMs, 62_000)
        XCTAssertEqual(cues[1].endMs, 69_250)
        XCTAssertEqual(cues[1].startLabel, "1:02")
        XCTAssertEqual(TeamsTranscriptJSON.offsetMs("01:02:03.5"), 3_723_500)
        // VTT bytes parse through the same entry point.
        XCTAssertEqual(TeamsTranscriptJSON.parse(Data(TranscriptsDemo.sampleVTT.utf8)).count, 4)
    }

    func testTranscriptSearchMatchesEveryWordInTextOrSpeaker() {
        let cues = TeamsTranscriptJSON.parse(Data(Self.transcriptJSON.utf8))
        XCTAssertEqual(TranscriptSearch.matches(cues, query: "numbers"), [1])
        XCTAssertEqual(TranscriptSearch.matches(cues, query: "tom IN"), [1])
        XCTAssertEqual(TranscriptSearch.matches(cues, query: "ava"), [0])
        XCTAssertEqual(TranscriptSearch.matches(cues, query: "  "), [])
    }

    // MARK: the whole recap, per part

    func testAllPartsLoadFromTheirSources() async {
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.sources(from: Self.messages()))
        t.transcriptResult = .success(Data(Self.transcriptJSON.utf8))
        t.notesResult = .success("Agenda")
        t.aiResult = .success(MeetingAIRecap(notes: ["Budget approved."], followUps: ["Send minutes."]))
        let m = model(t)
        m.load()
        let done = await waitFor { !m.isLoading }
        XCTAssertTrue(done)
        XCTAssertEqual(m.recording.value?.id, "rec-1")
        XCTAssertEqual(m.transcript.value?.count, 2)
        XCTAssertEqual(m.notes.value?.text, "Agenda")
        XCTAssertEqual(m.notes.value?.webURL.absoluteString, Self.notes)
        XCTAssertEqual(m.aiRecap.value?.followUps, ["Send minutes."])
        // Idempotent: a second load reads nothing again.
        m.load()
        XCTAssertEqual(t.calls.filter { $0 == "sources" }.count, 1)
    }

    func testEmptyChatReadsAsHonestAbsenceOnlyAfterSuccess() async {
        let t = FakeRecapTransport()
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.recording, .absent(MeetingRecapCopy.noRecording))
        XCTAssertEqual(m.transcript, .absent(MeetingRecapCopy.noTranscript))
        XCTAssertEqual(m.notes, .absent(MeetingRecapCopy.noNotes))
        XCTAssertEqual(m.aiRecap, .absent(MeetingRecapCopy.noAIRecap))
    }

    func testRecordingWithNoTranscriptOnTheFileIsAbsentTranscript() async {
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.sources(from: Array(Self.messages().prefix(1))))
        t.transcriptResult = .success(nil) // transcripts list read OK, empty
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertNotNil(m.recording.value)
        XCTAssertEqual(m.transcript, .absent(MeetingRecapCopy.noTranscript))
    }

    // MARK: guard — 401/403 never render as "no transcript"

    func testForbiddenChatReadIsAnErrorOnEveryPartNeverNone() async {
        for raw in ["HTTP 403 for https://x/y: {}", "401 Unauthorized for https://x. Token may be invalid"] {
            let t = FakeRecapTransport()
            t.sourcesResult = .failure(CoreCallError.failed(raw))
            let m = model(t)
            m.load()
            _ = await waitFor { !m.isLoading }
            for part in [m.recording.isFailed, m.transcript.isFailed, m.notes.isFailed, m.aiRecap.isFailed] {
                XCTAssertTrue(part, raw)
            }
            XCTAssertNotEqual(m.transcript, .absent(MeetingRecapCopy.noTranscript))
            guard case .failed(let msg) = m.transcript else { return XCTFail("not failed") }
            XCTAssertFalse(msg.contains("https://"), "no raw URL in the message")
            XCTAssertTrue(msg.contains(raw.hasPrefix("HTTP 403") ? "access denied" : "sign-in"), msg)
        }
    }

    func testForbiddenTranscriptReadIsAnErrorWhileOtherPartsShow() async {
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.sources(from: Self.messages()))
        t.transcriptResult = .failure(CoreCallError.failed("HTTP 403 (SharePoint)"))
        t.notesResult = .failure(CoreCallError.failed("401 Unauthorized (SharePoint)"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertNotNil(m.recording.value)
        XCTAssertTrue(m.transcript.isFailed)
        XCTAssertTrue(m.notes.isFailed)
        // The notes link stays usable (opens in the window).
        XCTAssertEqual(m.notesURL?.absoluteString, Self.notes)
        // Retry re-reads only the failed parts, and they land.
        t.transcriptResult = .success(Data(Self.transcriptJSON.utf8))
        t.notesResult = .success(nil)
        let before = t.calls.filter { $0 == "recording" }.count
        m.retry()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.transcript.value?.count, 2)
        XCTAssertNotNil(m.notes.value)
        XCTAssertEqual(t.calls.filter { $0 == "recording" }.count, before)
    }

    func testRecordingResolveFailureIsAnError() async {
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.sources(from: Self.messages()))
        t.recordingResult = .failure(CoreCallError.failed("HTTP 404 for x"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertTrue(m.recording.isFailed)
    }

    // MARK: drive files (Recaps rows without a meeting chat)

    func testDriveFilesOnlyRecapReadsTheTranscriptFileAndSaysWhyNoNotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recap2-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tr = TranscriptItem(id: "t-1", name: "Budget Review.vtt", size: 10, mime: nil, web_url: nil,
                                drive_id: "d", created: nil, modified: nil, source: "OneDrive")
        let out = dir.appendingPathComponent("t.vtt").path
        let m = model(FakeRecapTransport(), thread: nil, fileTranscript: tr) { _, _, _ in
            try TranscriptsDemo.sampleVTT.write(toFile: out, atomically: true, encoding: .utf8)
            return out
        }
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.transcript.value?.count, 4)
        XCTAssertEqual(m.notes, .absent(MeetingRecapCopy.filesOnlyNotes))
        XCTAssertEqual(m.recording, .absent(MeetingRecapCopy.noRecording))
    }

    func testStoreKeepsOneModelPerMeeting() {
        let store = MeetingRecapStore(transport: FakeRecapTransport(), download: { _, _, d in d })
        let a = store.model(threadID: "19:meeting_a@thread.v2", title: "A")
        XCTAssertTrue(a === store.model(threadID: "19:meeting_a@thread.v2", title: "A"))
        XCTAssertFalse(a === store.model(threadID: "19:meeting_b@thread.v2", title: "B"))
    }

    func testDemoRecapHasEveryPart() throws {
        let d = MeetingRecapDemoTransport()
        let s = try d.sources(threadID: DemoData.standupID)
        XCTAssertNotNil(s.playable)
        XCTAssertEqual(TeamsTranscriptJSON.parse(try XCTUnwrap(d.transcript(XCTUnwrap(s.transcriptTarget)))).count, 8)
        XCTAssertEqual(try d.sources(threadID: "other"), .none)
    }

    // MARK: source 0 — the meeting-artifacts service (Teams' recap index)

    func testArtifactsAddNotesAndTranscriptAndDedupeTheRecording() {
        let chat = MeetingRecapParse.sources(from: Array(Self.messages().prefix(1)))
        let loc = "https://contoso-my.sharepoint.com/_api/v2.1/drives/b!drive/items/01ITEM/versions/current/media/transcripts/T1/streamContent"
        let merged = MeetingRecapParse.merge(chat, artifacts: [
            .init(type: "recording", location: Self.file, drive_id: "b!drive", drive_item_id: "01ITEM"),
            .init(type: "transcriptv2", location: loc, drive_id: "b!drive", drive_item_id: "01ITEM"),
            .init(type: "notes", location: Self.notes),
        ], artifactsError: nil)
        XCTAssertEqual(merged.recordings.count, 1) // same file as the chat's
        XCTAssertEqual(merged.transcriptTarget?.location, loc)
        XCTAssertEqual(merged.notes.map(\.url), [Self.notes])
        // Artifacts alone (a chat with no recording message) still play.
        let only = MeetingRecapParse.merge(.none, artifacts: [
            .init(type: "recording", location: nil, drive_id: "d", drive_item_id: "i", web_url: Self.file)], artifactsError: nil)
        XCTAssertEqual(only.playable?.target, MeetingFileTarget(file_url: Self.file, drive_id: "d", item_id: "i"))
    }

    func testFailedArtifactsReadNeverReadsAsNoNotes() async {
        // Chat has a recording, artifacts read 403'd: notes are an error.
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.merge(MeetingRecapParse.sources(from: Array(Self.messages().prefix(1))),
                                                           artifacts: [], artifactsError: "HTTP 403 (meeting artifacts)"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertNotNil(m.recording.value)
        XCTAssertTrue(m.notes.isFailed)
        // Empty chat + failed artifacts: nothing is proven absent.
        let t2 = FakeRecapTransport()
        t2.sourcesResult = .success(MeetingRecapParse.merge(.none, artifacts: [], artifactsError: "HTTP 403 (meeting artifacts)"))
        let m2 = model(t2)
        m2.load()
        _ = await waitFor { !m2.isLoading }
        XCTAssertTrue(m2.recording.isFailed)
        XCTAssertTrue(m2.transcript.isFailed)
        XCTAssertNotEqual(m2.transcript, .absent(MeetingRecapCopy.noTranscript))
    }

    func testIntelligentRecapUnavailableShowsTeamsReason() async {
        let t = FakeRecapTransport()
        t.aiResult = .success(MeetingAIRecap(notes: [], followUps: [], unavailableReason: "Needs a license."))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.aiRecap, .absent("Needs a license."))
    }

    // MARK: RECAP2b — guards and the notes content read

    func testUnauthorizedChatReadIsSignInErrorOnEveryPartNeverNone() async {
        let t = FakeRecapTransport()
        t.sourcesResult = .failure(CoreCallError.failed("401 Unauthorized (messages)"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        for part in [m.recording.isFailed, m.transcript.isFailed, m.notes.isFailed, m.aiRecap.isFailed] {
            XCTAssertTrue(part)
        }
        guard case .failed(let message) = m.transcript else { return XCTFail("transcript not failed") }
        XCTAssertTrue(message.contains("sign-in has expired"), message)
        XCTAssertNotEqual(m.transcript, .absent(MeetingRecapCopy.noTranscript))
        XCTAssertNotEqual(m.recording, .absent(MeetingRecapCopy.noRecording))
    }

    func testTranscriptMessageWithNoReadableFileIsNeverNoTranscript() async {
        // Teams posted a transcript message (no file address in it), the
        // artifacts read succeeded with nothing: Teams has a transcript,
        // so the viewer never says there is none.
        let t = FakeRecapTransport()
        let msg = MeetingRecapParse.RawMessage(id: "11", messagetype: "RichText/Media_CallTranscript",
                                               content: "{\"callId\":\"c\",\"iCalUid\":\"i\"}")
        t.sourcesResult = .success(MeetingRecapParse.merge(MeetingRecapParse.sources(from: [msg]), artifacts: [],
                                                           artifactsError: nil))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.transcript, .failed(MeetingRecapCopy.transcriptUnlocated))
        XCTAssertEqual(m.recording, .absent(MeetingRecapCopy.noRecording))
        // The recording's transcript list read empty while Teams posted one.
        let t2 = FakeRecapTransport()
        t2.sourcesResult = .success(MeetingRecapParse.sources(from: Self.messages()))
        t2.transcriptResult = .success(nil)
        let m2 = model(t2)
        m2.load()
        _ = await waitFor { !m2.isLoading }
        XCTAssertEqual(m2.transcript, .failed(MeetingRecapCopy.transcriptUnlocated))
    }

    func testFailedArtifactsReadNeverReadsAsNotRecorded() async {
        // Chat names only the notes; the artifacts read 403'd.
        let t = FakeRecapTransport()
        let chat = MeetingRecapParse.sources(from: [Self.messages()[2]])
        t.sourcesResult = .success(MeetingRecapParse.merge(chat, artifacts: [],
                                                           artifactsError: "HTTP 403 (meeting artifacts)"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertTrue(m.recording.isFailed)
        XCTAssertTrue(m.transcript.isFailed)
        XCTAssertNotNil(m.notes.value)
        guard case .failed(let message) = m.recording else { return XCTFail("recording not failed") }
        XCTAssertTrue(message.contains("access denied"), message)
    }

    func testArtifactsNotesReadAsReadOnlyTextWithTheirIds() async {
        let t = FakeRecapTransport()
        let notes = MeetingRecapParse.ArtifactResource(type: "notes", location: Self.notes, drive_id: "b!drive",
                                                       drive_item_id: "01NOTES", file_title: "Budget Review notes")
        let chat = MeetingRecapParse.sources(from: Self.messages())
        t.sourcesResult = .success(MeetingRecapParse.merge(chat, artifacts: [notes], artifactsError: nil))
        t.notesResult = .success("Agenda\n\u{2022} Numbers")
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.notes.value?.text, "Agenda\n\u{2022} Numbers")
        XCTAssertEqual(m.notes.value?.title, "Budget Review notes")
        XCTAssertEqual(t.notesRefs.last?.drive_id, "b!drive")
        XCTAssertEqual(t.notesRefs.last?.item_id, "01NOTES")
        XCTAssertTrue(t.notesRefs.last?.json.contains("\"item_id\":\"01NOTES\"") ?? false)
    }

    func testRetryAfterFailedArtifactsReadKeepsShownParts() async {
        let t = FakeRecapTransport()
        t.transcriptResult = .success(Data(Self.transcriptJSON.utf8))
        let chat = MeetingRecapParse.sources(from: Array(Self.messages().prefix(1)))
        t.sourcesResult = .success(MeetingRecapParse.merge(chat, artifacts: [], artifactsError: "HTTP 503 (meeting artifacts)"))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertNotNil(m.recording.value)
        XCTAssertTrue(m.notes.isFailed)
        let notes = MeetingRecapParse.ArtifactResource(type: "notes", location: Self.notes)
        t.sourcesResult = .success(MeetingRecapParse.merge(chat, artifacts: [notes], artifactsError: nil))
        t.notesResult = .success("Agenda")
        m.retry()
        XCTAssertNotNil(m.recording.value, "a shown part never blanks on retry")
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.notes.value?.text, "Agenda")
        XCTAssertEqual(t.calls.filter { $0 == "recording" }.count, 1)
        XCTAssertEqual(t.calls.filter { $0 == "sources" }.count, 2)
    }

    func testLoopNotesHTMLBecomesReadOnlyText() {
        let html = """
        <html><head><title>x</title><style>p{color:red}</style></head><body>
        <h1>Agenda</h1><ul><li>Build&nbsp;status</li><li>Q&amp;A &#8212; &#x2713;</li></ul>
        <p>Line one<br/>Line two</p><script>var a = "<p>no</p>";</script>
        <table><tr><td>Owner</td><td>Tom Becker</td></tr></table><header>Top</header>
        </body></html>
        """
        let text = LoopNotesText.plain(fromHTML: html)
        XCTAssertEqual(text, "Agenda\n\n\u{2022} Build status\n\u{2022} Q&A \u{2014} \u{2713}\n\nLine one\nLine two\n\nOwner\tTom Becker\n\nTop")
        XCTAssertFalse(text.contains("color"))
        XCTAssertFalse(text.contains("var a"))
    }

    func testChatWithNoMeetingIdentityNeverReadsAsNone() async throws {
        // The core found no meeting identity (collab null): the artifacts
        // service was never asked, so nothing is proven absent.
        let json = #"{"ok":true,"messages":[],"pages":1,"complete":true,"meeting":null,"collab":null}"#
        let r = try JSONDecoder().decode(CoreMeetingRecapTransport.SourcesResponse.self, from: Data(json.utf8))
        let s = CoreMeetingRecapTransport.sources(from: r)
        XCTAssertEqual(s.artifactsError, MeetingRecapCopy.noIdentityError)
        let t = FakeRecapTransport()
        t.sourcesResult = .success(s)
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.recording, .failed(MeetingRecapCopy.noIdentity))
        XCTAssertEqual(m.transcript, .failed(MeetingRecapCopy.noIdentity))
        XCTAssertEqual(m.notes, .failed(MeetingRecapCopy.noIdentity))
        XCTAssertEqual(m.aiRecap, .absent(MeetingRecapCopy.noAIRecap), "the thread-keyed recap still reads")
        // An artifacts answer (even empty) proves absence.
        let ok = #"{"ok":true,"messages":[],"pages":1,"complete":true,"collab":{"ok":true,"resources":[]}}"#
        let r2 = try JSONDecoder().decode(CoreMeetingRecapTransport.SourcesResponse.self, from: Data(ok.utf8))
        XCTAssertNil(CoreMeetingRecapTransport.sources(from: r2).artifactsError)
    }

    func testTranscriptInUnknownFormatIsAnErrorNotNone() async {
        XCTAssertThrowsError(try TeamsTranscriptJSON.parseStrict(Data("<html>Sign in</html>".utf8)))
        XCTAssertEqual(try TeamsTranscriptJSON.parseStrict(Data("\u{FEFF}WEBVTT\n\n".utf8)), [])
        let t = FakeRecapTransport()
        t.sourcesResult = .success(MeetingRecapParse.sources(from: Array(Self.messages().prefix(1))))
        t.transcriptResult = .success(Data("<html>Sign in</html>".utf8))
        let m = model(t)
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.transcript, .failed(MeetingRecapCopy.transcriptUnreadable))
    }

    func testChatlessRecapWithAFailedDriveListIsAnErrorNotNone() async {
        let t = FakeRecapTransport()
        let rec = RecordingItem(id: "rec-9", name: "Budget Review.mp4", download_url: "https://contoso-my.sharepoint.com/dl")
        let m = MeetingRecapViewModel(threadID: nil, title: "Budget Review", fileRecording: rec, transport: t,
                                      download: { _, _, _ in throw CoreCallError.failed("no") })
        m.load()
        _ = await waitFor { !m.isLoading }
        XCTAssertEqual(m.transcript, .absent(MeetingRecapCopy.noTranscript))
        m.updateListErrors(recordings: nil, transcripts: "HTTP 403 (transcripts)")
        _ = await waitFor { !m.isLoading }
        XCTAssertTrue(m.transcript.isFailed)
        XCTAssertEqual(m.recording.value?.id, "rec-9")
        // Renamed transcript fields are an unknown format, not an empty transcript.
        let renamed = Data(#"{"entries":[{"start":"00:00:01","words":"Hi","text":"Hi"}]}"#.utf8)
        XCTAssertThrowsError(try TeamsTranscriptJSON.parseStrict(renamed))
        XCTAssertEqual(try TeamsTranscriptJSON.parseStrict(Data(#"{"entries":[]}"#.utf8)), [])
    }
}
