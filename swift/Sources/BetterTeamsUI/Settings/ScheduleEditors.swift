// ScheduleEditors.swift — the native controls Settings ▸ Notifications
// shares between Quiet Hours windows and Presence Schedule entries:
// From/To DatePickers plus one toggle button per weekday (a window is
// `QuietHoursWindow`: minutes-since-midnight + Calendar weekdays 1...7).
import OstMacCore
import SwiftUI

/// Start/end time-of-day pickers for one window.
struct WindowTimeFields: View {
    @Binding var window: QuietHoursWindow

    var body: some View {
        DatePicker("From", selection: time(\.startMinutes), displayedComponents: .hourAndMinute)
        DatePicker("To", selection: time(\.endMinutes), displayedComponents: .hourAndMinute)
    }

    private func time(_ key: WritableKeyPath<QuietHoursWindow, Int>) -> Binding<Date> {
        Binding(
            get: { QuietHoursStore.timeOfDay(minutes: window[keyPath: key]) },
            set: { window[keyPath: key] = QuietHoursStore.minutes(ofTime: $0) })
    }
}

/// One toggle button per weekday, in the calendar's week order.
struct WeekdayPicker: View {
    @Binding var days: [Int]
    private let calendar = Calendar.current

    var body: some View {
        LabeledContent("Days") {
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    Toggle(isOn: binding(day)) {
                        Text(calendar.veryShortWeekdaySymbols[day - 1])
                            .frame(minWidth: 14)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                }
            }
        }
    }

    /// 1...7 rotated to start on the calendar's first weekday.
    private var order: [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func binding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { days.contains(day) },
            set: { on in
                var set = Set(days)
                if on { set.insert(day) } else { set.remove(day) }
                days = set.sorted()
            })
    }
}
