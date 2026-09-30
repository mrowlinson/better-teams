// RecapLiveProbeTests.swift — opt-in live probe for the RECAP2 meeting-recap
// reads. RECAP_LIVE=1 to run; RECAP_LIVE_LOG=<path> also writes the lines.
// RECAP_LIVE_GETONLY=1 skips the two POST reads (Loop notes page, AI recap).
// Read-only: chat list GET, then the recap transport reads (sources,
// recording, transcript, notes, intelligent recap). No sends, no read
// state, no presence. Output is counts/booleans/status codes/enum names
// only: never titles, names, ids, URLs, text, or tokens.
import Foundation
import XCTest
@testable import OstMacCore

final class RecapLiveProbeTests: XCTestCase {
    /// Error class only: an HTTP status number, "noIdentity", or "error".
    static func errClass(_ raw: String) -> String {
        if raw == MeetingRecapCopy.noIdentityError { return "noIdentity" }
        if let r = raw.range(of: #"HTTP \d{3}"#, options: .regularExpression) {
            return String(raw[r])
        }
        return "error"
    }

    static func errClassOf(_ e: Error) -> String {
        if case CoreCallError.failed(let m) = e { return errClass(m) }
        return errClass(String(describing: e))
    }

    /// Lines that would leak identifiers/URLs.
    static func leaks(_ lines: [String]) -> [String] {
        lines.filter { $0.contains("@") || $0.contains("http") || $0.contains("19:") }
    }

    func testLeakCheckCatchesSample() {
        XCTAssertEqual(Self.leaks(["RECAPLIVE x@y"]).count, 1)
        XCTAssertEqual(Self.leaks(["RECAPLIVE see https://a"]).count, 1)
        XCTAssertEqual(Self.leaks(["RECAPLIVE 19:abc"]).count, 1)
        XCTAssertTrue(Self.leaks(["RECAPLIVE chat1 recordings=1"]).isEmpty)
        XCTAssertEqual(Self.errClass("x HTTP 403 y"), "HTTP 403")
        XCTAssertEqual(Self.errClass(MeetingRecapCopy.noIdentityError), "noIdentity")
        XCTAssertEqual(Self.errClass("boom https://a@b"), "error")
    }

    func testLiveRecapReads() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RECAP_LIVE"] == "1" else {
            throw XCTSkip("set RECAP_LIVE=1 to run the read-only meeting-recap probe")
        }
        let getOnly = env["RECAP_LIVE_GETONLY"] == "1"
        var log: [String] = []
        func note(_ s: String) {
            let line = "RECAPLIVE " + s
            print(line)
            log.append(line)
        }
        defer {
            if let path = env["RECAP_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let t0 = Date()
        let list: [ChatItem]
        do {
            list = ChatListViewModel.recencyOrdered(try CoreReads.chats(limit: 200).chats)
        } catch {
            note("chatList error=\(Self.errClassOf(error))")
            note("elapsedSeconds=\(Int(Date().timeIntervalSince(t0)))")
            XCTAssertTrue(Self.leaks(log).isEmpty)
            return
        }
        let meeting = list.filter { $0.chatId.contains("19:meeting_") }
        note("chatList total=\(list.count) meetingChats=\(meeting.count)")
        let transport = CoreMeetingRecapTransport()
        var withRefs: [(Int, ChatItem, MeetingRecapSources)] = []
        for (i, chat) in meeting.prefix(6).enumerated() {
            let label = "chat\(i + 1)"
            do {
                let s = try transport.sources(threadID: chat.chatId)
                let ae = s.artifactsError.map { Self.errClass($0) } ?? "none"
                note("\(label) sources recordings=\(s.recordings.count) transcripts=\(s.transcripts.count) "
                    + "notes=\(s.notes.count) pages=\(s.pages ?? -1) complete=\(s.complete ?? false) artifactsError=\(ae)")
                if !s.isEmpty { withRefs.append((i + 1, chat, s)) }
            } catch {
                note("\(label) sources error=\(Self.errClassOf(error))")
            }
        }
        for (n, chat, s) in withRefs.prefix(3) {
            let label = "chat\(n)"
            if let rec = s.playable ?? s.recordings.last {
                do {
                    let item = try transport.recording(rec.target)
                    let stream = !(item.download_url ?? "").isEmpty || !(item.web_url ?? "").isEmpty
                    note("\(label) recording ok=true hasStream=\(stream) durationPositive=\((item.duration_ms ?? rec.duration_ms ?? 0) > 0)")
                } catch {
                    note("\(label) recording error=\(Self.errClassOf(error))")
                }
            } else {
                note("\(label) recording none")
            }
            if let target = s.transcriptTarget {
                do {
                    if let data = try transport.transcript(target) {
                        let json = TeamsTranscriptJSON.cues(from: data)
                        let format: String
                        let cues: [TranscriptCue]
                        if let j = json {
                            format = "teamsJSON"; cues = j
                        } else {
                            cues = parseVTT(String(decoding: data, as: UTF8.self))
                            format = cues.isEmpty ? "unknown" : "vtt"
                        }
                        let speakers = Set(cues.compactMap(\.speaker)).count
                        let offsets = cues.contains { $0.startMs > 0 || $0.endMs > 0 }
                        note("\(label) transcript bytes=\(data.count) lines=\(cues.count) speakers=\(speakers) hasOffsets=\(offsets) format=\(format)")
                    } else {
                        note("\(label) transcript none")
                    }
                } catch {
                    note("\(label) transcript error=\(Self.errClassOf(error))")
                }
            } else {
                note("\(label) transcript noTarget")
            }
            if getOnly {
                note("\(label) notes skipped(getOnly) refs=\(s.notes.count)")
            } else if let nref = s.notes.first {
                do {
                    if let text = try transport.notesText(nref) {
                        note("\(label) notes chars=\(text.count)")
                    } else {
                        note("\(label) notes addressOnly")
                    }
                } catch {
                    note("\(label) notes error=\(Self.errClassOf(error))")
                }
            } else {
                note("\(label) notes none")
            }
            if getOnly { continue }
            do {
                if let ai = try transport.intelligentRecap(threadID: chat.chatId, fileURL: s.playable?.file_url) {
                    note("\(label) ai present notes=\(ai.notes.count) tasks=\(ai.followUps.count) unavailable=\(ai.unavailableReason != nil)")
                } else {
                    note("\(label) ai nil")
                }
            } catch {
                note("\(label) ai error=\(Self.errClassOf(error))")
            }
        }
        note("elapsedSeconds=\(Int(Date().timeIntervalSince(t0)))")
        let bad = Self.leaks(log)
        XCTAssertTrue(bad.isEmpty, "leak check failed on \(bad.count) line(s)")
    }
}
