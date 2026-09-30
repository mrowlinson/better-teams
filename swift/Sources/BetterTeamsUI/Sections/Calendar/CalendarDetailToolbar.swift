// CalendarDetailToolbar.swift — the details popup's event commands: RSVP
// (a pop-up showing the current response) or Edit, Delete ▾, Forward,
// Duplicate | Show as ▾, Reminder ▾, Categorize ▾, Private | Apps ▾,
// Print, Download (.ics) … Join, Chat, and the Tracking inspector toggle.
// The pop-out window shows them in its NSToolbar (like a Mail message
// window, `EventDetailsWindowToolbar`); the sheet, which has no window
// toolbar, in a bar of bordered control groups (`EventDetailsToolbar`).
// Personal fields (show as, reminder, categories, private) apply to the
// user's own copy (organizer or attendee) and roll back on failure.
import AppKit
import OstMacCore
import SwiftUI

/// Sheet host: the commands as bordered control groups above the card.
struct EventDetailsToolbar: View {
    let meeting: MeetingItem
    let detail: CalendarEventDetail?
    @ObservedObject var week: CalendarWeekStore
    @Binding var trackingShown: Bool
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            EventRespondControl(meeting: meeting, week: week)
            EventActionsGroup(meeting: meeting, week: week, close: close)
            EventPersonalGroup(meeting: meeting, week: week)
            EventFilesGroup(meeting: meeting, detail: detail, info: meeting.info)
            Spacer(minLength: 8)
            EventJoinChat(meeting: meeting, close: close)
            EventTrackingToggle(shown: $trackingShown)
        }
        .buttonStyle(.bordered)
        .menuStyle(.button)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Window host: the same commands as the pop-out window's toolbar items.
struct EventDetailsWindowToolbar: ToolbarContent {
    let meeting: MeetingItem
    let detail: CalendarEventDetail?
    let week: CalendarWeekStore
    @Binding var trackingShown: Bool
    let close: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            EventRespondControl(meeting: meeting, week: week)
            EventActionsGroup(meeting: meeting, week: week, close: close)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            EventMoreMenu(meeting: meeting, detail: detail, week: week)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            EventJoinChat(meeting: meeting, close: close)
            EventTrackingToggle(shown: $trackingShown)
        }
    }
}

/// Tracking pane show/hide: the trailing-inspector toggle (Mail, Calendar).
struct EventTrackingToggle: View {
    @Binding var shown: Bool

    var body: some View {
        Toggle(isOn: $shown) {
            Label("Tracking", systemImage: "sidebar.trailing")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(shown ? "Hide Tracking" : "Show Tracking")
        .accessibilityLabel(shown ? "Hide Tracking" : "Show Tracking")
    }
}

// MARK: RSVP / Edit

/// Attendee: RSVP pop-up titled with the current response ("Accepted";
/// "Respond" until answered). Organizer: Edit.
struct EventRespondControl: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if meeting.isOrganizer {
            if let model {
                Button { CalendarSection.edit(meeting, model) } label: { Label("Edit", systemImage: "pencil") }
                    .labelStyle(.titleAndIcon)
                    .help("Edit")
            }
        } else if let info = meeting.info {
            HStack(spacing: 4) {
                Menu {
                    ForEach(RSVPAction.allCases, id: \.rawValue) { action in
                        if meeting.isSeries {
                            Menu(action.title) {
                                Button("This Event") { week.respond(to: meeting, action) }
                                Button("All Events in the Series") { week.respond(to: meeting, action, series: true) }
                            }
                        } else {
                            Button { week.respond(to: meeting, action) } label: {
                                if info.myResponse == action.response {
                                    Label(action.title, systemImage: "checkmark")
                                } else {
                                    Text(action.title)
                                }
                            }
                        }
                    }
                } label: {
                    Label(Self.title(info.myResponse), systemImage: CalendarDetailsText.responseSymbol(info.myResponse))
                }
                // Applied to the Menu itself (as on Edit): an NSToolbar item keeps the title only then.
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .disabled(week.respondingID != nil)
                .help("Respond")
                if week.respondingID != nil { ProgressView().controlSize(.mini) }
                if let error = week.rsvpError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed).help(error)
                }
            }
        }
    }

    /// The pop-up's title: the current response, "Respond" until answered.
    static func title(_ r: RSVPResponse) -> String { r.isPending ? "Respond" : r.label }
}

// MARK: Delete / Forward / Duplicate

