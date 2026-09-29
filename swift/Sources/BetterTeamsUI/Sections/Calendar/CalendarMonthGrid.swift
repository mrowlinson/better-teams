// CalendarMonthGrid.swift — the Month view (Teams parity): weeks of
// day cells, each with its events as chips (all-day first), "+N more"
// past three; a day click opens that day in the Day view, a chip
// selects the meeting (inspector). Rows come from the store's month
// (its weeks land together, so a month never paints half-empty).
import OstMacCore
import SwiftUI

struct MonthGrid: View {
    @ObservedObject var week: CalendarWeekStore
    let selectedID: String?
    let select: (String?) -> Void
    let openDay: (String) -> Void
    @Environment(\.contentTextScale) private var scale

    static let chipsPerDay = 3

    struct Row: Identifiable {
        let id: String
        let keys: [Weekday]
    }

    struct Weekday: Identifiable {
        let id: String
    }

    private var rows: [Row] {
        let keys = week.monthDayKeys
        return stride(from: 0, to: keys.count, by: 7).map { i in
            let slice = keys[i ..< min(i + 7, keys.count)].map(Weekday.init(id:))
            return Row(id: slice.first?.id ?? "\(i)", keys: slice)
        }
    }

    private var weekdays: [Weekday] {
        (rows.first?.keys ?? []).compactMap { key in
            CalendarFormat.day(key.id).map { Weekday(id: $0.formatted(.dateTime.weekday(.abbreviated))) }
        }
    }

    var body: some View {
        let now = RelativeClock.shared.now
        let buckets = Dictionary(uniqueKeysWithValues: zip(week.monthDayKeys,
                                                           CalWeek.bucket(week.monthMeetings, keys: week.monthDayKeys)))
        let month = week.calendar.component(.month, from: week.monthStart)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays) { d in
                    Text(d.id)
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        ForEach(row.keys) { cell in
                            let key = cell.id
                            MonthDayCell(
                                key: key, meetings: buckets[key] ?? [],
                                inMonth: CalendarFormat.day(key).map { week.calendar.component(.month, from: $0) == month } ?? false,
                                today: CalendarFormat.day(key).map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false,
                                selectedID: selectedID, week: week, select: select, openDay: openDay)
                                .overlay(alignment: .leading) { Divider() }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct MonthDayCell: View {
    let key: String
    let meetings: [MeetingItem]
    let inMonth: Bool
    let today: Bool
    let selectedID: String?
    @ObservedObject var week: CalendarWeekStore
    let select: (String?) -> Void
    let openDay: (String) -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { openDay(key) } label: {
                Text(CalendarFormat.day(key)?.formatted(.dateTime.day()) ?? key)
                    .font(today ? AppFont.headline(scale) : AppFont.caption(scale))
                    .monospacedDigit()
                    .foregroundStyle(today ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 5)
                    .background { if today { Capsule().fill(.tint) } }
            }
            .buttonStyle(.plain)
            .help("Show this day")
            .accessibilityLabel(CalendarFormat.dayTitle(key, now: RelativeClock.shared.now))
            ForEach(meetings.prefix(MonthGrid.chipsPerDay)) { m in
                CalendarChip(meeting: m, selected: m.id == selectedID, showTime: !m.isAllDay) { select(m.id) }
                    .contextMenu { CalendarMeetingMenu(meeting: m, week: week) }
            }
            if meetings.count > MonthGrid.chipsPerDay {
                Button("+\(meetings.count - MonthGrid.chipsPerDay) more") { openDay(key) }
                    .buttonStyle(.plain)
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.tint)
                    .help("Show all events on this day")
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary.opacity(0.3)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDay(key) }
    }
}

/// One-line event chip (month cells, all-day strip): category color
/// bar, optional start time, subject.
struct CalendarChip: View {
    let meeting: MeetingItem
    let selected: Bool
    let showTime: Bool
    let action: () -> Void
    @Environment(\.contentTextScale) private var scale

    private var color: AnyShapeStyle {
        meeting.categories.lazy.compactMap(WeekEventColor.color(forCategory:)).first
            .map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
                if showTime, let s = CalendarFormat.date(meeting.start) {
                    Text(CalendarFormat.time(s))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(meeting.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(AppFont.caption(scale))
            .padding(.vertical, 1)
            .padding(.trailing, 3)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(selected ? 0.32 : 0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(meeting.subject), \(CalendarFormat.range(meeting))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
