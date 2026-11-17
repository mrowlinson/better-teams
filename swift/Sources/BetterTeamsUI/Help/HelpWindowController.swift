// HelpWindowController.swift — the Help window and the Keyboard
// Shortcuts window (C8a, UI-SPEC §9.1 Help ▸). One window, sidebar
// topics + a shortcuts table generated from the catalog, so the list
// can never drift from the menu bar. Native split view + list.
import AppKit
import SwiftUI

@MainActor
public final class HelpWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = HelpWindowController()

    /// Evidence: the Help window if it was ever created (never creates it).
    private(set) static weak var loaded: HelpWindowController?

    private let state = HelpRootState()

    private init() {
        // Role `.pane`: the content never resizes the window (a
        // `NavigationSplitView` reports no useful fitting size, which
        // collapsed the window to 310x42 under `.settings`).
        let window = NSWindow(contentViewController: Hosting.controller(HelpRootView(state: state),
                                                                        role: .pane, model: nil))
        window.styleMask = [.titled, .closable, .resizable]
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.title = "Better Teams Help"
        window.setContentSize(NSSize(width: 780, height: 600))
        window.minSize = NSSize(width: 640, height: 440)
        super.init(window: window)
        window.delegate = self
        Self.loaded = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Shows Help on `topic` (else the first topic). Evidence orders the
    /// window in without activating the app or taking key (§11.4).
    public func show(topic: String? = nil, evidence: Bool = false) {
        state.selection = topic ?? HelpContent.topics.first?.id ?? "start"
        window?.title = "Better Teams Help"
        order(evidence: evidence)
    }

    /// Shows Help on the shortcuts table.
    public func showShortcuts(evidence: Bool = false) {
        state.selection = HelpRootState.shortcutsID
        window?.title = "Keyboard Shortcuts"
        order(evidence: evidence)
    }

    private func order(evidence: Bool) {
        if evidence {
            window?.center()
            window?.orderFrontRegardless()
        } else {
            if window?.isVisible != true { window?.center() }
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Sidebar selection, owned by the window controller.
@MainActor
@Observable
final class HelpRootState {
    static let shortcutsID = "__shortcuts"
    var selection: String = HelpContent.topics.first?.id ?? "start"
}

private struct HelpRootView: View {
    @Bindable var state: HelpRootState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(HelpContent.topics, id: \.id) { topic in
                    NavigationLink(value: topic.id) {
                        Label(topic.title, systemImage: topic.symbol)
                    }
                }
                NavigationLink(value: HelpRootState.shortcutsID) {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if state.selection == HelpRootState.shortcutsID {
                ShortcutsTableView()
            } else if let topic = HelpContent.topics.first(where: { $0.id == state.selection }) {
                HelpTopicView(topic: topic)
            }
        }
    }
}

/// One topic's content: sections of prose + bullets.
private struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topic.sections.indices, id: \.self) { i in
                    let s = topic.sections[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.heading).font(.headline)
                        Text(s.body).font(.body).foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if !s.bullets.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(s.bullets, id: \.self) { b in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(b).font(.body).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(topic.title)
    }
}

/// Every binding, grouped by menu in standard order.
private struct ShortcutsTableView: View {
    private var sections: [ShortcutSection] { HelpContent.shortcutSections() }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.menu) {
                    ForEach(section.rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                if let note = row.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            if !row.keys.isEmpty {
                                Text(row.keys).font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !HelpContent.planned.isEmpty {
                Section("Planned") {
                    ForEach(HelpContent.planned.indices, id: \.self) { i in
                        let p = HelpContent.planned[i]
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title)
                                Text(p.note).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(p.keys).font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Keyboard Shortcuts")
    }
}
