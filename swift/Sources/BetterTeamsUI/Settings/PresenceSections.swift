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
