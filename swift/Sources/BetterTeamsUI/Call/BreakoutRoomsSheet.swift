// BreakoutRoomsSheet.swift — breakout rooms plan (BREAKOUT, Call menu).
// Native sheet over the meeting roster: create rooms (count stepper,
// automatic/manual segmented picker), assign via pop-up menus, open/
// close per room or all at once, live state display. Two engines: demo
// runs the local planner (BreakoutRoomsStore); live sessions manage
// real rooms over MiddleTier (LiveBreakoutRoomsStore) when the meeting
// + token allow, and disable every mutation with the reason otherwise.
// HIG: segmented control for the mode, Stepper for the count, List
// with disclosure groups, plain Buttons; no underline tabs, no
// web-look controls.
import OstMacCore
import SwiftUI

/// Breakout rooms sheet, presented from the Call menu while a group
/// call or meeting is joined. Reads the live roster for assignment.
/// `liveRooms` is non-nil exactly when the meeting + token allow live
/// management (CallSection.roomsLiveReady): the sheet then drives the
/// server and reloads after every write. Live without it disables
/// every mutating control with the reason below; demo stays fully
/// interactive on the local planner.
struct BreakoutRoomsSheet: View {
    @ObservedObject var rooms: BreakoutRoomsStore
    @ObservedObject var roster: MeetingRosterStore
    /// True in live (non-demo) sessions. Set by CallSection.sheet from
    /// the window's demo flag.
    var live = false
    /// Live rooms store (nil = live management unavailable).
    var liveRooms: LiveBreakoutRoomsStore? = nil
    /// Sign-in state for the disabled reason (nil = still resolving).
    var liveSignedIn: Bool? = true
    @Environment(\.windowModel) private var model
    @State private var count = BreakoutRoomsStore.defaultCount
    @State private var mode = BreakoutAssignMode.automatic
    @State private var confirmingEnd = false

    /// Help text on every disabled control in live sessions without
    /// meeting coords.
    static let liveDisabledReason =
        "rooms need the meeting's Teams coordinates — this meeting doesn't provide them"
    /// Help text when the user is signed out.
    static let liveSignInReason = "sign in to manage live breakout rooms"
    /// Banner over the live management UI.
    static let liveBanner = "Rooms are managed live in this meeting."
    /// Banner over the demo local planner.
    static let demoBanner = "Rooms are planned locally here and can't open live rooms."

    /// Live gate: mutations stay disabled in live sessions without a
    /// live store, whatever the manager flag; demo and live-ready
    /// defer to canManage per control.
    var mutationsDisabled: Bool { live && liveRooms == nil }

    /// Which disabled reason applies (sign-in wins over coords).
    var disabledReason: String {
        liveSignedIn == false ? Self.liveSignInReason : Self.liveDisabledReason
    }

    private var rosterIDs: [String] { roster.participants.map({ $0.id }) }

