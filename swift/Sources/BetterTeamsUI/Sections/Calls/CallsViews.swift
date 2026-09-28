// CallsViews.swift — Calls panes (UI-SPEC §6.5): the list (Current
// call, Speed Dial, Recent), the person detail, and New Call. Missed
// calls = red symbol + the word "Missed" (§10: never color alone).
import OstMacCore
import SwiftUI

// MARK: list

struct CallsListPane: View {
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var contacts: ContactsStore
    @ObservedObject var presence: PresenceStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            content(model)
        }
    }

    @ViewBuilder
    private func content(_ m: WindowModel) -> some View {
        let rows = CallsRowModel.rows(history: history.records, activity: activity.items,
                                      hidden: history.hiddenFeedIDs)
        let dial = contacts.pinnedContacts()
        let current = m.call.flatMap { $0.ended ? nil : $0 }
        switch m.forced(.calls) {
        case .loading:
            LoadingPane("Loading Calls\u{2026}")
        case .error:
            ErrorPane(title: "Couldn\u{2019}t Load Calls",
                      message: m.connection == .offline ? "You\u{2019}re offline." : "Something went wrong.") {}
        case .empty:
            CallsEmptyPane()
        case nil:
            if rows.isEmpty, dial.isEmpty, current == nil {
                CallsEmptyPane()
            } else {
                list(rows, dial: dial, current: current, m)
            }
        }
    }

    private func list(_ rows: [CallsRowModel], dial: [TeamMember], current: CallSession?, _ m: WindowModel)
        -> some View
    {
        let now = RelativeClock.shared.now
        let selection = Binding<String?>(
            get: { m.nav.selection(in: .calls)?.id },
            set: { id in
                if id == CallsListPane.currentCallID {
                    m.call?.show()
                } else {
                    m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .calls)
                }
            })
        return List(selection: selection) {
            if let current {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current call").font(AppFont.bodyEmphasized(m.textScale))
                            CallDurationText(session: current, scale: m.textScale)
                        }
                    } icon: {
                        Image(systemName: "phone.connection.fill").foregroundStyle(Palette.presenceAvailable)
                    }
                    .padding(.vertical, 3)
                    .tag(CallsListPane.currentCallID)
                }
            }
            if !dial.isEmpty {
                Section("Speed Dial") {
                    ForEach(dial) { c in
                        HStack(spacing: 8) {
                            Avatar(name: c.displayName)
                                .overlay(alignment: .bottomTrailing) {
                                    if let s = PeerPresence.status(presence, chatID: nil, userID: c.userId ?? c.id) {
                                        // 4 pt: at 2 the ring clipped the monogram (ACTSEARCH, Search People).
                                        PresenceBadge(status: s, size: 11).offset(x: 4, y: 4)
                                    }
                                }
                            Text(c.displayName).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(CallsSection.speedDialPrefix + c.id)
                    }
                    // Drag to reorder (Finder sidebar favorites).
                    .onMove { contacts.movePins(fromOffsets: $0, toOffset: $1) }
                }
            }
            Section("Recent") {
                ForEach(rows) { r in
                    CallsRow(row: r, now: now).tag(r.id)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, id != CallsListPane.currentCallID, let p = CallsSection.person(id, m) {
                Button("Call Back") { CallsSection.call(p, m) }
                    .disabled(p.thread.isEmpty || !(m.call.map(\.ended) ?? true))
                if CallsSection.chatID(p, m) != nil {
                    Button("Message") { CallsSection.message(p, m) }
                }
                Divider()
                if CallsSection.isPinned(p, m) {
                    Button("Remove from Speed Dial") { CallsSection.removeFromSpeedDial(p, m) }
                } else if CallsSection.member(p) != nil {
                    Button("Add to Speed Dial") { CallsSection.addToSpeedDial(p, m) }
                }
                if CallsSection.isRecent(id) {
                    Button("Remove from Recents") { CallsSection.removeFromRecents([id], m) }
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if id == CallsListPane.currentCallID { m.call?.show() } else {
                m.navigator?.select(SectionSelection(id: id), in: .calls)
            }
        }
    }

    static let currentCallID = "current-call"
}

struct CallsEmptyPane: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        EmptyPane("No Recent Calls", systemImage: "phone") {
            Button("New Call…") { model?.presentSheet(SheetRequest(CallsCommands.newCallSheet, in: .calls)) }
        }
    }
}

/// Recent row (§6.5): direction symbol (missed: red + the word
/// "Missed") · name · time · duration.
struct CallsRow: View {
    let row: CallsRowModel
    let now: Date
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: row.symbol)
                .font(AppFont.body(scale))
                .foregroundStyle(row.isMissed ? AnyShapeStyle(Palette.failed) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.name)
                        .font(AppFont.body(scale))
                        .foregroundStyle(row.isMissed ? AnyShapeStyle(Palette.failed) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ActivityRow.time(row.date, now: now))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(row.detailLine)
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.detailLine), \(ActivityRow.time(row.date, now: now))")
    }
}

// MARK: detail

