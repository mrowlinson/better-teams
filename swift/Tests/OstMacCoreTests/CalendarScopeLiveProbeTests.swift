// CalendarScopeLiveProbeTests.swift — CAL-SCOPE opt-in live proof
// (CALSCOPE_LIVE=1). Read-only GET: past weeks' organizer online meetings
// → MT meeting options (names + values only, never subjects/URLs/tokens).
// Write (CALSCOPE_LIVE_WRITE=1): one self-only meeting (LiveTest.subject,
// attendees NONE) — Graph event-knob attempt, shipped production
// load/save + independent read-back, revert, DELETE, plus a month-range
// overlay read. Net zero.
import Foundation
import XCTest

@testable import OstMacCore

final class CalendarScopeLiveProbeTests: XCTestCase {
    private static func note(_ s: String, _ log: inout [String]) {
        print("HUNT \(s)")
        log.append(s)
    }

    func testHuntMeetingOptionsGET() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALSCOPE_LIVE"] == "1" else {
            throw XCTSkip("set CALSCOPE_LIVE=1 for the hunt probe")
        }
        var log: [String] = []
        defer {
            if let path = env["CALSCOPE_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let now = Date()
        var online: [MeetingItem] = []
        var scanned = 0
        var weekStart = CalWeek.startOfWeek(containing: now)
        for _ in 0 ..< 5 {
            let from = Calendar.current.startOfDay(for: weekStart)
            let rows = try g.range(from: from, to: from.addingTimeInterval(7 * 86_400))
            scanned += rows.count
            online += rows.filter { $0.joinURL?.contains("meetup-join") == true && $0.isOrganizer }
            if !online.isEmpty { break }
            weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        }
        Self.note("scanned=\(scanned) ownOnline=\(online.count)", &log)
        guard let first = online.first else {
            Self.note("noJoinMeeting=none", &log)
            return
        }
        Self.note("pickedIsOrganizer=\(first.isOrganizer)", &log)
        guard let join = first.joinURL, let coords = MeetingCoordinates.fromJoinURL(join) else {
            Self.note("coords=no", &log)
            return
        }
        Self.note("coords=yes threadLen=\(coords.threadID.count) msg=\(coords.messageID)", &log)
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        let (status, opts) = MeetingOptionsReader.fetchRaw(
            slots: slots, now: ctx.now(), coords: coords, http: URLSessionCalendarHTTP())
        Self.note("mtStatus=\(status) optCount=\(opts.count)", &log)
        Self.note("optNames=\(opts.map(\.name).sorted().joined(separator: ","))", &log)
        for o in opts where o.name == MeetingOptionsReader.lobbyName || o.name == MeetingOptionsReader.presenterName {
            Self.note("opt \(o.name)=\(o.currentValue)", &log)
        }
        Self.note("lobby=\(MeetingOptionsReader.lobby(of: opts).map { $0.rawValue } ?? "nil")", &log)
        Self.note("presenters=\(MeetingOptionsReader.presenters(of: opts).map { $0.rawValue } ?? "nil")", &log)
    }

    func testCleanupOrphanAndRetry() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALSCOPE_LIVE"] == "1", env["CALSCOPE_LIVE_WRITE"] == "1" else {
            throw XCTSkip("set CALSCOPE_LIVE=1 and CALSCOPE_LIVE_WRITE=1 for the cleanup run")
        }
        var log: [String] = []
        defer {
            if let path = env["CALSCOPE_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let from = Calendar.current.startOfDay(for: Date())
        let rows = try g.range(from: from, to: from.addingTimeInterval(24 * 86_400))
        let orphans = rows.filter { $0.subject == LiveTest.subject }
        Self.note("orphans=\(orphans.count)", &log)
        guard let orphan = orphans.first,
              let join = orphan.joinURL,
              let coords = MeetingCoordinates.fromJoinURL(join) else {
            Self.note("noOrphan=nothing-to-do", &log)
            return
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        let http = URLSessionCalendarHTTP()
        func failNames(_ data: Data) -> String {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let names = obj["failedOptionNames"] as? [String] else { return "-" }
            return names.sorted().joined(separator: ",")
        }
        do {
            let (status, opts) = MeetingOptionsReader.fetchRaw(
                slots: slots, now: ctx.now(), coords: coords, http: http)
            Self.note("get=\(status) opts=\(opts.count)", &log)
            Self.note("lobbyRow=\(MeetingOptionsReader.lobbyRow(in: opts)?.name ?? "nil")"
                + " presRow=\(MeetingOptionsReader.presenterRow(in: opts)?.name ?? "nil")", &log)
            for o in opts where o.name == MeetingOptionsReader.lobbyRow(in: opts)?.name
                || o.name == MeetingOptionsReader.presenterRow(in: opts)?.name {
                Self.note("row \(o.name) type=\(o.type) cat=\(o.category ?? "-") val=\(o.currentValue)", &log)
            }
            guard !opts.isEmpty,
                  MeetingOptionsReader.lobbyRow(in: opts) != nil,
                  MeetingOptionsReader.presenterRow(in: opts) != nil else {
                Self.note("noRowsForRetry=yes", &log)
                try g.delete(id: orphan.meetingId)
                Self.note("deleted=\((try? g.detail(id: orphan.meetingId)) == nil)", &log)
                return
            }
            let origLobby = MeetingOptionsReader.lobby(of: opts)
            let origPres = MeetingOptionsReader.presenters(of: opts)
            let newLobby: MeetingLobbyBypass = (origLobby == .organizerOnly) ? .invited : .organizerOnly
            let newPres: MeetingPresenters = (origPres == .organizerOnly) ? .everyone : .organizerOnly
            // Attempt 1: full echo with category (client-faithful).
            guard let full = MeetingOptionsReader.body(rows: opts, lobby: newLobby, presenters: newPres) else {
                throw CoreCallError.failed("cleanup: no body")
            }
            let url = MeetingOptionsReader.url(
                middleTier: CoreReads.regionGTMS(slots)["middleTier"], coords: coords)!
            let headers = ["Authorization": "Bearer \(slots.accessToken!.token)",
                           "X-Skypetoken": "\(slots.skypeToken!.token)",
                           "x-ms-client-type": "desktop",
                           "Content-Type": "application/json", "Accept": "application/json"]
            let r1 = try http.send("POST", url: url, headers: headers, body: full)
            Self.note("postFull=\(r1.status) failed=\(failNames(r1.data))", &log)
            var okLobby: MeetingLobbyBypass?; var okPres: MeetingPresenters?
            if (200 ..< 300).contains(r1.status) {
                let back = try MeetingOptionsReader.load(meeting: orphan)
                okLobby = back.lobby; okPres = back.presenters
            } else if let sub = MeetingOptionsReader.bodySubset(rows: opts, lobby: newLobby, presenters: newPres) {
                // Attempt 2: subset (only the two rows).
                let r2 = try http.send("POST", url: url, headers: headers, body: sub)
                Self.note("postSubset=\(r2.status) failed=\(failNames(r2.data))", &log)
                if (200 ..< 300).contains(r2.status) {
                    let back = try MeetingOptionsReader.load(meeting: orphan)
                    okLobby = back.lobby; okPres = back.presenters
                }
            }
            Self.note("after lobby=\(okLobby?.rawValue ?? "nil") pres=\(okPres?.rawValue ?? "nil")", &log)
            Self.note("roundTrip=\(okLobby == newLobby && okPres == newPres)", &log)
            if let ol = origLobby, let op = origPres {
                _ = MeetingOptionsReader.postRaw(slots: slots, now: ctx.now(), coords: coords,
                                                 data: MeetingOptionsReader.body(
                                                     rows: opts, lobby: ol, presenters: op) ?? Data(),
                                                 http: http)
                let back = try MeetingOptionsReader.load(meeting: orphan)
                Self.note("reverted=\(back.lobby == ol && back.presenters == op)", &log)
            }
        } catch {
            Self.note("retryThrew=yes", &log)
        }
        try g.delete(id: orphan.meetingId)
        Self.note("deleted=\((try? g.detail(id: orphan.meetingId)) == nil)", &log)
    }

    func testHuntMeetingOptionsWrite() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALSCOPE_LIVE"] == "1", env["CALSCOPE_LIVE_WRITE"] == "1" else {
            throw XCTSkip("set CALSCOPE_LIVE=1 and CALSCOPE_LIVE_WRITE=1 for the write probe")
        }
        var log: [String] = []
        defer {
            if let path = env["CALSCOPE_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        // Month overlay read (read-only, second calendar over a 42-day window).
        do {
            let feeds = try g.calendars()
            let second = feeds.first { !$0.isDefault }
            Self.note("monthOverlay second=\(second != nil)", &log)
            if let second {
                let from = Calendar.current.startOfDay(for: Date())
                let rows = try g.calendarRange(id: second.id, from: from,
                                              to: from.addingTimeInterval(42 * 86_400))
                Self.note("monthOverlayRows=\(rows.count)", &log)
            }
        } catch {
            Self.note("monthOverlay=threw", &log)
        }
        let now = Date()
        let created = try g.create(subject: LiveTest.subject, start: now.addingTimeInterval(3600),
                                   end: now.addingTimeInterval(5400), online: true)
        Self.note("created join=\(created.joinURL != nil)", &log)
        var deleted = false
        defer { Self.note("deleted=\(deleted ? "yes" : "NO-delete-by-hand")", &log) }
        do {
            // Graph event-level attempt (expected closed): onlineMeeting knobs on the event.
            let patchStatus: String = {
                do {
                    _ = try g.request("PATCH", "/me/events/\(CalendarGraph.encode(created.meetingId))", json: [
                        "onlineMeeting": [
                            "lobbyBypassSettings": ["scope": "everyone"],
                            "allowedPresenters": "everyone",
                        ],
                    ])
                    return "applied-2xx"
                } catch {
                    return "threw"
                }
            }()
            Self.note("graphPatchAttempt=\(patchStatus)", &log)
            // Shipped production path: load (row names logged), save, independent read-back.
            let first: MeetingOptionsReader.Selection
            do {
                first = try MeetingOptionsReader.load(meeting: created)
            } catch {
                Self.note("prodLoad=threw", &log)
                try g.delete(id: created.meetingId)
                deleted = (try? g.detail(id: created.meetingId)) == nil
                return
            }
            Self.note("prodLoad ok lobbyRow=\(first.lobbyRowName ?? "nil")"
                + " presRow=\(first.presenterRowName ?? "nil")", &log)
            Self.note("orig lobby=\(first.lobby?.rawValue ?? "nil") pres=\(first.presenters?.rawValue ?? "nil")", &log)
            guard first.lobbyRowName != nil, first.presenterRowName != nil else {
                Self.note("noMatchingRows=yes", &log)
                try g.delete(id: created.meetingId)
                deleted = (try? g.detail(id: created.meetingId)) == nil
                return
            }
            let newLobby: MeetingLobbyBypass = (first.lobby == .organizerOnly) ? .invited : .organizerOnly
            let newPres: MeetingPresenters = (first.presenters == .organizerOnly) ? .everyone : .organizerOnly
            let saved = try MeetingOptionsReader.save(meeting: created, lobby: newLobby, presenters: newPres)
            Self.note("prodSave lobby=\(saved.lobby?.rawValue ?? "nil")"
                + " pres=\(saved.presenters?.rawValue ?? "nil")", &log)
            let reread = try MeetingOptionsReader.load(meeting: created)
            Self.note("readBack lobby=\(reread.lobby?.rawValue ?? "nil")"
                + " pres=\(reread.presenters?.rawValue ?? "nil")", &log)
            Self.note("roundTrip=\(reread.lobby == newLobby && reread.presenters == newPres)", &log)
            if let ol = first.lobby, let op = first.presenters {
                let reverted = try MeetingOptionsReader.save(meeting: created, lobby: ol, presenters: op)
                Self.note("reverted=\(reverted.lobby == ol && reverted.presenters == op)", &log)
            }
            try g.delete(id: created.meetingId)
            deleted = (try? g.detail(id: created.meetingId)) == nil
        }
    }
}