    private var statusLine: String {
        let open = rooms.openCount
        let total = rooms.rooms.count
        let un = rooms.unassigned(rosterIDs: rosterIDs).count
        return String(open) + " of " + String(total) + " open · " + String(un) + " unassigned"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Breakout Rooms").font(.headline)
            if live, let store = liveRooms {
                LiveBreakoutRoomsContent(store: store, roster: roster)
            } else {
                Text(live ? disabledReason : Self.demoBanner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !rooms.isActive {
                    setup
                } else {
                    active
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("Close") { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: setup (no plan yet)

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split this meeting into smaller rooms. Only the organizer or an appointed manager can run rooms.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Stepper(String(count) + " rooms", value: $count, in: 1...BreakoutRoomsStore.maxRooms)
            Picker("Assignment", selection: $mode) {
                ForEach(BreakoutAssignMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Spacer(minLength: 0)
                Button("Create Rooms") {
                    rooms.create(count: count, mode: mode, rosterIDs: rosterIDs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mutationsDisabled || !rooms.canManage)
                .help(live ? disabledReason : "")
            }
        }
    }

    // MARK: active plan

    private var active: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 8) {
                Button("Open All") { rooms.openAll() }
                    .disabled(mutationsDisabled || !rooms.canManage || rooms.rooms.allSatisfy({ $0.isOpen }))
                    .help(live ? disabledReason : "")
                Button("Close All") { rooms.closeAll() }
                    .disabled(mutationsDisabled || !rooms.canManage || rooms.openCount == 0)
                    .help(live ? disabledReason : "")
                Spacer(minLength: 0)
                Button("End Rooms", role: .destructive) { confirmingEnd = true }
                    .disabled(mutationsDisabled || !rooms.canManage)
                    .help(live ? disabledReason : "")
                    .confirmationDialog("End all breakout rooms?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                        Button("End Rooms", role: .destructive) { rooms.reset() }
                    }
            }
            List {
                ForEach(rooms.rooms) { room in
                    DisclosureGroup {
                        ForEach(room.assigneeIDs, id: \.self) { pid in
                            HStack {
                                Text(roster.participants.first { $0.id == pid }?.name ?? pid)
                                Spacer(minLength: 0)
                                if rooms.canManage {
                                    Button("Remove") { rooms.unassign(pid) }
                                        .buttonStyle(.link)
                                        // Link buttons stay blue under
                                        // .disabled in a List: force the
                                        // grey in live so nothing looks
                                        // tappable over the dead endpoint.
                                        .foregroundStyle(mutationsDisabled ? Color.secondary : Color.accentColor)
                                        .disabled(mutationsDisabled)
                                        .help(live ? disabledReason : "")
                                }
                            }
                        }
                        if rooms.canManage, !rooms.unassigned(rosterIDs: rosterIDs).isEmpty {
                            Menu("Assign…") {
                                ForEach(rooms.unassigned(rosterIDs: rosterIDs), id: \.self) { pid in
                                    Button(roster.participants.first { $0.id == pid }?.name ?? pid) {
                                        rooms.assign(pid, to: room.id)
                                    }
                                }
                            }
                            .disabled(mutationsDisabled)
                            .help(live ? disabledReason : "")
                        }
                    } label: {
                        HStack {
                            Text(room.name)
                            Spacer(minLength: 0)
                            Text(room.isOpen ? "Open" : "Closed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(String(room.assigneeIDs.count))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if rooms.canManage {
                                Button(room.isOpen ? "Close" : "Open") {
                                    rooms.setOpen(room.id, !room.isOpen)
                                }
                                .buttonStyle(.link)
                                // Link buttons stay blue under .disabled
                                // in a List: force the grey in live (see
                                // Remove above).
                                .foregroundStyle(mutationsDisabled ? Color.secondary : Color.accentColor)
                                .disabled(mutationsDisabled)
                                .help(live ? disabledReason : "")
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }
}

/// The sheet's live path: real rooms over MiddleTier, driven by
/// `LiveBreakoutRoomsStore`. Every control here performs a server
/// round-trip (the store reloads after each write); nothing is local
/// or faked. Owns no sheet chrome (the parent frames it).
struct LiveBreakoutRoomsContent: View {
    @ObservedObject var store: LiveBreakoutRoomsStore
    @ObservedObject var roster: MeetingRosterStore
    @State private var count = LiveBreakoutRoomsStore.defaultCount
    @State private var mode = BreakoutAssignMode.automatic
    @State private var confirmingEnd = false
    @State private var announceText = ""
    @State private var chooseOverride: Bool?
    @State private var durationDraft: String?

    private var rosterIDs: [String] { roster.participants.map({ $0.id }) }

    private var statusLine: String {
        let un = store.unassigned(rosterIDs: rosterIDs).count
        return String(store.openCount) + " of " + String(store.rooms.count) + " open · " +
            String(un) + " unassigned"
    }

    private func displayName(for p: LiveBreakoutParticipant) -> String {
        if let m = p.mri, let hit = roster.participants.first(where: { $0.id == m }) { return hit.name }
        if let u = p.upn, let hit = roster.participants.first(where: { $0.id == u }) { return hit.name }
        return p.mri ?? p.upn ?? p.objectID ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(BreakoutRoomsSheet.liveBanner)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = store.error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button("Retry") { store.reload() }
                }
            }
            if store.loading, !store.isActive {
                HStack {
                    Spacer(minLength: 0)
                    ProgressView()
                    Spacer(minLength: 0)
                }
            } else if !store.isActive {
                liveSetup
            } else {
                liveActive
            }
        }
        .onAppear { store.load() }
    }

    // MARK: live setup (no server plan yet)

    private var liveSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split this meeting into smaller rooms. Only the organizer or an appointed manager can run rooms.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Stepper(String(count) + " rooms", value: $count, in: 1...LiveBreakoutRoomsStore.maxRooms)
            Picker("Assignment", selection: $mode) {
                ForEach(BreakoutAssignMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Spacer(minLength: 0)
                Button("Create Rooms") {
                    store.create(count: count, mode: mode, roster: roster.participants)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.working || !store.canManage)
            }
        }
    }

    // MARK: live active plan

    private var liveActive: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 8) {
                Button("Open All") { store.openAll() }
                    .disabled(store.working || !store.canManage || store.rooms.allSatisfy(\.isOpened))
                Button("Close All") { store.closeAll() }
                    .disabled(store.working || !store.canManage || store.openCount == 0)
                Spacer(minLength: 0)
                Button("End Rooms", role: .destructive) { confirmingEnd = true }
                    .disabled(store.working || !store.canManage)
                    .confirmationDialog("End all breakout rooms?", isPresented: $confirmingEnd,
                                        titleVisibility: .visible) {
                        Button("End Rooms", role: .destructive) { store.reset() }
                    }
            }
            List {
                ForEach(store.rooms) { room in
                    DisclosureGroup {
                        ForEach(room.participants, id: \.seatKey) { p in
                            HStack {
                                Text(displayName(for: p))
                                Spacer(minLength: 0)
                                if store.canManage {
                                    Button("Remove") {
                                        store.unassign(p.mri ?? p.upn ?? p.objectID ?? "")
                                    }
                                    .buttonStyle(.link)
                                    .disabled(store.working)
                                }
                            }
                        }
                        if store.canManage, !store.unassigned(rosterIDs: rosterIDs).isEmpty {
                            Menu("Assign…") {
                                ForEach(store.unassigned(rosterIDs: rosterIDs), id: \.self) { pid in
                                    Button(roster.participants.first { $0.id == pid }?.name ?? pid) {
                                        if let seat = roster.participants.first(where: { $0.id == pid }) {
                                            store.assign(seat, to: room.id)
                                        }
                                    }
                                }
                            }
                            .disabled(store.working)
                        }
                    } label: {
                        HStack {
                            Text(room.roomName)
                            Spacer(minLength: 0)
                            Text(room.isOpened ? "Open" : "Closed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(String(room.participants.count))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if store.canManage {
                                Button(room.isOpened ? "Close" : "Open") {
                                    store.setOpen(room.id, !room.isOpened)
                                }
                                .buttonStyle(.link)
                                .disabled(store.working)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            liveSettings
            liveAnnounce
        }
    }

    // MARK: live settings + announce

    private var liveSettings: some View {
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Let participants choose their room", isOn: Binding(
                    get: { chooseOverride ?? store.settings?.allowChoose ?? false },
                    set: { chooseOverride = $0 }))
                HStack {
                    Text("Duration")
                    TextField("PT15M", text: Binding(
                        get: { durationDraft ?? store.settings?.roomDuration ?? "" },
                        set: { durationDraft = $0 }))
                    .frame(width: 90)
                    .help("Room timer, e.g. PT15M for 15 minutes")
                    Spacer(minLength: 0)
                    Button("Save") {
                        store.saveSettings(allowChoose: chooseOverride,
                                           roomDuration: durationDraft ?? store.settings?.roomDuration)
                        chooseOverride = nil
                        durationDraft = nil
                    }
                    .disabled(store.working)
                }
            }
            .padding(.top, 4)
        }
    }

    private var liveAnnounce: some View {
        HStack {
            TextField("Message all open rooms…", text: $announceText)
            Button("Announce") {
                let open = store.rooms.filter(\.isOpened).map(\.id)
                store.announce(announceText, roomIDs: open)
                announceText = ""
            }
            .disabled(store.working || !store.canManage || store.openCount == 0 ||
                announceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
