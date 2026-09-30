// CustomizeTabBarSheet.swift — View ▸ Customize Tab Bar… (UI-SPEC §5.2):
// the pinned apps as a stock `List` with `.onMove` (the only reorder
// path; no direct drag on the rail), Remove per row, Add from Library….
// Edits a draft: Done applies it, Cancel discards it (§9.5: Cancel + a
// default action, never a lone Done).
import SwiftUI

struct CustomizeTabBarSheet: View {
    let library: AppsLibrary
    @Environment(\.windowModel) private var model
    /// The edited pin order (nil until the sheet appears).
    @State private var draft: [RailEntry]?

    var body: some View {
        if let m = model {
            let pins = draft ?? m.rail.pinned
            VStack(alignment: .leading, spacing: 12) {
                InfoLabel(title: "Customize Tab Bar", subject: "customizing the tab bar",
                          text: "Drag to reorder pinned apps. The first three open with ⌘7, ⌘8 and ⌘9.")
                    .font(.headline)
                list(pins)
                HStack(spacing: 8) {
                    Button("Add from Library…") {
                        apply(pins, m)
                        m.dismissSheet()
                        m.navigator?.select(section: .apps)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { m.dismissSheet() }
                        .keyboardShortcut(.cancelAction)
                    Button("Done") {
                        apply(pins, m)
                        m.dismissSheet()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 400)
            .onAppear { if draft == nil { draft = m.rail.pinned } }
        }
    }

    /// Unpins what the draft removed, then takes its order.
    private func apply(_ pins: [RailEntry], _ m: WindowModel) {
        for e in m.rail.pinned where !pins.contains(e) { m.navigator?.unpin(e) }
        m.rail.setOrder(pins)
    }

    @ViewBuilder
    private func list(_ pins: [RailEntry]) -> some View {
        if pins.isEmpty {
            EmptyPane("No Pinned Apps", systemImage: "pin",
                      message: "Pin apps from the Apps library to add them to the tab bar.")
                .frame(height: 220)
        } else {
            List {
                ForEach(pins, id: \.key) { e in
                    HStack(spacing: 8) {
                        Image(systemName: e.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(library.item(for: e)?.title ?? e.title).lineLimit(1)
                        Spacer()
                        Button("Remove") { draft = pins.filter { $0 != e } }
                            .controlSize(.small)
                    }
                }
                .onMove { from, to in
                    var d = pins
                    d.move(fromOffsets: from, toOffset: to)
                    draft = d
                }
            }
            .listStyle(.bordered)
            .frame(height: 220)
        }
    }
}
