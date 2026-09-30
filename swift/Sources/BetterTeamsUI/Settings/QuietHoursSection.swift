// QuietHoursSection.swift — Settings ▸ Notifications: Do Not Disturb with
// auto-expire, and any number of quiet-hours windows with weekdays
// (`QuietHoursStore`). Native Form controls only.
import OstMacCore
import SwiftUI

struct DoNotDisturbSection: View {
    @ObservedObject var quiet: QuietHoursStore

    var body: some View {
        Section {
            Toggle("Do Not Disturb", isOn: Binding(
                get: { quiet.dndActive() },
                set: { on in
                    if on { quiet.enableDND(quiet.pendingDNDOption) } else { quiet.disableDND() }
                }))
            Picker("Turn off", selection: Binding(
                get: { quiet.pendingDNDOption },
                set: { option in
                    // Re-applied while on, so the new expiry takes effect at once.
                    if quiet.dndActive() { quiet.enableDND(option) } else { quiet.pendingDNDOption = option }
                })) {
                ForEach(DNDDuration.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
        } header: {
            InfoHeader(title: "Do Not Disturb", subject: "Do Not Disturb",
                       text: "Silences banners until it turns off by itself or you switch it off.")
        } footer: {
            if quiet.dndActive() {
                Text("Banners are silenced \(quiet.dndStatus()).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct QuietHoursSection: View {
    @ObservedObject var quiet: QuietHoursStore
    @ObservedObject var focus: FocusSyncStore
    @State private var atLimit = false

    var body: some View {
        Section {
            ForEach(quiet.windows.indices, id: \.self) { i in
                WindowEditor(window: binding(i), title: quiet.windows.count > 1 ? "Window \(i + 1)" : "Quiet hours",
                             remove: i == 0 ? nil : { quiet.removeWindow(at: i) })
            }
            Button("Add Window") { atLimit = !quiet.addWindow() }
            Toggle("Stay quiet while a Focus is on", isOn: $focus.syncEnabled)
        } header: {
            Text("Quiet Hours")
        } footer: {
            if atLimit {
                Text("Up to \(QuietHoursStore.maxWindows) windows.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ i: Int) -> Binding<QuietHoursWindow> {
        Binding(get: { i < quiet.windows.count ? quiet.windows[i] : QuietHoursWindow() },
                set: { if i < quiet.windows.count { quiet.windows[i] = $0 } })
    }
}

/// One window: enable switch, From/To, weekdays, optional Remove.
struct WindowEditor: View {
    @Binding var window: QuietHoursWindow
    let title: String
    var remove: (() -> Void)?

    var body: some View {
        Toggle(title, isOn: $window.enabled)
        if window.enabled {
            WindowTimeFields(window: $window)
            WeekdayPicker(days: $window.days)
        }
        if let remove {
            Button("Remove", role: .destructive, action: remove)
        }
    }
}
