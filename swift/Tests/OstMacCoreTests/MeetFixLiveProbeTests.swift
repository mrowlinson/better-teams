// MeetFixLiveProbeTests.swift — opt-in live proof of the meeting lobby lane
// (MEETFIX_B, lanes/meetfix). ONE live session per run:
//   solo meeting (subject "test") -> join muted/camera-off -> poll roster
//   ~20 s (counts only) -> headless Chrome guest ("test") x3 ->
//   deny / admit / admitAll -> callEnd -> DELETE event.
// Counts and booleans only; never subjects, names, ids, tokens or URLs.
// Auth or shape surprise -> XCTFail (SCOPE GATE: parent writes PLAN2.md).
import Foundation
import XCTest
@testable import OstMacCore

final class MeetFixLiveProbeTests: XCTestCase {
    private var log: [String] = []

    private func note(_ s: String) {
        print("PROBE \(s)")
        log.append(s)
    }

    private func guestEnv(_ joinURL: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MEET_JOIN_URL"] = joinURL
        return env
    }

    /// Run the headless-Chrome guest script; returns its one JSON line.
    private func guest(_ action: String, joinURL: String) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard let node = env["MEETFIX_NODE"], let js = env["MEETFIX_GUEST_JS"] else {
            throw NSError(domain: "MeetFixLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MEETFIX_NODE/MEETFIX_GUEST_JS unset"])
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [js, action]
        var full = env
        full["MEET_JOIN_URL"] = joinURL
        task.environment = full
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MeetFixLive", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "guest script unreadable output"])
        }
        return obj
    }

    private func roster() throws -> CallRosterPoll { try RustCore.callRoster() }

    /// Sanitize any guest JSON for the log: no URLs, no tokens, no ids.
    private func san(_ s: String) -> String {
        var o = s
        o = o.replacingOccurrences(of: "https?://[^\\s\"]+", with: "<url>",
                                   options: .regularExpression)
        o = o.replacingOccurrences(of: "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",
                                   with: "<jwt>", options: .regularExpression)
        if o.count > 2000 { o = String(o.prefix(2000)) + "…" }
        return o
    }

    private func guestJSON(_ gj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: gj)) ?? Data()
        return san(String(data: data, encoding: .utf8) ?? "<unencodable>")
    }

    /// Poll until `check` passes; returns whether it passed in time.
    private func waitUntil(_ label: String, timeout: TimeInterval,
                          _ check: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try check() { return true }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return (try? check()) ?? false
    }

    func testLiveMeetingLobbyAdmitCycle() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETFIX_LIVE"] == "1" else {
            throw XCTSkip("set MEETFIX_LIVE=1 to run the live meeting-lobby probe")
        }
        defer {
            if let path = env["MEETFIX_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        let guestName = env["MEET_GUEST_NAME"] ?? "test"
        let g = CalendarGraph.production()
        let now = Date()
        note("create enter")
        let created: MeetingItem
        do {
            created = try g.create(subject: "test", start: now,
                                   end: now.addingTimeInterval(1800), online: true)
            note("create exit ok")
        } catch {
            note("create throw type=\(type(of: error)) desc=\(String(describing: error)) loc=\(error.localizedDescription)")
            throw error
        }
        var deleted = false
        defer {
            try? g.delete(id: created.meetingId)
            deleted = (try? g.detail(id: created.meetingId)) == nil
            note("deleteConfirmed=\(deleted)")
        }
        guard let joinURL = created.joinURL, !joinURL.isEmpty else {
            XCTFail("created meeting has no joinURL (shape surprise)")
            return
        }
        note("created joinPresent=true online=\(created.isOnline)")

        note("coords enter")
        let parsed = JoinParse.parse(raw: joinURL)
        guard parsed.kind == "thread", let thread = parsed.threadID, !thread.isEmpty else {
            XCTFail("join link parses as non-thread (shape surprise, want thread)")
            return
        }
        let target = JoinTarget(kind: parsed.kind, threadID: thread,
                                meetingID: parsed.meetingID, url: parsed.url)
        let coords = JoinParse.meetingCoordinates(joinURL)
        note("target thread=true msgID=\(coords.messageID != nil) org=\(coords.organizerOID != nil) ten=\(coords.tenantID != nil)")
        guard coords.messageID != nil, coords.organizerOID != nil, coords.tenantID != nil else {
            XCTFail("join link missing meeting coordinates (shape surprise)")
            return
        }
        note("coords exit ok")

        // Propagation probe: 30s stillness between coords-verified and
        // first join attempt (tests the lag theory at a different point).
        note("sleep30 enter")
        Thread.sleep(forTimeInterval: 30.0)
        note("sleep30 exit")

        // Mute in its OWN do/catch so a mute throw names mute, not join.
        note("mute enter")
        var muteSticky = false
        do {
            let mute = try RustCore.callMute(muted: true)
            muteSticky = mute.muted
            note("mute exit ok muted=\(muteSticky)")
        } catch {
            note("mute throw type=\(type(of: error)) desc=\(String(describing: error)) loc=\(error.localizedDescription)")
            throw error
        }

        // JOIN-TOO-SOON-AFTER-CREATE: server Graph store lags create by
        // seconds; retry 404s up to ~90s. Any other throw fails fast.
        note("join enter")
        var res: CallResult?
        var joinAttempts = 0
        let joinDeadline = Date().addingTimeInterval(90)
        while true {
            joinAttempts += 1
            do {
                var req = MeetingJoinRequest(target: target)
                req.video = false
                res = try RustCore.callJoinMeeting(req)
                note("join exit ok attempts=\(joinAttempts)")
                break
            } catch {
                let msg = String(describing: error)
                if msg.contains("404") {
                    if Date() < joinDeadline {
                        note("join 404 attempt=\(joinAttempts) retrying type=\(type(of: error))")
                        Thread.sleep(forTimeInterval: 5.0)
                        continue
                    }
                    XCTFail("join 404 persistent >90s (not propagation)")
                    return
                }
                note("join throw type=\(type(of: error)) desc=\(String(describing: error)) loc=\(error.localizedDescription)")
                throw error
            }
        }
        guard let res else {
            XCTFail("join produced no response")
            return
        }
        let joined = res.accepted == true || res.call?.state == "connected"
        let joinedCallId = res.call?.id ?? ""
        let joinedState = res.call?.state ?? "<none>"
        note("join ok=\(res.ok) accepted=\(res.accepted == true) stateConnected=\(res.call?.state == "connected") muteSticky=\(muteSticky) attempts=\(joinAttempts)")
        guard joined else {
            XCTFail("core join not accepted (auth surprise?)")
            return
        }
        defer { _ = try? RustCore.callEnd() }

        // Baseline roster poll (counts + shapes only): joined call id vs
        // roster call id (Bug-A check), roster log lines (frame evidence),
        // call state. 20 polls; log drains each call so lines stream out.
        var baseRows = 0
        for i in 0..<20 {
            if let r = try? roster() {
                baseRows = r.participants.count
                let selfPresent = r.participants.contains { $0.isSelf }
                let match = !joinedCallId.isEmpty && r.callId == joinedCallId
                note("poll rows=\(r.participants.count) self=\(selfPresent) lobby=\(r.lobby?.count ?? -1) updates=\(r.updates) callMatch=\(match) state=\(joinedState)")
                for line in r.log { note("rlog[\(i)] \(san(line))") }
            } else {
                note("poll throw")
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Admit-shape cycle, one guest join each: deny, admit, admitAll.
        let r0 = try roster()
        note("links lobbyKeyPresent=\(r0.lobby != nil)")

        func lobbyWaiters() throws -> [CallLobbyParticipant] { try roster().lobby ?? [] }

        // 1. Deny.
        var gj = try guest("join", joinURL: joinURL)
        note("guest1 json=\(guestJSON(gj))")
        guard (try? waitUntil("lobby1", timeout: 90) { try lobbyWaiters().count == 1 }) == true else {
            XCTFail("guest1 never reached lobby")
            return
        }
        note("guest1 inLobby=true nameMatch=\((try? lobbyWaiters().first?.name == guestName) ?? false)")
        let w1 = try lobbyWaiters()
        try RustCore.callLobbyDeny(id: w1[0].id, name: w1[0].name)
        let deniedGone = waitUntil("deny", timeout: 30) {
            (try? lobbyWaiters().isEmpty) ?? false
        }
        let afterDeny = try roster()
        note("deny lobbyEmpty=\(deniedGone) rowsBackToBase=\(afterDeny.participants.count == baseRows)")
        XCTAssertTrue(deniedGone)
        _ = try? guest("leave", joinURL: joinURL)
        Thread.sleep(forTimeInterval: 3.0)

        // 2. Admit.
        gj = try guest("join", joinURL: joinURL)
        note("guest2 json=\(guestJSON(gj))")
        guard (try? waitUntil("lobby2", timeout: 90) { try lobbyWaiters().count == 1 }) == true else {
            XCTFail("guest2 never reached lobby")
            return
        }
        let w2 = try lobbyWaiters()
        try RustCore.callLobbyAdmit(id: w2[0].id, name: w2[0].name)
        let admitted = waitUntil("admit", timeout: 30) {
            let r = (try? roster())
            return (r?.lobby?.isEmpty ?? false)
                && (r?.participants.contains { $0.name == guestName && !$0.isSelf } ?? false)
        }
        let afterAdmit = try roster()
        note("admit inCall=\(admitted) rowsPlusOne=\(afterAdmit.participants.count == baseRows + 1)")
        XCTAssertTrue(admitted)
        _ = try? guest("leave", joinURL: joinURL)
        let left = waitUntil("leave2", timeout: 30) {
            ((try? roster().participants.count) ?? -1) == baseRows
        }
        note("guest2 left rowsBackToBase=\(left)")

        // 3. Admit all.
        gj = try guest("join", joinURL: joinURL)
        note("guest3 json=\(guestJSON(gj))")
        guard (try? waitUntil("lobby3", timeout: 90) { try lobbyWaiters().count == 1 }) == true else {
            XCTFail("guest3 never reached lobby")
            return
        }
        try RustCore.callLobbyAdmitAll()
        let admittedAll = waitUntil("admitAll", timeout: 30) {
            let r = (try? roster())
            return (r?.lobby?.isEmpty ?? false)
                && (r?.participants.contains { $0.name == guestName && !$0.isSelf } ?? false)
        }
        note("admitAll inCall=\(admittedAll)")
        XCTAssertTrue(admittedAll)
        _ = try? guest("leave", joinURL: joinURL)
        _ = waitUntil("leave3", timeout: 30) {
            ((try? roster().participants.count) ?? -1) == baseRows
        }

        let end = try RustCore.callEnd()
        note("callEnd ok=\(end.ok) ended=\(end.ended == true)")
    }
}
