// AppsPane.swift — Settings ▸ Apps (UI-SPEC §9.4, §7.3): Keep apps in
// memory (Low 1 / Balanced 3 / High 6: the `FrameHost` LRU cap on
// non-visible web views), Suspend after (0/5/15/30/60 min: the keep-alive
// before a warm view is suspended), the apps in memory with Unload, the
// downloads folder
// and Refresh Library. Values apply to the window's `FrameHost` at once
// (its next attach, detach or memory event evicts or suspends by them)
// and persist under the keys FrameHost reads at launch; demo keeps them
// in memory.
import AppKit
import OstMacCore
import SwiftUI

struct AppsPane: View {
    let host: FrameHost
    let defaults: UserDefaults
    @State private var keep: Int
    @State private var suspendMinutes: Int
    @State private var downloads: URL
    /// Bumped after Unload so the resident list re-reads the host.
    @State private var residentsTick = 0

    struct KeepOption { let n: Int; let title: String }
    static let keepOptions = [KeepOption(n: 1, title: "Low"), KeepOption(n: 3, title: "Balanced"),
                              KeepOption(n: 6, title: "High")]
    static let suspendOptions = [0, 5, 15, 30, 60]

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let m else { return AnyView(SettingsUnavailable(text: "Open a window to set up apps.")) }
        let host = m.frameHost
        return AnyView(AppsPane(host: host, defaults: AppSettings.shared.defaults))
    }

    init(host: FrameHost, defaults: UserDefaults) {
        self.host = host
        self.defaults = defaults
        _keep = State(initialValue: host.keepInMemory)
        _suspendMinutes = State(initialValue: Int(host.keepAlive / 60))
        _downloads = State(initialValue: host.downloadsFolder)
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep apps in memory", selection: $keep) {
                    ForEach(Self.keepOptions, id: \.n) { o in
                        Text("\(o.title) (\(o.n))").tag(o.n)
                    }
                }
                Picker("Suspend background apps after", selection: $suspendMinutes) {
                    ForEach(Self.suspendOptions, id: \.description) { v in
                        Text(v == 0 ? "Immediately" : "\(v) minutes").tag(v)
                    }
                }
            } footer: {
                Text("More apps in memory switch faster and use more memory. Suspended apps reload their page when you return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Apps in Memory") {
                let _ = residentsTick
                let residents = host.residentPages
                if residents.isEmpty {
                    Text("No apps are in memory.").foregroundStyle(.secondary)
                } else {
                    ForEach(residents, id: \.key.raw) { p in
                        LabeledContent(p.title) {
                            if p.isOnScreen {
                                Text("On screen").foregroundStyle(.secondary)
                            } else {
                                Button("Unload") {
                                    host.unload(p.key)
                                    residentsTick += 1
                                }
                                .accessibilityLabel("Unload \(p.title)")
                            }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Save downloads to") {
                    HStack {
                        Label(downloads.lastPathComponent, systemImage: "folder")
                            .help(downloads.path)
                        Button("Choose\u{2026}") { chooseDownloads() }
                    }
                }
            }
            Section {
                LabeledContent("Apps library") {
                    Button("Refresh Library") { host.library.refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: keep) { _, n in
            host.keepInMemory = n
            defaults.set(n, forKey: FramePolicy.keepInMemoryKey)
        }
        .onChange(of: suspendMinutes) { _, v in
            host.keepAlive = TimeInterval(v * 60)
            defaults.set(v, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        }
    }

    private func chooseDownloads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloads
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloads = url
        host.downloadsFolder = url
        defaults.set(url.path, forKey: FrameHost.downloadsFolderKey)
    }
}