struct CallsDetailPane: View {
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var contacts: ContactsStore
    @ObservedObject var presence: PresenceStore
    @ObservedObject var chats: ChatListViewModel
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if let model, model.forced(.calls) == nil,
           let p = CallsSection.person(model.nav.selection(in: .calls)?.id, model) {
            detail(p, model)
        } else {
            NoSelectionPane("No Contact Selected")
        }
    }

    private func detail(_ p: CallsSection.Person, _ m: WindowModel) -> some View {
        let now = RelativeClock.shared.now
        let recent = CallsRowModel.rows(history: history.records, activity: activity.items,
                                        hidden: history.hiddenFeedIDs)
            .filter { $0.personKey == p.personKey }
            .prefix(10)
        let status = PeerPresence.status(presence, chatID: CallsSection.chatID(p, m), userID: p.personID)
        let idle = m.call.map(\.ended) ?? true
        return Form {
            Section {
                VStack(spacing: 10) {
                    Avatar(name: p.name, diameter: 64)
                        .overlay(alignment: .bottomTrailing) {
                            if let status { PresenceBadge(status: status, size: 16) }
                        }
                    VStack(spacing: 4) {
                        Text(p.name).font(AppFont.title3(scale))
                        if let status {
                            Text(PeerPresence.label(status))
                                .font(AppFont.subheadline(scale))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Call") { CallsSection.call(p, m) }
                            .buttonStyle(.borderedProminent)
                            .disabled(p.thread.isEmpty || !idle)
                        Button("Video") { CallsSection.call(p, m, video: true) }
                            .disabled(!CallsSection.canVideo(p, m) || !idle)
                        Button("Chat") { CallsSection.message(p, m) }
                            .disabled(CallsSection.chatID(p, m) == nil)
                    }
                    if CallsSection.isPinned(p, m) {
                        Button("Remove from Speed Dial") { CallsSection.removeFromSpeedDial(p, m) }
                            .buttonStyle(.link)
                    } else if CallsSection.member(p) != nil {
                        Button("Add to Speed Dial") { CallsSection.addToSpeedDial(p, m) }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            if !recent.isEmpty {
                Section("Recent Calls") {
                    ForEach(Array(recent)) { r in
                        LabeledContent {
                            Text(ActivityRow.time(r.date, now: now)).monospacedDigit()
                        } label: {
                            Label {
                                Text(r.detailLine)
                            } icon: {
                                Image(systemName: r.symbol)
                                    .foregroundStyle(r.isMissed ? AnyShapeStyle(Palette.failed) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: New Call

/// New Call (§6.5): recent 1:1 contacts filtered by name, or people from
/// the directory as you type. A recent contact calls on that chat; picked
/// people go through `AppState.startCall(with:)` (core-c): their 1:1 (or
/// a new group chat for two or more) is found or created, then the call
/// shows in the chosen presentation and dials.
struct NewCallSheet: View {
    @ObservedObject var chats: ChatListViewModel
    /// Directory search (the sheet's own store, never `app.contacts`).
    let contacts: ContactsStore?
    @ObservedObject var presence: PresenceStore
    @State private var query = ""
    @State private var picked: String?
    @State private var people: [TeamMember] = []
    @State private var starting = false
    @State private var failure: String?
    @State private var debounce = Debounce(milliseconds: 250)
    @Environment(\.windowModel) private var model

    private var candidates: [ChatItem] {
        ChatListFormat.filter(chats.chats.filter { !$0.is_group }, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Call").font(.headline)
            SearchField(text: $query, placeholder: "Search People")
                .frame(height: 24)
            if !people.isEmpty {
                PickedPeople(people: $people)
            }
            if let contacts, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                DirectoryResults(contacts: contacts, people: $people)
            } else {
                recentContacts
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.failed)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Call") { call() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || (people.isEmpty && picked == nil))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: query) { _, q in
            guard let contacts else { return }
            debounce.schedule { Task { await contacts.search(query: q) } }
        }
    }

    private var recentContacts: some View {
        List(selection: $picked) {
            ForEach(candidates) { c in
                HStack(spacing: 8) {
                    Avatar(name: c.name)
                        .overlay(alignment: .bottomTrailing) {
                            if let s = PeerPresence.status(presence, chatID: c.id, userID: nil) {
                                PresenceBadge(status: s, size: 11).offset(x: 4, y: 4)
                            }
                        }
                    Text(c.name)
                    Spacer(minLength: 8)
                    if let s = PeerPresence.status(presence, chatID: c.id, userID: nil) {
                        Text(PeerPresence.label(s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(c.id)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: 200)
        .overlay {
            if candidates.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func call() {
        guard let m = model else { return }
        if people.isEmpty {
            guard let id = picked, let c = chats.chats.first(where: { $0.id == id }) else { return }
            m.dismissSheet()
            CallsSection.call(CallsSection.Person(name: c.name, personID: nil, personKey: "name:" + c.name,
                                                  thread: id), m)
            return
        }
        guard let app = m.app else { return }
        starting = true
        failure = nil
        let chosen = people
        Task { @MainActor in
            let target = await app.startCall(with: chosen) { t in
                m.beginCall(.person(name: t.name, thread: t.threadID)) != nil
            }
            starting = false
            if target != nil || app.startCallError == nil {
                // Placed, or aborted because a running call came forward.
                m.dismissSheet()
            } else {
                failure = app.startCallError
            }
        }
    }
}
