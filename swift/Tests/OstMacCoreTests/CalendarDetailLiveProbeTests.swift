// CalendarDetailLiveProbeTests.swift — CALDETAIL lane, opt-in live
// proof (CALDETAIL_LIVE=1). Read-only: own calendarView counts (header
// tally vs attendee groups for up to 3 events) and which endpoints the
// Teams web token can reach (status codes only). With
// CALDETAIL_LIVE_WRITE=1 also one solo meeting (subject "test", no
// attendees): show-as, reminder, category and private edited, then
// deleted. Prints numbers and booleans only — never subjects, names,
// addresses, tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class CalendarDetailLiveProbeTests: XCTestCase {
    private static func status(_ run: () throws -> Void) -> String {
        do {
            try run()
            return "200"
        } catch {
            let text = "\(error)"
            if let r = text.range(of: #"HTTP \d{3}"#, options: .regularExpression) { return String(text[r].dropFirst(5)) }
            return text.contains("401") ? "401" : "error"
        }
    }

    func testLiveDetailCountsEndpointsAndPersonalEdits() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALDETAIL_LIVE"] == "1" else {
            throw XCTSkip("set CALDETAIL_LIVE=1 to run the live calendar-details probe")
        }
        var log: [String] = []
        func note(_ s: String) {
            print("PROBE \(s)")
            log.append(s)
        }
        defer {
            if let path = env["CALDETAIL_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let from = Calendar.current.startOfDay(for: CalWeek.startOfWeek(containing: Date()))
        let rows = try g.range(from: from.addingTimeInterval(-14 * 86_400), to: from.addingTimeInterval(21 * 86_400))
        let withPeople = rows.filter { ($0.info?.people.count ?? 0) >= 2 }
        note("rows=\(rows.count) withAttendees=\(withPeople.count)")
        for (i, m) in withPeople.prefix(3).enumerated() {
            let people = m.info?.people ?? []
            let organizerEntries = people.filter { a in
                a.response == .organizer || (!a.email.isEmpty && a.email.lowercased() == m.organizerEmail?.lowercased())
            }.count
            let oldAccepted = people.filter { $0.response == .accepted || $0.response == .organizer }.count
            let t = m.tally
            let groups = CalendarEventInfo.groups(m.invitees)
            let listAccepted = groups.first { $0.bucket == .accepted }?.people.count ?? 0
            note("event\(i + 1) attendees=\(people.count) organizerEntries=\(organizerEntries) "
                + "oldHeaderAccepted=\(oldAccepted) header=\(t.accepted)/\(t.tentative)/\(t.declined)/\(t.pending) "
                + "listAccepted=\(listAccepted) listTotal=\(groups.reduce(0) { $0 + $1.people.count }) "
                + "consistent=\(t.accepted == listAccepted && t.total == groups.reduce(0) { $0 + $1.people.count })")
        }
        note("sentOnPresent=\(rows.filter { $0.info?.sentAt != nil }.count)/\(rows.count) "
            + "categorized=\(rows.filter { !$0.categories.isEmpty }.count) webinarLike=\(rows.filter { $0.eventType == .webinar }.count)")
        note("GET me=\(Self.status { _ = try g.selfAddress() })")
        note("GET masterCategories=\(Self.status { _ = try g.masterCategories() })")
        let me = (try? g.selfAddress()) ?? ""
        note("POST getSchedule(self)=\(Self.status { _ = try g.schedule(for: [me], from: from, to: from.addingTimeInterval(86_400)) })")
        note("GET webinars=\(Self.status { try g.request("GET", "/solutions/virtualEvents/webinars?$top=1") })")
        if let withFiles = rows.first(where: { $0.info?.hasAttachments == true }) {
            note("GET attachments=\(Self.status { _ = try g.detail(id: withFiles.meetingId) })")
        } else {
            note("attachments: none in range")
        }

        guard env["CALDETAIL_LIVE_WRITE"] == "1" else { return }
        let now = Date()
        let created = try g.create(subject: "test", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000),
                                   online: true)
        note("created attendees=\(created.info?.people.count ?? -1) join=\(created.joinURL != nil)")
        var deleted = false
        defer { note("deleted: \(deleted ? "yes" : "NO — solo test meeting left; id in log") \(deleted ? "" : created.meetingId)") }
        let category = (try? g.masterCategories())?.first?.name
        let edited = try g.update(id: created.meetingId, patch: CalendarEventPatch(
            showAs: "free", reminderMinutes: 5, categories: category.map { [$0] }, sensitivity: "private"))
        note("edited showAsFree=\(edited.info?.showAs == "free") reminder5=\(edited.info?.reminderMinutes == 5) "
            + "categorySet=\(category == nil ? "no-master-list" : "\(edited.categories == [category!])") "
            + "private=\(edited.info?.sensitivity == "private") subjectKept=\(edited.subject == "test")")
        let off = try g.update(id: created.meetingId, patch: CalendarEventPatch(reminderMinutes: -1))
        let reread = try? g.detail(id: created.meetingId).event
        note("reminderOff patchReply=\(off.info?.reminderMinutes == nil) reread=\(reread.map { $0.info?.reminderMinutes == nil } ?? false)")
        if reread?.info?.reminderMinutes != nil {
            // Variants: which PATCH body does Outlook honour for "off"?
            let path = "/me/events/\(CalendarGraph.encode(created.meetingId))"
            let variants: [(String, [String: Any])] = [
                ("offZero", ["isReminderOn": false, "reminderMinutesBeforeStart": 0]),
                ("offOnly2", ["isReminderOn": false]),
            ]
            for (name, body) in variants {
                _ = try? g.request("PATCH", path, json: body)
                Thread.sleep(forTimeInterval: 2)
                let again = try? g.detail(id: created.meetingId).event
                note("reminderOff variant \(name) reread=\(again.map { $0.info?.reminderMinutes == nil } ?? false) mins=\(again?.info?.reminderMinutes.map(String.init) ?? "nil")")
            }
        }
        try g.delete(id: created.meetingId)
        deleted = (try? g.detail(id: created.meetingId)) == nil
        note("deleteConfirmed=\(deleted)")
    }
}
