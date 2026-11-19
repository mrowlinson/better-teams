// ShiftsSheets.swift — shifts-write lane: time-off request, add
// shift, swap request sheets + the requests queue + drafts banner.
//
// Sheets present from ShiftsSection commands (View ▸ Shifts menu,
// toolbar twins, inline buttons). Work runs in ShiftsStore (demo:
// in-memory writer); every surface stays native Form/Table.
import OstMacCore
import SwiftUI

/// Graph local wall-clock stamp (`yyyy-MM-ddTHH:mm:ss`), matching the
/// week rows and demo stamps.
func graphStamp(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                  parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1,
                  parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
}

/// Short human error for a write failure (never raw JSON).
func shiftsWriteError(_ error: Error) -> String {
    if isShiftScopeError(error) { return ShiftsWriter.scopePendingMessage }
    if case CoreCallError.failed(let m) = error, m.count < 120 { return m }
    return "Couldn't save. Check the connection and try again."
}

/// Shared sheet frame: title, content, error line, Cancel + action
/// (same HIG shape as the Teams sheets).
private struct ShiftsSheetFrame<Content: View>: View {
    let title: String
    let action: String
    let enabled: Bool
    let busy: Bool
    let error: String?
    let perform: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small)
                        Text("Saving…").foregroundStyle(.secondary)
                    } else if let error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                        Text(error).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Member: request time off for one reason and range.
