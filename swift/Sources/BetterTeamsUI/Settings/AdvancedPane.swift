// AdvancedPane.swift — Settings ▸ Advanced (UI-SPEC §9.4): diagnostics
// and health (core `HealthStore` check + `DiagnosticsFormat` lines), MCP
// status (the bundled `ostmac-mcp` helper), Export Archive… (the open
// conversation through the core `ArchiveStore`), and maintenance:
// Rebuild Offline Index…, Reset Caches… (both confirm with an alert) and
// Open Logs Folder (writes this session's log there first). Demo runs no
// live probe, writes no file and deletes nothing.
import AppKit
import OSLog
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct AdvancedPane: View {
    @ObservedObject var app: AppStateDiagnostics
    @ObservedObject var health: HealthStore
    @ObservedObject var rebuild: SearchIndexRebuild
    let demo: Bool
    var frameHost: FrameHost?
    @State private var exportResult: String?
    @State private var maintenanceResult: String?

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let m, let app = m.app else { return AnyView(SettingsUnavailable(text: "Sign in to see diagnostics.")) }
        return AnyView(AdvancedPane(app: AppStateDiagnostics(app), health: HealthStore(),
                                    rebuild: app.searchIndexRebuild, demo: m.options.demo,
                                    frameHost: m.frameHost))
    }

    /// The MCP helper shipped next to the app, if this build has it.
    static var mcpHelper: URL? { Bundle.main.url(forAuxiliaryExecutable: "ostmac-mcp") }

    var body: some View {
        Form {
            Section("Diagnostics") {
                LabeledContent("Core", value: app.coreLine)
                LabeledContent("Session", value: app.sessionLine)
                LabeledContent("Realtime", value: app.feedWord)
                LabeledContent("Health") {
                    HStack {
                        Text(healthText).foregroundStyle(.secondary)
                        Button("Run Check") { Task { await health.run() } }
                            .disabled(demo || health.running)
                    }
                }
            }
            Section("MCP") {
                LabeledContent("Server", value: Self.mcpHelper == nil ? "Not included in this build" : "Installed")
                if let url = Self.mcpHelper {
                    LabeledContent("Location") {
                        Text(url.path).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section {
                LabeledContent("Archive") {
                    Button("Export Archive\u{2026}") { export() }
                        .disabled(demo || app.store.conv.chatID == nil)
                }
            } header: {
                InfoHeader(title: "Data", subject: "exporting an archive",
                           text: "Saves the open conversation\u{2019}s loaded messages as a compressed archive.")
            } footer: {
                if let exportResult { Text(exportResult).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                LabeledContent("Offline search") {
                    if let p = rebuild.progress {
                        HStack {
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                .frame(width: 120)
                                .accessibilityLabel("Rebuilding index")
                            Button("Cancel") { rebuild.cancel() }
                        }
                    } else {
                        Button("Rebuild Index\u{2026}") { rebuildIndex() }
                            .disabled(demo)
                    }
                }
                LabeledContent("Caches") {
                    Button("Reset Caches\u{2026}") { resetCaches() }
                        .disabled(demo)
                }
                LabeledContent("Logs") {
                    Button("Open Logs Folder") { LogsFolder.open() }
                        .disabled(demo)
                }
            } header: {
                InfoHeader(title: "Maintenance", subject: "maintenance",
                           text: "Resetting caches keeps your sign-in and settings. Search keeps working while the index rebuilds.")
            } footer: {
                if let status = maintenanceFooter {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var maintenanceFooter: String? {
        if let p = rebuild.progress {
            return "Rebuilding the index: \(p.done) of \(p.total) conversations."
        }
        if let r = maintenanceResult { return r }
        switch rebuild.outcome {
        case .finished(let docs)?: return "Index rebuilt: \(docs) messages."
        case .failed(let e)?: return "Couldn\u{2019}t rebuild: \(e)"
        case .cancelled?: return "Index rebuild cancelled."
        case nil: return nil
        }
    }

    private var healthText: String {
        if demo { return "Not checked in the demo" }
        if health.running { return "Checking\u{2026}" }
        if let e = health.error { return e }
        guard let r = health.report else { return "Not checked" }
        switch r.overall {
        case .ok: return "OK"
        case .degraded: return "Degraded"
        case .broken: return "Not working"
        }
    }

    private func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func rebuildIndex() {
        guard !demo, confirm("Rebuild the offline search index?",
                             "Better Teams re-indexes every conversation stored on this Mac in the background. Search keeps working while it runs.",
                             "Rebuild") else { return }
        maintenanceResult = nil
        app.store.rebuildSearchIndex()
    }

    private func resetCaches() {
        guard !demo, confirm("Reset caches?",
                             "Better Teams deletes downloaded images and media and web apps\u{2019} cached files. They download again when needed.",
                             "Reset") else { return }
        let store = app.store
        let web = frameHost?.dataStore
        Task {
            await store.resetCaches()
            let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
            await web?.removeData(ofTypes: types, modifiedSince: .distantPast)
            maintenanceResult = "Caches reset."
        }
    }

    private func export() {
        let conv = app.store.conv
        guard let name = conv.chatName ?? conv.chatID else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).archive"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let stats = try ArchiveStore.export(conv.messages, to: url)
            exportResult = "Exported \(stats.messageCount) messages."
        } catch {
            exportResult = "Couldn\u{2019}t export: \(error.localizedDescription)"
        }
    }
}

/// The few AppState values the pane shows (R28: never the whole
/// AppState observed from a view).
@MainActor
final class AppStateDiagnostics: ObservableObject {
    let store: AppState
    init(_ store: AppState) { self.store = store }

    var coreLine: String { DiagnosticsFormat.coreLine(version: store.coreVersion, initCode: store.initCode) }
    var sessionLine: String { DiagnosticsFormat.sessionLine(isDemo: store.isDemo, signedIn: store.signedIn) }
    var feedWord: String { DiagnosticsFormat.feedWord(state: store.feedState) }
}

/// Settings ▸ Advanced ▸ Open Logs Folder: `~/Library/Logs/Better Teams`.
/// The app keeps no log file, so opening it first saves this session's
/// unified-log entries (last hour, this process) as a timestamped file.
enum LogsFolder {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(AppIdentity.name)", isDirectory: true)
    }

    @MainActor
    static func open() {
        let dir = url
        Task.blocking(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = snapshot(into: dir)
            await MainActor.run {
                if let file {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else {
                    TeamsLinkRouter.open(dir)
                }
            }
        }
    }

    static func snapshot(into dir: URL, since: TimeInterval = 3600) -> URL? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-since)))
        else { return nil }
        let stamp = ISO8601DateFormatter()
        var text = ""
        for case let e as OSLogEntryLog in entries {
            text += "\(stamp.string(from: e.date)) [\(e.subsystem)] \(e.composedMessage)\n"
        }
        let name = "Session \(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).log"
        let file = dir.appendingPathComponent(name)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}
