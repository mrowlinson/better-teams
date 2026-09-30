// CalendarDetailActions.swift — CALDETAIL lane: the details popup's
// actions on `CalendarWeekStore` past RSVP/edit: personal fields (show
// as, reminder, categories, private) on any copy, forward, remove an
// invitation from the calendar, attachment download, free/busy for the
// scheduling assistant, duplicate and webinar drafts. Live calls run
// detached (blocking Graph); demo (`localEdits`) stays in memory.
import Foundation

extension CalendarWeekStore {
    // MARK: personal fields

    /// Show as / reminder / categories / private on `row` (organizer or
    /// attendee: these live on the user's own copy). Applied at once;
    /// a failure rolls back and sets `personalError`.
    @discardableResult
    public func setPersonal(_ row: MeetingItem, _ patch: CalendarEventPatch) async -> Bool {
        guard patch.isPersonal, !patch.isEmpty else { return false }
        let saved = (meetings, monthMeetings, weekCache, details, state)
        mutateRows({ $0.id == row.id }) { patch.applied(to: $0) }
        personalError = nil
        if localEdits { return true }
        let runner = runners.update
        let id = row.id
        do {
            var updated = try await Task.blocking { try runner(id, patch) }.value
            if let r = patch.reminderMinutes, r < 0, updated.info?.reminderMinutes != nil {
                // Reminder off: confirm with a fresh read (the PATCH reply
                // can still carry the old reminder).
                let detail = runners.detail
                let fresh: CalendarEventDetail? = try? await Task.blocking { try detail(id) }.value
                if let fresh { updated = fresh.event }
                if updated.info?.reminderMinutes != nil {
                    personalError = "Outlook kept the reminder on for this event"
                }
            }
            let final = updated
            mutateRows({ $0.id == id }, { _ in final })
            return true
        } catch {
            (meetings, monthMeetings, weekCache, details, state) = saved
            personalError = Self.message(for: error)
            return false
        }
    }

    public func clearPersonalError() {
        personalError = nil
        removeError = nil
    }

    /// Categorize: read the master list once (fallback: Outlook's
    /// defaults plus names in use), keeping what's shown meanwhile.
    public func loadCategories() {
        let seen = meetings + monthMeetings
        if categoryList.isEmpty { categoryList = CalendarCategory.merged(nil, seen: seen) }
        guard !categoriesLoaded, !localEdits else { return }
        categoriesLoaded = true
        let runner = runners.categories
        Task {
            let master = try? await Task.blocking { try runner() }.value
            categoryList = CalendarCategory.merged(master, seen: meetings + monthMeetings)
        }
    }

    // MARK: forward

    /// Forward the invitation to `recipients` (SMTP addresses).
    @discardableResult
    public func forward(_ row: MeetingItem, to recipients: [String], comment: String = "") async -> Bool {
        let to = recipients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !to.isEmpty else {
            forwardError = "Add at least one recipient"
            return false
        }
        guard to.allSatisfy(Self.looksLikeAddress) else {
            forwardError = "Enter email addresses"
            return false
        }
        guard !forwarding else { return false }
        forwardError = nil
        if localEdits { return true }
        forwarding = true
        defer { forwarding = false }
        let runner = runners.forward
        let id = row.id
        do {
            try await Task.blocking { try runner(id, to, comment) }.value
            return true
        } catch {
            forwardError = Self.message(for: error)
            return false
        }
    }

    public func clearForwardError() { forwardError = nil }