struct TimeOffRequestSheet: View {
    @ObservedObject var store: ShiftsStore
    @State private var reasonID = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(86_400)
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowModel) private var model

    var body: some View {
        ShiftsSheetFrame(title: "Request Time Off", action: "Send Request",
                         enabled: !reasonID.isEmpty && end > start,
                         busy: busy, error: error, perform: save) {
            Form {
                Picker("Reason", selection: $reasonID) {
                    ForEach(store.reasons) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                DatePicker("Starts", selection: $start)
                DatePicker("Ends", selection: $end)
                TextField("Message", text: $message, prompt: Text("Optional"),
                          axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.columns)
            .onAppear {
                if reasonID.isEmpty { reasonID = store.reasons.first?.id ?? "" }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                let stamp: (Date) -> String = { graphStamp($0) }
                try await store.createTimeOffRequest(reasonID: reasonID, start: stamp(start),
                                                     end: stamp(end),
                                                     message: message.trimmingCharacters(
                                                         in: .whitespacesAndNewlines).isEmpty
                                                         ? nil : message)
                store.note("Time-off request sent.")
                model?.dismissSheet()
            } catch {
                self.error = shiftsWriteError(error)
            }
            busy = false
        }
    }
}

/// Manager: create one draft shift.
struct AddShiftSheet: View {
    @ObservedObject var store: ShiftsStore
    @State private var userID: String?
    @State private var day = Date()
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(8 * 3600)
    @State private var name = ""
    @State private var theme = "blue"
    @State private var notes = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowModel) private var model

    private static let themes = ["blue", "green", "purple", "pink", "yellow", "orange", "gray"]

    private var members: [(id: String, name: String)] {
        store.memberNames
            .filter { !$0.key.contains("@") }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ShiftsSheetFrame(title: "Add Shift", action: "Add Draft",
                         enabled: end > start, busy: busy, error: error, perform: save) {
            Form {
                Picker("Member", selection: $userID) {
                    Text("Open shift").tag(nil as String?)
                    ForEach(members, id: \.id) { Text($0.name).tag($0.id as String?) }
                }
                .pickerStyle(.menu)
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                TextField("Label", text: $name, prompt: Text("Front Desk"))
                Picker("Theme", selection: $theme) {
                    ForEach(Self.themes, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
                TextField("Notes", text: $notes, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.columns)
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                let cal = Calendar.current
                func at(_ time: Date) -> String {
                    let dc = cal.dateComponents([.hour, .minute], from: time)
                    let base = cal.startOfDay(for: day)
                    let at = cal.date(bySettingHour: dc.hour ?? 9, minute: dc.minute ?? 0,
                                      second: 0, of: base) ?? base
                    return graphStamp(at)
                }
                try await store.createShift(userID: userID, start: at(start), end: at(end),
                                            displayName: name, theme: theme, notes: notes)
                store.note("Draft shift added. Publish to share it.")
                model?.dismissSheet()
            } catch {
                self.error = shiftsWriteError(error)
            }
            busy = false
        }
    }
}

/// Member: ask another member to swap one shift.
struct SwapRequestSheet: View {
    @ObservedObject var store: ShiftsStore
    let shiftID: String
    @State private var receiverID: String?
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowModel) private var model

    private var members: [(id: String, name: String)] {
        let own = store.ownUserID
        return store.memberNames
            .filter { !$0.key.contains("@") && $0.key != own }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ShiftsSheetFrame(title: "Request Shift Swap", action: "Send Request",
                         enabled: true, busy: busy, error: error, perform: save) {
            Form {
                Picker("Swap With", selection: $receiverID) {
                    Text("Anyone").tag(nil as String?)
                    ForEach(members, id: \.id) { Text($0.name).tag($0.id as String?) }
                }
                .pickerStyle(.menu)
                TextField("Message", text: $message, prompt: Text("Optional"),
                          axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.columns)
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                try await store.createSwapRequest(shiftID: shiftID, receiverUserID: receiverID,
                                                 message: message.trimmingCharacters(
                                                     in: .whitespacesAndNewlines).isEmpty
                                                     ? nil : message)
                store.note("Swap request sent.")
                model?.dismissSheet()
            } catch {
                self.error = shiftsWriteError(error)
            }
            busy = false
        }
    }
}

/// One-line summary of a change request for the queue rows.
func shiftRequestSummary(_ r: ShiftChangeRequest, names: [String: String],
                         reasons: [TimeOffReason]) -> (title: String, detail: String) {
    let who: (String?) -> String = { id in
        guard let id, !id.isEmpty else { return "Anyone" }
        return names[id] ?? "Team Member"
    }
    switch r.kind {
    case "swap":
        return ("Swap request", "\(who(r.receiverUserID)) · \(r.message ?? "No message")")
    case "offer":
        return ("Offered shift", "To \(who(r.receiverUserID)) · \(r.message ?? "No message")")
    default:
        let reason = reasons.first { $0.id == r.reasonID }?.name ?? "Time off"
        return ("Time off: \(reason)", "\(r.message ?? "No message")")
    }
}

/// The change-request queue + drafts banner above the week grid.
/// Approve/Decline render for managers only; everyone else sees the
/// states. Scope-pending shows the approval line, never raw JSON.
struct ShiftsRequestsView: View {
    @ObservedObject var store: ShiftsStore
    @State private var deciding: String?
    @State private var error: String?
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
            }
            if let requestsError = store.requestsError {
                Label(requestsError, systemImage: "exclamationmark.triangle")
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if store.hasDrafts {
                HStack(spacing: 8) {
                    Label("Unpublished drafts on this week.", systemImage: "doc.badge.plus")
                        .font(AppFont.body(scale))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.isManager {
                        Button("Publish") { publish() }
                            .buttonStyle(.link)
                            .disabled(deciding != nil)
                    }
                }
            }
            if !store.requests.isEmpty {
                ForEach(store.requests) { r in
                    requestRow(r)
                    Divider()
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func requestRow(_ r: ShiftChangeRequest) -> some View {
        let summary = shiftRequestSummary(r, names: store.memberNames, reasons: store.reasons)
        return HStack(spacing: 8) {
            Image(systemName: r.kind == "timeoff" ? "calendar.badge.clock"
                        : r.kind == "offer" ? "arrowshape.turn.up.right" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(AppFont.subheadline(scale))
                Text(summary.detail)
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(r.state?.capitalized ?? "Unknown")
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
            if store.isManager, r.isPending {
                Button("Approve") { decide(r, approve: true) }
                    .buttonStyle(.link)
                    .disabled(deciding != nil)
                Button("Decline") { decide(r, approve: false) }
                    .buttonStyle(.link)
                    .disabled(deciding != nil)
            }
            if deciding == r.id {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func decide(_ r: ShiftChangeRequest, approve: Bool) {
        deciding = r.id
        error = nil
        Task {
            do {
                try await store.decideRequest(r, approve: approve)
                store.note(approve ? "Request approved." : "Request declined.")
            } catch {
                self.error = shiftsWriteError(error)
            }
            deciding = nil
        }
    }

    private func publish() {
        deciding = "publish"
        error = nil
        Task {
            do {
                try await store.publishDrafts(notifyTeam: false)
                store.note("Schedule published.")
            } catch {
                self.error = shiftsWriteError(error)
            }
            deciding = nil
        }
    }
}
