// CalendarSeries.swift — recurring events (R34.28 "View series", R34.29
// "Show all instances"): the links under a series' recurrence text and
// the instances sheet (every occurrence in the window, its response,
// Open). Reads go through the store (`instances` / series-master
// details), fakes in tests and the demo calendar in `--demo`.
import OstMacCore
import SwiftUI

/// "Series" pull-down: View Series (the series master's details) and
/// Show All Instances.
struct SeriesLinks: View {
    let meeting: MeetingItem
    let model: WindowModel

    var body: some View {
        Menu("Series") {
            if meeting.info?.kind != .seriesMaster {
                Button("View Series") { CalendarSection.viewSeries(meeting, model) }
            }
            Button("Show All Instances") { CalendarSection.showInstances(meeting, model) }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// Every occurrence of the series of `eventID` in a selectable list: the
/// opened occurrence starts selected and scrolled into view; Open (the
/// default button), Return or a double-click opens the selection.
struct EventInstancesSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let seriesID: String
    let title: String
    /// The occurrence the sheet was opened from (else the first one from today).
    var openedFrom: String?
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale
    @State private var selection: String?

    private var rows: [MeetingItem]? { week.seriesInstances[seriesID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All instances").font(.headline)
                Text(rows?.first?.subject ?? title).foregroundStyle(.secondary).lineLimit(1)
            }
            Group {
                if let rows, !rows.isEmpty {
                    ScrollViewReader { proxy in
                        List(rows, selection: $selection) { row in
                            instanceRow(row).tag(row.id).id(row.id)
                        }
                        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                            if let id = ids.first { open(id) }
                        }
                        .onAppear { focus(rows, proxy) }
                        .onChange(of: rows.count) { _, _ in focus(rows, proxy) }
                    }
                } else if let error = week.instancesError[seriesID] {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { week.loadInstances(series: seriesID, force: true) }
                    }
                } else if rows == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the series\u{2026}").foregroundStyle(.secondary)
                    }
                } else {
                    Text("No instances in this period").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text(rows.map { "\($0.count) instance\($0.count == 1 ? "" : "s")" } ?? "")
                    .font(AppFont.caption(scale)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model?.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .font(AppFont.body(scale))
        .padding(20)
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { week.loadInstances(series: seriesID) }
    }

    private func open(_ id: String) {
        guard let model, let row = rows?.first(where: { $0.id == id }) else { return }
        CalendarSection.showDetails(row, model)
    }

    /// The row the sheet starts on: the occurrence it was opened from,
    /// else the first one from `now`.
    static func focusID(_ rows: [MeetingItem], openedFrom: String?, now: Date) -> String? {
        if let openedFrom, rows.contains(where: { $0.id == openedFrom }) { return openedFrom }
        return rows.first { (CalendarTime.instant($0.utcStart) ?? .distantPast) >= now }?.id
    }

    /// Select the focus row (the system selection marks it) and center it.
    private func focus(_ rows: [MeetingItem], _ proxy: ScrollViewProxy) {
        guard let id = Self.focusID(rows, openedFrom: openedFrom, now: RelativeClock.shared.now) else { return }
        if selection == nil { selection = id }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    private func instanceRow(_ row: MeetingItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.isOrganizer ? "checkmark.circle" : CalendarDetailsText.responseSymbol(row.info?.myResponse ?? .none))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarFormat.when(row)).monospacedDigit()
                if row.info?.kind == .exception {
                    Text("Changed from the series").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !row.isOrganizer, let r = row.info?.myResponse, !r.isPending {
                Text(r.label).font(AppFont.caption(scale)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