struct EventActionsGroup: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    let close: () -> Void
    @Environment(\.windowModel) private var model
    @State private var forwardShown = false

    var body: some View {
        ControlGroup {
            deleteMenu
            Button { forwardShown = true } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward")
                .popover(isPresented: $forwardShown, arrowEdge: .bottom) {
                    ForwardEventPopover(meeting: meeting, week: week) { forwardShown = false }
                }
            Button {
                if let model { CalendarSection.duplicate(meeting, model) }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .help("Duplicate event")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    private var deleteMenu: some View {
        Menu {
            if meeting.isOrganizer {
                Button("Cancel Meeting\u{2026}", role: .destructive) {
                    if let model { CalendarSection.confirmCancel(meeting, model) }
                }
            } else {
                Button("Decline and Delete") { remove(decline: true, series: false) }
                Button("Delete Without Responding") { remove(decline: false, series: false) }
                if meeting.isSeries {
                    Divider()
                    Button("Decline and Delete Series") { remove(decline: true, series: true) }
                    Button("Delete Series Without Responding") { remove(decline: false, series: true) }
                }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .help(meeting.isOrganizer ? "Cancel meeting" : "Delete")
    }

    private func remove(decline: Bool, series: Bool) {
        close()
        week.removeFromCalendar(meeting, decline: decline, series: series)
    }
}

// MARK: Show as / Reminder / Categorize / Private

struct EventPersonalGroup: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore

    var info: CalendarEventInfo? { meeting.info }

    var body: some View {
        ControlGroup {
            showAsMenu
            reminderMenu
            categorizeMenu
            Toggle(isOn: privateBinding) {
                Label("Private", systemImage: "lock")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(info?.sensitivity == "private" ? "Private (on)" : "Private")
        }
        .fixedSize()
    }

    var privateBinding: Binding<Bool> {
        Binding(
            get: { info?.sensitivity == "private" },
            set: { on in personal(CalendarEventPatch(sensitivity: on ? "private" : "normal")) })
    }

    func personal(_ patch: CalendarEventPatch) {
        Task { await week.setPersonal(meeting, patch) }
    }

    @ViewBuilder var showAsItems: some View {
        ForEach(EventDetailsToolbar.showAsChoices, id: \.0) { value, title in
            Button {
                personal(CalendarEventPatch(showAs: value))
            } label: {
                if info?.showAs == value { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
    }

    private var showAsMenu: some View {
        Menu { showAsItems } label: {
            Label(CalendarDetailsText.showAsLabel(info?.showAs ?? "busy") ?? "Busy",
                  systemImage: CalendarDetailsText.showAsSymbol(info?.showAs))
                .labelStyle(.titleAndIcon)
        }
        .help("Show as")
    }

    @ViewBuilder var reminderItems: some View {
        ForEach(EventDetailsToolbar.reminderChoices, id: \.0) { value, title in
            let current = info?.reminderMinutes ?? -1
            Button {
                personal(CalendarEventPatch(reminderMinutes: value))
            } label: {
                if current == value { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
    }

    private var reminderMenu: some View {
        Menu { reminderItems } label: {
            Label("Reminder", systemImage: info?.reminderMinutes == nil ? "bell.slash" : "alarm")
                .labelStyle(.iconOnly)
        }
        .help(CalendarDetailsText.reminderLabel(info?.reminderMinutes))
    }

    @ViewBuilder var categorizeItems: some View {
        ForEach(week.categoryList) { c in
            let on = meeting.categories.contains { $0.caseInsensitiveCompare(c.name) == .orderedSame }
            Button {
                var names = meeting.categories.filter { $0.caseInsensitiveCompare(c.name) != .orderedSame }
                if !on { names.append(c.name) }
                personal(CalendarEventPatch(categories: names))
            } label: {
                if on { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
            }
        }
        if !meeting.categories.isEmpty {
            Divider()
            Button("Clear All Categories") { personal(CalendarEventPatch(categories: [])) }
        }
    }

    private var categorizeMenu: some View {
        Menu { categorizeItems } label: {
            Label("Categorize", systemImage: meeting.categories.isEmpty ? "tag" : "tag.fill")
                .labelStyle(.iconOnly)
        }
        .help(meeting.categories.isEmpty ? "Categorize" : "Categories: " + meeting.categories.joined(separator: ", "))
    }
}

extension EventDetailsToolbar {
    static let showAsChoices: [(String, String)] = [
        ("free", "Free"), ("workingElsewhere", "Working elsewhere"), ("tentative", "Tentative"),
        ("busy", "Busy"), ("oof", "Out of office"),
    ]

    static let reminderChoices: [(Int, String)] = [
        (-1, "Don\u{2019}t remind me"), (0, "At time of event"), (5, "5 minutes before"),
        (15, "15 minutes before"), (30, "30 minutes before"), (60, "1 hour before"),
        (120, "2 hours before"), (1440, "1 day before"), (10080, "1 week before"),
    ]
}

// MARK: Apps / Print / Download

struct EventFilesGroup: View {
    let meeting: MeetingItem
    let detail: CalendarEventDetail?
    let info: CalendarEventInfo?

    var body: some View {
        ControlGroup {
            appsMenu
            Button { CalendarPrinting.print(meeting, detail: detail) } label: { Label("Print", systemImage: "printer") }
                .help("Print")
            Button { CalendarICSSave.save(meeting, detail: detail) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .help("Download (.ics)")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    /// Outlook add-ins run in Outlook on the web: the event opens there.
    @ViewBuilder var appsItems: some View {
        if let link = info?.webLink, let url = URL(string: link) {
            Button("Open in Outlook on the Web") { TeamsLinkRouter.openInBrowser(url) }
            Text("Outlook add-ins for this event run there.")
        } else {
            Text("No add-ins for this event")
        }
    }

    private var appsMenu: some View {
        Menu { appsItems } label: {
            Label("Apps", systemImage: "square.grid.2x2")
        }
        .help("Apps")
    }
}

// MARK: More (window toolbar)

/// Window toolbar: Show as / Reminder / Categorize / Private and Apps /
/// Print / Download folded into one pull-down (Mail's message window keeps
/// its toolbar short), so every item fits at the default window size.
struct EventMoreMenu: View {
    let meeting: MeetingItem
    let detail: CalendarEventDetail?
    @ObservedObject var week: CalendarWeekStore

    var body: some View {
        let personal = EventPersonalGroup(meeting: meeting, week: week)
        let files = EventFilesGroup(meeting: meeting, detail: detail, info: meeting.info)
        Menu {
            Menu("Show As") { personal.showAsItems }
            Menu("Reminder") { personal.reminderItems }
            Menu("Categorize") { personal.categorizeItems }
            Toggle("Private", isOn: personal.privateBinding)
            Divider()
            Menu("Apps") { files.appsItems }
            Button("Print\u{2026}") { CalendarPrinting.print(meeting, detail: detail) }
            Button("Download (.ics)\u{2026}") { CalendarICSSave.save(meeting, detail: detail) }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More: show as, reminder, categories, private, apps, print, download")
        .accessibilityLabel("More")
    }
}

// MARK: Join / Chat

struct EventJoinChat: View {
    let meeting: MeetingItem
    let close: () -> Void
    @Environment(\.windowModel) private var model

    var body: some View {
        if meeting.joinURL?.isEmpty == false, let model {
            Button {
                close()
                CalendarSection.join(meeting, model)
            } label: { Label("Join", systemImage: "video.fill") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
        }
        if meeting.chatThreadID != nil, let model {
            Button { CalendarSection.openChat(meeting, model) } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .labelStyle(.titleAndIcon)
            .help("Chat with participants")
        }
    }
}

/// Category names as Finder/Mail tags: an Outlook-colored dot + the name, no fill.
struct CategoryChips: View {
    let names: [String]
    let list: [CalendarCategory]
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 12) {
            ForEach(names.map(NamedItem.init)) { item in
                let name = item.id
                HStack(spacing: 4) {
                    Circle().fill(CalendarDetailsText.categoryColor(name, list: list)).frame(width: 8, height: 8)
                    Text(name)
                }
                .font(AppFont.caption(scale))
            }
        }
    }
}

/// Forward: recipients + optional note (Graph forward).
struct ForwardEventPopover: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    let done: () -> Void
    @State private var to = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Forward \u{201C}\(meeting.subject)\u{201D}").font(.headline).lineLimit(1)
            TextField("To", text: $to, prompt: Text("name@example.com; \u{2026}"))
            TextField("Message", text: $note, prompt: Text("Add a note (optional)"), axis: .vertical)
                .lineLimit(2 ... 4)
            HStack {
                if week.forwarding { ProgressView().controlSize(.small) }
                if let error = week.forwardError {
                    Text(error).foregroundStyle(Palette.failed).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    week.clearForwardError()
                    done()
                }
                Button("Forward") {
                    Task {
                        if await week.forward(meeting, to: CalendarWeekStore.recipients(to), comment: note) { done() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(CalendarWeekStore.recipients(to).isEmpty || week.forwarding)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// Add a room (organizer): a room name, optionally its address; the
/// room joins the location and, with an address, the attendee list as
/// a resource (it books the room).
struct AddRoomPopover: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    let done: () -> Void
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a room").font(.headline)
            TextField("Room", text: $name, prompt: Text("Room name"))
            TextField("Room address", text: $address, prompt: Text("room@example.com (optional)"))
            HStack {
                if week.updating { ProgressView().controlSize(.small) }
                if let error = week.updateError {
                    Text(error).foregroundStyle(Palette.failed).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    week.clearUpdateError()
                    done()
                }
                Button("Add") {
                    let patch = CalendarDetailsText.roomPatch(meeting, name: name, address: address)
                    Task { if await week.update(meeting, patch: patch) { done() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || week.updating)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
