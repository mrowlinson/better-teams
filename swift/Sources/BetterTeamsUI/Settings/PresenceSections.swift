// PresenceSections.swift — Settings ▸ Notifications: own status (with
// "reset after" duration, Be Right Back / Appear Away, lock), automatic
// Away when the Mac is idle, and presence-schedule editing. Core:
// `PresenceTruthStore`, `PresenceScheduleStore`. Native Form controls.
import OstMacCore
import SwiftUI

struct PresenceStatusSection: View {
    @ObservedObject var truth: PresenceTruthStore
    @ObservedObject var presence: PresenceStore
    let live: Bool

    /// The account's real status; choosing applies at once (no Apply button).
    private var current: Binding<PresenceStatus> {
        Binding(
            get: { presence.own.flatMap { PresenceStatus(graphAvailability: $0.availability) } ?? .available },
            set: { truth.choose(status: $0) })
    }

    var body: some View {
        Section {
            Picker("Status", selection: current) {
                ForEach(PresenceStatus.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .disabled(!live)
            Picker("Reset after", selection: $truth.resetAfter) {
                ForEach(PresenceLockDuration.allCases, id: \.rawValue) {
                    Text($0 == .untilOff ? "Never" : $0.label).tag($0)
                }
            }
            LabeledContent("Locked") {
                HStack {
                    Text(DiagnosticsFormat.presenceLockLine(lock: truth.lock))
                        .foregroundStyle(.secondary)
                    if truth.isLocked() {
                        Button("Unlock") { truth.unlock() }
                    }
                }
            }
            Toggle("Away when this Mac is idle", isOn: $truth.autoAway)
            Toggle("Back to Available on input", isOn: $truth.restoreOnActivity)
            LabeledContent("This Mac", value: truth.activitySummary)
        } header: {
            InfoHeader(title: "My Status", subject: "my status",
                       text: "A timed status is pinned against idle Away and schedule windows until it ends.")
        }
    }
}

/// Out of office (OOO-SET): current overlay as read from the unified
/// presence service, plus an editor (message + start + duration) that
/// saves via PATCH /me/mailboxSettings. The duration reuses the status
/// "Reset after" picker: Never = always on, anything else schedules
/// start → start+duration. Saves are explicit (Set / Turn off) and
/// live-only; demo binds an inert store.
struct OutOfOfficeSection: View {
    @ObservedObject var presence: PresenceStore
    @StateObject private var ooo = OutOfOfficeStore()
    let live: Bool
    @State private var message = ""
    @State private var start = Date()
    @State private var duration: PresenceLockDuration = .untilOff

    /// Current overlay (server echo when signed in, adopted otherwise).
    private var overlay: (title: String, note: String?) {
        if let mine = presence.own, mine.outOfOffice == true {
            return ("Out of Office", mine.outOfOfficeNote)
        }
        return (ooo.setting.summary(), nil)
    }

    var body: some View {
        Section {
            LabeledContent("Status", value: overlay.title)
            if let note = overlay.note, !note.isEmpty {
                LabeledContent("Reply", value: note.count > 60 ? String(note.prefix(59)) + "…" : note)
            }
            TextField("Reply message", text: $message, prompt: Text("Out of office reply"))
                .disabled(!live || ooo.loading)
            DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .disabled(!live || ooo.loading || duration == .untilOff)
            Picker("Duration", selection: $duration) {
                ForEach(PresenceLockDuration.allCases, id: \.rawValue) {
                    Text($0 == .untilOff ? "Never (always on)" : $0.label).tag($0)
                }
            }
            .disabled(!live || ooo.loading)
            HStack {
                Button("Set Out of Office") {
                    ooo.save(.scheduled(message: message, start: start, duration: duration))
                }
                .disabled(!live || ooo.loading || message.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Turn Off", role: .destructive) { ooo.save(.off) }
                    .disabled(!live || ooo.loading)
            }
            if let error = ooo.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            InfoHeader(title: "Out of Office", subject: "out of office",
                       text: "Replies come from your mailbox, not your status. Never means always on until turned off.")
        }
        .onAppear {
            if live {
                ooo.refresh()
                if let s = oooStart() { start = s }
            }
        }
    }

    /// Prefill the start picker from the current schedule (nil = leave now).
    private func oooStart() -> Date? { ooo.setting.start }
}

struct PresenceScheduleSection: View {
    @ObservedObject var schedule: PresenceScheduleStore
    @State private var atLimit = false

    var body: some View {
        Section {
            Toggle("Set my status on a schedule", isOn: $schedule.enabled)
            ForEach($schedule.entries) { $entry in
                let n = (schedule.entries.firstIndex { $0.id == entry.id } ?? 0) + 1
                let many = schedule.entries.count > 1
                Picker(many ? "Schedule \(n) status" : "Status", selection: $entry.status) {
                    ForEach(PresenceStatus.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                WindowEditor(window: $entry.window, title: many ? "Schedule \(n)" : "Enabled",
                             remove: { schedule.removeEntry(id: entry.id) })
            }
            Button("Add Schedule") {
                atLimit = !schedule.addEntry(
                    PresenceScheduleEntry(window: QuietHoursWindow(
                        enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60, days: [2, 3, 4, 5, 6])))
            }
        } header: {
            Text("Presence Schedule")
        } footer: {
            if atLimit {
                Text("Up to \(PresenceScheduleStore.maxEntries) schedules.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
