// CalendarWeekGrid.swift — the Week view (UI-SPEC §6.4): the store's
// week window as day columns on an hour scale. Placement is a SwiftUI
// `Layout` (`WeekGridLayout`, R8: no geometry readers); overlapping
// meetings share a column by the pure lane assignment in
// `WeekGridLanes`. Selecting a meeting shows it in the inspector.
import OstMacCore
import SwiftUI

struct WeekGrid: View {
    @ObservedObject var week: CalendarWeekStore
    let selectedID: String?
    let select: (String?) -> Void
    @Environment(\.contentTextScale) private var scale

    static let hourHeight: CGFloat = 44
    static let gutter: CGFloat = 56

    struct Day: Identifiable {
        let id: String
        let meetings: [MeetingItem]
    }

    struct Hour: Identifiable {
        let id: Int
    }

    private static let hours = (0 ..< 24).map(Hour.init(id:))

    private var days: [Day] {
        zip(week.dayKeys, week.columns).map { Day(id: $0.0, meetings: $0.1) }
    }

    var body: some View {
        let now = RelativeClock.shared.now
        let nowMinute = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        // The day header is a pinned section header inside the scroll
        // view, so it and the columns share one width (a header outside
        // spans the legacy scroller too and drifts right, ~14 pt by Sat).
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            gutter
                            ForEach(days) { day in
                                let today = Self.isToday(day.id, now)
                                WeekDayColumn(meetings: day.meetings, selectedID: selectedID,
                                              nowMinute: today ? nowMinute : nil, select: select)
                                    .frame(maxWidth: .infinity)
                                    .background(today ? AnyShapeStyle(.tint.opacity(0.05)) : AnyShapeStyle(Color.clear))
                                    .overlay(alignment: .leading) { Divider() }
                            }
                        }
                        .frame(height: 24 * Self.hourHeight)
                        .background { HourLines(hourHeight: Self.hourHeight, leading: Self.gutter) }
                    } header: {
                        VStack(spacing: 0) {
                            header(now)
                            Divider()
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
            }
            // Opens on working hours (or an hour before now in the
            // current week), not at the top of the day.
            .task(id: days.first?.id) {
                let hour = Self.initialHour(days: days, now: now)
                // The pinned header covers the top hour row. Targets the
                // gutter ForEach identity (the hour), no id modifier (R4).
                proxy.scrollTo(Hour.ID(max(0, hour - 1)), anchor: .top)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    static func isToday(_ dayKey: String, _ now: Date) -> Bool {
        CalendarFormat.day(dayKey).map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
    }

    /// First hour shown: an hour before now in the current week, else
    /// the earlier of 8 AM and the week's first meeting.
    static func initialHour(days: [Day], now: Date) -> Int {
        if days.contains(where: { isToday($0.id, now) }) {
            return max(0, Calendar.current.component(.hour, from: now) - 1)
        }
        let first = days.flatMap(\.meetings).compactMap { CalendarFormat.minutes($0.start) }.min()
        return min(8, (first ?? 8 * 60) / 60)
    }

    private func header(_ now: Date) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days) { day in
                let today = Self.isToday(day.id, now)
                VStack(spacing: 1) {
                    Text(CalendarFormat.day(day.id)?.formatted(.dateTime.weekday(.abbreviated)) ?? "")
                        .font(AppFont.caption(scale))
                        .foregroundStyle(today ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    // Today: the date in a filled accent circle (Calendar.app).
                    Text(CalendarFormat.day(day.id)?.formatted(.dateTime.day()) ?? day.id)
                        .font(today ? AppFont.headline(scale) : AppFont.body(scale))
                        .monospacedDigit()
                        .foregroundStyle(today ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 5)
                        .background { if today { Capsule().fill(.tint) } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(CalendarFormat.dayTitle(day.id, now: now))
            }
        }
    }

    private var gutter: some View {
        VStack(spacing: 0) {
            ForEach(Self.hours) { h in
                Text(h.id == 0 ? "" : Self.hourLabel(h.id))
                    .font(AppFont.caption(scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.gutter - 8, height: Self.hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
            }
        }
        .frame(width: Self.gutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    static func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
        return d.formatted(.dateTime.hour())
    }
}

/// Hour rules behind the columns.
private struct HourLines: View {
    let hourHeight: CGFloat
    let leading: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for h in 1 ..< 24 {
                let y = CGFloat(h) * hourHeight
                p.move(to: CGPoint(x: leading, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// One day: meetings placed by start/end minutes and lane.
private struct WeekDayColumn: View {
    let meetings: [MeetingItem]
    let selectedID: String?
    /// Minutes after midnight on today's column (the now line), else nil.
    let nowMinute: Int?
    let select: (String?) -> Void

    var body: some View {
        let spans = meetings.map { m -> (Int, Int) in
            let s = CalendarFormat.minutes(m.start) ?? 0
            let e = CalendarFormat.minutes(m.end).map { $0 > s ? $0 : 24 * 60 } ?? s + 30
            return (s, e)
        }
        let slots = WeekGridLanes.assign(spans)
        WeekGridLayout(minuteHeight: WeekGrid.hourHeight / 60) {
            ForEach(meetings) { m in
                let i = meetings.firstIndex(of: m) ?? 0
                WeekEventBlock(meeting: m, selected: m.id == selectedID) { select(m.id) }
                    .layoutValue(key: WeekGridSpan.self,
                                 value: WeekGridSpan.Value(start: spans[i].0, end: spans[i].1,
                                                           lane: slots[i].lane, lanes: slots[i].lanes))
            }
        }
        .overlay(alignment: .topLeading) {
            if let nowMinute {
                // Current-time line (Calendar.app): red rule + dot.
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Rectangle().fill(.red).frame(height: 1.5)
                }
                .offset(x: -3.5, y: CGFloat(nowMinute) * WeekGrid.hourHeight / 60 - 3.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct WeekGridSpan: LayoutValueKey {
    struct Value: Equatable {
        var start: Int
        var end: Int
        var lane: Int
        var lanes: Int
    }

    static let defaultValue = Value(start: 0, end: 30, lane: 0, lanes: 1)
}

/// Places each meeting at its minutes (y) and lane (x) inside the day.
struct WeekGridLayout: Layout {
    var minuteHeight: CGFloat
    var inset: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 120, height: 24 * 60 * minuteHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews {
            let s = v[WeekGridSpan.self]
            let lanes = CGFloat(max(1, s.lanes))
            let laneWidth = max(0, (bounds.width - 2 * inset) / lanes)
            let x = bounds.minX + inset + laneWidth * CGFloat(s.lane)
            let y = bounds.minY + CGFloat(s.start) * minuteHeight + 1
            let h = max(18, CGFloat(s.end - s.start) * minuteHeight - 2)
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: max(0, laneWidth - inset), height: h))
        }
    }
}

private struct WeekEventBlock: View {
    let meeting: MeetingItem
    let selected: Bool
    let action: () -> Void
    @Environment(\.contentTextScale) private var scale

    /// The first Outlook category's color, else the accent tint.
    private var color: AnyShapeStyle {
        meeting.categories.lazy.compactMap(WeekEventColor.color(forCategory:)).first
            .map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.subject)
                        .font(AppFont.caption(scale).weight(.semibold))
                        .lineLimit(4)
                    // Narrow lanes: start time only, never a clipped range.
                    ViewThatFits(in: .horizontal) {
                        Text(CalendarFormat.range(meeting))
                        Text(CalendarFormat.date(meeting.start).map(CalendarFormat.time) ?? "")
                    }
                    .font(AppFont.caption(scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(selected ? 0.32 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: selected ? 1.5 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(meeting.subject), \(CalendarFormat.range(meeting))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Outlook color categories: the preset names ("Blue category", or any
/// name containing a color word) map to system colors; other names
/// keep the accent tint.
enum WeekEventColor {
    static func color(forCategory name: String) -> Color? {
        let n = name.lowercased()
        let table: [(String, Color)] = [
            ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
            ("teal", .teal), ("blue", .blue), ("purple", .purple), ("pink", .pink),
            ("gray", .gray), ("grey", .gray),
        ]
        return table.first { n.contains($0.0) }?.1
    }
}
