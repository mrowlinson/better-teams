// BreakoutRoomsSheet.swift — breakout rooms plan (BREAKOUT, Call menu).
// Native sheet over the meeting roster: create rooms (count stepper,
// automatic/manual segmented picker), assign via pop-up menus, open/
// close per room or all at once, live state display. Local state only
// (BreakoutRoomsStore): no network writes. HIG: segmented control for
// the mode, Stepper for the count, List with disclosure groups, plain
// Buttons; no underline tabs, no web-look controls.
import OstMacCore
import SwiftUI

/// Breakout rooms sheet, presented from the Call menu while a group
/// call or meeting is joined. Reads the live roster for assignment.
/// The plan is local-only (no public Graph API moves live rooms, so
/// the Teams client owns them): in live sessions every mutating
/// control stays disabled with the reason below; demo stays fully
/// interactive.
struct BreakoutRoomsSheet: View {
    @ObservedObject var rooms: BreakoutRoomsStore
    @ObservedObject var roster: MeetingRosterStore
    /// True in live (non-demo) sessions: mutations disabled, banner
    /// shown. Set by CallSection.sheet from the window's demo flag.
    var live = false
    @Environment(\.windowModel) private var model
    @State private var count = BreakoutRoomsStore.defaultCount
    @State private var mode = BreakoutAssignMode.automatic
    @State private var confirmingEnd = false

    /// Help text on every disabled control in live sessions.
    static let liveDisabledReason = "rooms need the Teams client — no API to open them"

    /// Live gate: mutations stay disabled in live sessions whatever
    /// the manager flag; demo defers to canManage per control.
    var mutationsDisabled: Bool { live }

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
            Text("Rooms are planned locally here and can't open live rooms.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !rooms.isActive {
                setup
            } else {
                active
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
                .help(live ? Self.liveDisabledReason : "")
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
                    .help(live ? Self.liveDisabledReason : "")
                Button("Close All") { rooms.closeAll() }
                    .disabled(mutationsDisabled || !rooms.canManage || rooms.openCount == 0)
                    .help(live ? Self.liveDisabledReason : "")
                Spacer(minLength: 0)
                Button("End Rooms", role: .destructive) { confirmingEnd = true }
                    .disabled(mutationsDisabled || !rooms.canManage)
                    .help(live ? Self.liveDisabledReason : "")
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
                                        .help(live ? Self.liveDisabledReason : "")
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
                            .help(live ? Self.liveDisabledReason : "")
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
                                .help(live ? Self.liveDisabledReason : "")
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }
}
