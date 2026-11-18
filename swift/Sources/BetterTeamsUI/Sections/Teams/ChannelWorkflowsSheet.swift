// ChannelWorkflowsSheet.swift — Workflows for one channel (FIXPACK-UI R3):
// list, enable/disable, run now, add from a template. Native grouped
// form. Live sign-ins have no Power Automate access, so the pane says
// so and offers Power Automate; only the demo source acts.
import OstMacCore
import SwiftUI

/// Pure wording for the sheet (tested).
enum ChannelWorkflowsInfo {
    static func lastRun(_ w: ChannelWorkflow, now: Date = Date()) -> String {
        guard let at = w.lastRun else { return "Never run" }
        let when = at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return (w.lastRunSucceeded == false ? "Failed " : "Ran ") + when
    }
}

struct ChannelWorkflowsSheet: View {
    @StateObject var store: ChannelWorkflowsStore
    @ObservedObject var teams: TeamsViewModel
    let channelID: String
    @Environment(\.windowModel) private var model

    /// The team resolves lazily: `?sheet=` presents before demo teams
    /// load, and the store keys by channel, so a missing team never
    /// blocks the sheet (same pattern as ManageChannelSheet).
    private var channelName: String {
        TeamsListPane.locate(channelID, in: teams.teams)?.1.name ?? channelID
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workflows").font(.headline)
                Text(channelName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 460)
        .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            LoadingPane("Loading Workflows\u{2026}")
        case .unsupported(let reason):
            EmptyPane("Workflows Aren\u{2019}t Available Here", systemImage: "bolt.horizontal",
                      message: reason) {
                if let url = TeamsSection.workflowsURL {
                    Button("Open Power Automate") { TeamsLinkRouter.open(url) }
                }
            }
        case .failed(let message):
            ErrorPane(title: "Couldn\u{2019}t Load Workflows", message: message) { Task { await store.load() } }
        case .loaded:
            Form {
                Section("This Channel") {
                    if store.workflows.isEmpty {
                        Text("No workflows yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.workflows) { w in row(w) }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ w: ChannelWorkflow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name).lineLimit(2)
                Text("\(w.trigger) \u{2022} \(ChannelWorkflowsInfo.lastRun(w))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.busy.contains(w.id) { ProgressView().controlSize(.small) }
            Button("Run") { Task { await store.run(w.id) } }
                .disabled(!w.isEnabled || store.busy.contains(w.id))
                .help(w.isEnabled ? "Run this workflow now" : "Turn the workflow on to run it")
            Toggle("Enabled", isOn: Binding(get: { w.isEnabled },
                                            set: { on in Task { await store.setEnabled(on, w.id) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(store.busy.contains(w.id))
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = store.actionError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if store.isSupported, store.state == .loaded {
                Menu("Add Workflow") {
                    ForEach(store.templates) { t in
                        Button(t.name) { Task { await store.add(t) } }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(store.adding || store.templates.isEmpty)
            }
            Button("Done") { model?.dismissSheet() }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
