// AppStoreViews.swift — the Apps store pages in the Apps detail pane
// (APPHOST-B2): home (search, shelves, category grid) and app detail
// (about, capabilities, permissions, domains; Open, Pin, Add to Teams).
// Stable UI: cached rows stay up while the store refreshes; the first
// load shows the shared delayed LoadingPane.
import AppKit
import SwiftUI
import OstMacCore

// MARK: - Home

struct AppStoreHome: View {
    let library: AppsLibrary
    let category: String?
    @State private var query = ""
    @Environment(\.windowModel) private var model

    private var store: AppStoreModel { library.store }

    var body: some View {
        if let m = model {
            if store.apps.isEmpty, store.allManifests.isEmpty {
                if store.loading || (!store.demo && store.error == nil) {
                    LoadingPane("Loading Apps\u{2026}")
                } else {
                    ErrorPane(title: m.connection == .offline ? "You're Offline" : "Couldn't Load Apps",
                              message: store.error ?? "The app store is unavailable.") { store.refresh() }
                }
            } else {
                content(m)
            }
        }
    }

    private func content(_ m: WindowModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let results = store.searchResults {
                    shelf(results.isEmpty ? "No Results" : "Results", results, m)
                } else if let category {
                    shelf(nil, store.apps(inCategory: category), m)
                } else {
                    ForEach(store.shelves, id: \.title) { s in shelf(s.title, s.apps, m) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: query) { _, q in store.search(q) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category ?? "Apps").font(.largeTitle.weight(.semibold))
                Text(category == nil ? "Apps for you and your team, running right in Better Teams."
                                     : "Apps in \(category ?? "")")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if store.searching || (store.loading && !store.apps.isEmpty) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(store.searching ? "Searching" : "Refreshing")
            }
            SearchField(text: $query, placeholder: "Search Apps")
                .frame(width: 240)
                .accessibilityLabel("Search Apps")
        }
    }

    @ViewBuilder
    private func shelf(_ title: String?, _ apps: [TeamsAppManifest], _ m: WindowModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.title3.weight(.semibold)) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)], spacing: 12) {
                ForEach(apps) { a in
                    Button {
                        m.navigator?.select(AppStoreRoute.detail(a.id), in: .apps)
                    } label: {
                        AppStoreCard(app: a, installed: store.isInstalled(a.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AppStoreCard: View {
    let app: TeamsAppManifest
    let installed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconTile(app: app, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.headline).lineLimit(1)
                    if installed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Installed")
                    }
                }
                Text(app.developer ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(app.shortDescription ?? "").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(app.name)
        .accessibilityElement(children: .combine)
    }
}

/// App icon: the manifest's color icon (live, cached by AppIconCache),
/// else an SF Symbol on the app's accent color (demo, or while the icon
/// loads).
struct AppIconTile: View {
    let app: TeamsAppManifest
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            shape.fill(Palette.manifestAccent(app.accentColor) ?? Color.accentColor)
            if let url = AppIconCache.iconURL(app) {
                AppIconImage(url: url, size: size * 0.76, rounded: false) { symbol }
            } else {
                symbol
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: DemoAppStore.symbols[app.id] ?? "square.grid.2x2")
            .font(AppFont.appTileGlyph(size))
            .foregroundStyle(.white)
    }
}

/// A string with a stable identity for ForEach (lint R4).
struct NamedItem: Identifiable, Hashable {
    let id: String
    init(_ id: String) { self.id = id }
}

// MARK: - Detail

struct AppStoreDetail: View {
    let library: AppsLibrary
    let appID: String
    @State private var hostMode = TeamsJSHostMode.automatic
    /// Bumped by Try Again (host status re-reads defaults).
    @State private var hostTick = 0
    @Environment(\.windowModel) private var model

    private var store: AppStoreModel { library.store }

    var body: some View {
        if let m = model {
            if let app = store.manifest(appID) {
                page(app, m)
            } else if store.loading {
                LoadingPane("Loading App\u{2026}", rows: false)
            } else {
                EmptyPane("App Not Found", systemImage: "questionmark.app",
                          message: "This app isn't in your organization's app store.") {
                    Button("Browse Apps") { m.navigator?.select(nil, in: .apps) }
                }
            }
        }
    }

    private func page(_ app: TeamsAppManifest, _ m: WindowModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button {
                    m.navigator?.select(nil, in: .apps)
                } label: {
                    Label("Apps", systemImage: "chevron.backward")
                }
                .buttonStyle(.link)
                header(app, m)
                if let e = store.installError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.failed)
                        .font(.callout)
                }
                section("About") {
                    Text(app.fullDescription ?? app.shortDescription ?? "No description.")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section("Capabilities") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.capabilities(app), id: \.0) { c in
                            Label(c.0, systemImage: c.1)
                        }
                    }
                }
                section("Permissions") {
                    VStack(alignment: .leading, spacing: 6) {
                        let perms = (app.permissions ?? []).map(NamedItem.init)
                        if perms.isEmpty { Text("No special permissions.").foregroundStyle(.secondary) }
                        ForEach(perms) { p in
                            Label(Self.permission(p.id), systemImage: "lock.shield")
                        }
                        if !app.validDomains.isEmpty {
                            Text("Loads content from \(app.validDomains.joined(separator: ", "))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let hosted = library.hostedApp(forCatalogApp: app.id) {
                    section("Hosting") {
                        Picker("Host Mode", selection: $hostMode) {
                            ForEach(TeamsJSHostMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: hostMode) { _, mode in
                            TeamsJSTransportChoice.setMode(mode, app: app.id, demo: store.demo)
                            m.frameHost.hostModeChanged(appID: app.id)
                        }
                        hostStatus(app, hosted, m)
                    }
                }
                links(app)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: app.id) { hostMode = TeamsJSTransportChoice.mode(app.id, demo: store.demo) }
    }

    /// Where the app runs now, and Try Again after a remembered failure.
    @ViewBuilder
    private func hostStatus(_ app: TeamsAppManifest, _ hosted: FrameApp, _ m: WindowModel) -> some View {
        let _ = hostTick
        let demo = store.demo
        let failure = m.frameHost.hostFailure(appID: app.id)
        let text: String = if let failure {
            "This app couldn't load (\(FrameHost.failureMessage(failure))). Its pane shows why, with Retry."
        } else {
            switch hostMode {
            case .automatic: "Runs directly in its pane, signed in with your account, and picks the way it loads."
            case .frameless: "Runs directly as the pane's page, signed in with your account."
            case .iframe: "Runs in a frame inside its pane, signed in with your account."
            }
        }
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if failure != nil {
            Button("Try Again") {
                TeamsJSTransportChoice.forgetFailure(app: app.id, demo: demo)
                m.frameHost.hostModeChanged(appID: app.id)
                hostTick += 1
            }
        }
    }

    private func header(_ app: TeamsAppManifest, _ m: WindowModel) -> some View {
        let hostedApp = library.hostedApp(forCatalogApp: app.id)
        let installed = store.isInstalled(app.id) || hostedApp != nil
        let entry = hostedApp.map { RailEntry.web($0.id) }
        let pinned = entry.map(m.rail.pinned.contains) ?? false
        return HStack(alignment: .top, spacing: 16) {
            AppIconTile(app: app, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title.weight(.semibold))
                Text(app.developer ?? "Unknown publisher").foregroundStyle(.secondary)
                if let cats = app.categories, !cats.isEmpty {
                    Text(cats.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if let hostedApp {
                        Button("Open") { AppActions.open(LibraryItem(hostedApp), m) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        Button(pinned ? "Unpin" : "Pin to Tab Bar") { AppActions.togglePin(LibraryItem(hostedApp), m) }
                    } else if installed {
                        Label("Installed", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if store.installing.contains(app.id) {
                        ProgressView().controlSize(.small)
                        Text("Adding\u{2026}").foregroundStyle(.secondary)
                    } else {
                        Button("Add to Teams") { confirmInstall(app, m) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 8)
                if installed, hostedApp == nil {
                    Text("Use \(app.name) in chats and channels.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func confirmInstall(_ app: TeamsAppManifest, _ m: WindowModel) {
        let who = app.developer.map { " from \($0)" } ?? ""
        m.confirm(title: "Add \u{201C}\(app.name)\u{201D} to Teams?",
                  message: "\(app.name)\(who) will be installed for your account in your organization's Teams "
                      + "and gets the permissions listed on this page.",
                  action: "Add") { store.install(app) }
    }

    @ViewBuilder
    private func links(_ app: TeamsAppManifest) -> some View {
        let list: [(String, String?)] = [("Website", app.websiteUrl), ("Privacy Policy", app.privacyUrl),
                                         ("Terms of Use", app.termsOfUseUrl)]
        let valid = list.compactMap { t, s in s.flatMap(URL.init(string:)).map { (t, $0) } }
            .filter { $0.1.scheme?.lowercased() == "https" }
        if !valid.isEmpty {
            HStack(spacing: 16) {
                ForEach(valid, id: \.0) { t, u in
                    Link(t, destination: u).disabled(store.demo)
                }
            }
            .font(.callout)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            body()
        }
    }

    static func capabilities(_ a: TeamsAppManifest) -> [(String, String)] {
        var out: [(String, String)] = []
        if a.hasPersonalTab { out.append(("Personal app", "person.crop.square")) }
        if a.hasConfigurableTab { out.append(("Tab in channels and chats", "rectangle.stack")) }
        if a.hasBot == true { out.append(("Bot", "bubble.left.and.text.bubble.right")) }
        if a.hasMessagingExtension == true { out.append(("Messaging extension", "text.bubble")) }
        if out.isEmpty { out.append(("Web content", "globe")) }
        return out
    }

    static func permission(_ p: String) -> String {
        switch p {
        case "identity": "Know who you are (name, email, organization)"
        case "messageTeamMembers": "Send messages and notifications to you and your team"
        default: p
        }
    }
}
