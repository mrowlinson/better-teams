// ShiftsViews.swift — Shifts week table and shift inspector (UI-SPEC
// §6.7, R18 pane states).
import OstMacCore
import SwiftUI

/// The week schedule: pane state, else the people × days `Table`.
struct ShiftsWeekPane: View {
    @ObservedObject var store: ShiftsStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let state = ShiftsPaneState.resolve(store.state, hasTeams: !store.teams.isEmpty,
                                                forced: model.forced(.native(.shifts)),
                                                offline: model.connection == .offline)
            switch state {
            case .loading: LoadingPane("Loading Shifts\u{2026}")
            case .notSetUp:
                EmptyPane(ShiftsPaneState.notSetUpTitle, systemImage: NativeAppID.shifts.symbol,
                          message: ShiftsPaneState.notSetUpMessage)
            case .emptyWeek: emptyWeek
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { store.refresh() }
            case .week:
                if let week = store.week {
                    let rows = ShiftsRow.rows(week: week, reasons: store.reasons, names: store.memberNames)
                    VStack(spacing: 0) {
                        if let error = store.weekError {
                            // A week that failed behind the grid (the grid stays).
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                        if rows.isEmpty { emptyWeek } else { table(week, rows, model) }
                    }
                    // A week loading behind the grid on screen: a small
                    // spinner at the header's trailing end, never a
                    // loading pane.
                    .overlay(alignment: .topTrailing) {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 5)
                            .padding(.trailing, 8)
                            .opacity(store.isLoadingWeek ? 1 : 0)
                            .help(store.isLoadingWeek ? "Updating Week" : "")
                            .accessibilityLabel("Updating Week")
                            .accessibilityHidden(!store.isLoadingWeek)
                    }
                }
            }
        }
    }

    private var emptyWeek: some View {
        EmptyPane(ShiftsPaneState.emptyWeekTitle, systemImage: "calendar",
                  message: ShiftsSection.weekRange(store.weekStart))
    }

    private func table(_ week: ShiftWeek, _ rows: [ShiftsRow], _ m: WindowModel) -> some View {
        let days = ShiftsDay.week(week.weekStart)
        let selection = Binding<String?>(
            get: { ShiftsSection.selectedRowID(m) },
            set: { ShiftsSection.select($0, m) })
        return Table(rows, selection: selection) {
            TableColumn("Member") { row in ShiftsPersonCell(row: row) }
                .width(min: 140, ideal: 180)
            TableColumnForEach(days) { day in
                TableColumn(day.title) { row in ShiftsDayCell(cells: row.days[day.id]) }
                    .width(min: 96, ideal: 130)
            }
        }
        .contextMenu(forSelectionType: String.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            if let id = ids.first { ShiftsSection.open(id, m) }
        }
    }
}

/// Theme swatch colors (Graph `scheduleEntityTheme`), system colors only.
enum ShiftsTheme {
    static func color(_ theme: String?) -> Color {
        switch theme?.lowercased() ?? "" {
        case "blue", "darkblue": .blue
        case "green", "darkgreen": .green
        case "purple", "darkpurple": .purple
        case "pink", "darkpink": .pink
        case "yellow", "darkyellow": .yellow
        default: .gray
        }
    }
}

struct ShiftsPersonCell: View {
    let row: ShiftsRow
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: row.name, isGroup: row.name == ShiftsRow.openShiftsName)
            Text(row.name)
                .font(AppFont.body(scale))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// One day: each entry is a swatch + time over its label.
struct ShiftsDayCell: View {
    let cells: [ShiftsCell]
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cells) { cell in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(ShiftsTheme.color(cell.theme))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cell.time)
                            .font(AppFont.subheadline(scale))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(cell.isDraft ? "\(cell.label) (Draft)" : cell.label)
                            .font(AppFont.caption(scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The selected row's entries this week (§6.7 inspector = shift).
struct ShiftsInspectorPane: View {
    @ObservedObject var store: ShiftsStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if let model, let id = ShiftsSection.selectedRowID(model), let week = store.week,
           let row = ShiftsRow.rows(week: week, reasons: store.reasons, names: store.memberNames)
               .first(where: { $0.id == id }) {
            detail(row, days: ShiftsDay.week(week.weekStart))
        } else {
            NoSelectionPane("No Shift Selected")
        }
    }

    private func detail(_ row: ShiftsRow, days: [ShiftsDay]) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Avatar(name: row.name, isGroup: row.name == ShiftsRow.openShiftsName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(AppFont.title3(scale))
                        Text(ShiftsSection.weekRange(store.weekStart))
                            .font(AppFont.subheadline(scale))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(days) { day in
                if !row.days[day.id].isEmpty {
                    Section(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                        ForEach(row.days[day.id]) { cell in
                            LabeledContent {
                                Text(cell.time).monospacedDigit()
                            } label: {
                                Label {
                                    Text(cell.label)
                                } icon: {
                                    Circle().fill(ShiftsTheme.color(cell.theme)).frame(width: 8, height: 8)
                                }
                            }
                            if cell.isDraft {
                                LabeledContent("Status", value: "Draft (not shared)")
                            }
                            if let notes = cell.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(AppFont.body(scale))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