    nonisolated static func looksLikeAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
    }

    /// Recipients typed as "a@x.com; b@y.com" / commas / newlines.
    nonisolated public static func recipients(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: remove (attendee Delete)

    /// Attendee "Delete": `decline` answers the organizer (Decline and
    /// delete); otherwise the event leaves only this calendar, no
    /// response sent. Organizers cancel instead (`cancel(eventID:)`).
    public func removeFromCalendar(_ row: MeetingItem, decline: Bool, series: Bool = false) {
        guard !row.isOrganizer else { return }
        if decline {
            respond(to: row, .decline, series: series)
            return
        }
        let master = row.info?.seriesMasterID
        let target = series ? (master ?? row.id) : row.id
        let match: (MeetingItem) -> Bool = series && master != nil
            ? { $0.info?.seriesMasterID == master || $0.id == row.id }
            : { $0.id == row.id }
        let saved = (meetings, monthMeetings, weekCache, details, state)
        mutateRows(match) { _ in nil }
        removeError = nil
        if localEdits { return }
        let runner = runners.remove
        Task {
            do {
                try await Task.blocking { try runner(target) }.value
            } catch {
                (meetings, monthMeetings, weekCache, details, state) = saved
                removeError = Self.message(for: error)
            }
        }
    }

    // MARK: attachments

    /// Download `file` of `eventID` into `downloadsFolder()` (never
    /// overwriting: "name 2.ext"); returns the saved file.
    @discardableResult
    public func downloadAttachment(eventID: String, _ file: EventAttachment) async -> URL? {
        if let done = savedAttachments[file.id], FileManager.default.fileExists(atPath: done.path) { return done }
        guard !downloading.contains(file.id) else { return nil }
        downloading.insert(file.id)
        attachmentErrors[file.id] = nil
        defer { downloading.remove(file.id) }
        let bytes: Data
        if localEdits {
            bytes = Data("Demo attachment: \(file.name)\n".utf8)
        } else {
            let runner = runners.attachment
            do {
                bytes = try await Task.blocking { try runner(eventID, file.id) }.value
            } catch {
                attachmentErrors[file.id] = Self.message(for: error)
                return nil
            }
        }
        let dir = downloadsFolder()
        let dest = Self.freeDestination(dir: dir, name: file.fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dest, options: .atomic)
        } catch {
            attachmentErrors[file.id] = "Couldn\u{2019}t save \u{201C}\(file.fileName)\u{201D}"
            return nil
        }
        savedAttachments[file.id] = dest
        return dest
    }

    /// First free "name.ext", "name 2.ext", … in `dir`.
    nonisolated static func freeDestination(dir: URL, name: String) -> URL {
        var dest = dir.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return dest
    }

    // MARK: scheduling assistant

    /// Free/busy for `emails` over `[from, to)`. The previous grid stays
    /// on screen until the new one lands (no blank flash).
    public func loadFreeBusy(_ emails: [String], from: Date, to: Date) {
        let list = Array(Set(emails.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
        guard !list.isEmpty else { return }
        freeBusyError = nil
        if localEdits {
            freeBusy = CalendarDemo.freeBusy(list, rows: meetings, from: from, to: to)
            return
        }
        freeBusyLoading = true
        let runner = runners.schedule
        Task {
            do {
                let got = try await Task.blocking { try runner(list, from, to) }.value
                freeBusy = got
            } catch {
                freeBusyError = Self.message(for: error)
            }
            freeBusyLoading = false
        }
    }

    // MARK: duplicate / webinar

    /// Create `draft` (Duplicate). Returns the row, or nil with
    /// `createError` set.
    public func create(_ draft: CalendarEventDraft) async -> MeetingItem? {
        let name = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            createError = "Title is required"
            return nil
        }
        guard draft.end > draft.start else {
            createError = "End must be after start"
            return nil
        }
        guard !creating else { return nil }
        createError = nil
        let row: MeetingItem
        if localEdits {
            meetNowCount += 1
            let tz = calendar.timeZone
            let id = (demoGate != nil ? "demo-cal-copy-" : "local-copy-") + "\(meetNowCount)"
            row = MeetingItem(
                meetingId: id, subject: name,
                start: CalendarTime.wallClock(draft.start, in: tz), end: CalendarTime.wallClock(draft.end, in: tz),
                joinURL: draft.online ? "https://teams.microsoft.com/l/meetup-join/19:meeting_\(id)@thread.v2/0" : nil,
                organizer: demoGate != nil ? CalendarDemo.owner : nil,
                organizerEmail: demoGate != nil ? CalendarDemo.ownerEmail : nil,
                isOrganizer: true, isOnline: draft.online, categories: draft.categories, isAllDay: draft.isAllDay,
                info: CalendarEventInfo(location: draft.location, myResponse: .organizer, showAs: draft.showAs ?? "busy",
                                        attendees: draft.attendees, sensitivity: draft.sensitivity,
                                        reminderMinutes: draft.reminderMinutes))
        } else {
            creating = true
            defer { creating = false }
            let runner = runners.create
            var d = draft
            d.subject = name
            let sent = d
            do {
                row = try await Task.blocking { try runner(sent) }.value
            } catch {
                createError = Self.message(for: error)
                return nil
            }
        }
        insert(row)
        return row
    }

    /// Create a draft Teams webinar; returns its id (publishing and
    /// registration stay in Teams).
    public func createWebinar(title: String, start: Date, end: Date) async -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            createError = "Title is required"
            return nil
        }
        guard end > start else {
            createError = "End must be after start"
            return nil
        }
        guard !creating else { return nil }
        createError = nil
        if localEdits { return "demo-webinar-\(Int(start.timeIntervalSince1970))" }
        creating = true
        defer { creating = false }
        let runner = runners.webinar
        do {
            return try await Task.blocking { try runner(name, start, end) }.value
        } catch {
            createError = Self.message(for: error)
            return nil
        }
    }

    /// The series master id of `m` (itself when it is the master); nil
    /// for a one-off.
    public static func seriesID(of m: MeetingItem) -> String? {
        guard let info = m.info, info.kind.isSeries else { return nil }
        return info.kind == .seriesMaster ? m.id : info.seriesMasterID
    }

    /// Read a series' occurrences once (-30 days ... +180 days).
    public func loadInstances(series id: String, force: Bool = false) {
        guard force || seriesInstances[id] == nil, !instancesLoading.contains(id) else { return }
        let from = Date().addingTimeInterval(-30 * 86_400)
        let to = Date().addingTimeInterval(180 * 86_400)
        instancesError[id] = nil
        if localEdits {
            if let gate = demoGate {
                seriesInstances[id] = CalendarDemo.instances(gate, series: id, from: from, to: to, calendar: calendar)
            }
            return
        }
        instancesLoading.insert(id)
        let runner = runners.instances
        Task {
            do {
                let rows = try await Task.blocking { try runner(id, from, to) }.value
                seriesInstances[id] = rows.sorted { ($0.start ?? "") < ($1.start ?? "") }
            } catch {
                instancesError[id] = Self.message(for: error)
            }
            instancesLoading.remove(id)
        }
    }

    public func clearCreateError() { createError = nil }
}
