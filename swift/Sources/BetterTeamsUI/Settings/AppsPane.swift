// AppsPane.swift — Settings ▸ Apps (UI-SPEC §9.4, §7.3): Keep apps in
// memory (Low 1 / Balanced 3 / High 6: the `FrameHost` LRU cap on
// non-visible web views), Suspend after (0/5/15/30/60 min: the keep-alive
// before a warm view is suspended), the apps in memory with Unload, the
// downloads folder, Teams chrome hiding with per-app crops (Reset Crops)
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
    /// Pinned Teams-hosted apps: the ones chrome hiding and crops apply to.
    let teamsApps: [FrameApp]
    @State private var keep: Int
    @State private var suspendMinutes: Int
    @State private var downloads: URL
    @State private var hideChrome: Bool
    @State private var cropApp: FrameAppID?
    @State private var crop: TeamsFrameCrop
    @State private var hasCrops: Bool
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
        let teamsApps: [FrameApp] = m.rail.pinned.compactMap { e in
            guard case .web(let id) = e, let a = host.library.app(id), case .teamsHosted = a.launch else { return nil }
            return a
        }
        return AnyView(AppsPane(host: host, defaults: AppSettings.shared.defaults, teamsApps: teamsApps))
    }

    init(host: FrameHost, defaults: UserDefaults, teamsApps: [FrameApp] = []) {
        self.host = host
        self.defaults = defaults
        self.teamsApps = teamsApps
        _keep = State(initialValue: host.keepInMemory)
        _suspendMinutes = State(initialValue: Int(host.keepAlive / 60))
        _downloads = State(initialValue: host.downloadsFolder)
        _hideChrome = State(initialValue: host.hideChrome)
        let first = teamsApps.first?.id
        _cropApp = State(initialValue: first)
        _crop = State(initialValue: first.map { host.crop(.app($0)) } ?? .none)
        _hasCrops = State(initialValue: !host.crops.isEmpty)
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
                Toggle("Hide the Teams header and app bar", isOn: $hideChrome)
                if let cropApp {
                    Picker("Crop", selection: Binding(get: { cropApp }, set: { select($0) })) {
                        ForEach(teamsApps) { a in Text(a.label).tag(a.id) }
                    }
                    Stepper("Left: \(Int(crop.left)) pt", value: $crop.left, in: 0...400, step: 4)
                    Stepper("Top: \(Int(crop.top)) pt", value: $crop.top, in: 0...400, step: 4)
                }
                LabeledContent("Crops") {
                    Button("Reset Crops") { resetCrops() }
                        .disabled(!hasCrops)
                }
            } header: {
                Text("Teams Apps")
            } footer: {
                Text(teamsApps.isEmpty
                     ? "Pin an app that runs in Teams to set its crop."
                     : "A crop trims edges of Teams that stay visible in an app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Apps library") {
                    Button("Refresh Library") { host.library.refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: keep) { _, n in
            host.keepInMemory = n
            defaults.set(n, forKey: FramePolicy.keepInMemoryKey)
        }
        .onChange(of: suspendMinutes) { _, v in
            host.keepAlive = TimeInterval(v * 60)
            defaults.set(v, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        }
        .onChange(of: crop) { _, c in
            if let cropApp { saveCrop(c, for: cropApp) }
        }
        .onChange(of: hideChrome) { _, on in
            host.hideChrome = on
            defaults.set(on, forKey: FrameChromeStyle.hideKey)
        }
    }

    private func select(_ id: FrameAppID?) {
        cropApp = id
        crop = id.map { host.crop(.app($0)) } ?? .none
    }

    private func saveCrop(_ c: TeamsFrameCrop, for id: FrameAppID) {
        guard host.crop(.app(id)) != c else { return }
        host.setCrop(c, for: .app(id))
        FrameChromeStyle.saveCrops(host.crops, defaults: defaults)
        hasCrops = !host.crops.isEmpty
    }

    private func resetCrops() {
        host.resetCrops()
        FrameChromeStyle.saveCrops(host.crops, defaults: defaults)
        hasCrops = false
        crop = .none
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
