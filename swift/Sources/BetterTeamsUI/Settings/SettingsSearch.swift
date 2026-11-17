// SettingsSearch.swift — Settings ▸ Search (C8d, SET-13): a search tab
// that jumps to the matching pane. The toolbar tabs are tab-managed,
// so the search lives in its own tab (magnifyingglass, last): a field
// plus one row per matching pane. Pure matcher, unit-tested.
import SwiftUI

/// One searchable settings destination: the pane plus the words that
/// find it.
public struct SettingsSearchItem: Sendable {
    public var pane: String
    public var label: String
    public var keywords: String

    public init(_ pane: String, _ label: String, keywords: String) {
        self.pane = pane
        self.label = label
        self.keywords = keywords
    }
}

public enum SettingsSearch {
    /// Every pane with its search words (kept next to the pane order in
    /// `SettingsWindowController.panes`).
    public static let items: [SettingsSearchItem] = [
        SettingsSearchItem("search", "Search Settings", keywords: "search settings find preferences"),
        SettingsSearchItem("general", "General", keywords: "general default section menu bar dock badge banners login launch at login"),
        SettingsSearchItem("appearance", "Appearance", keywords: "appearance text size glass theme light dark"),
        SettingsSearchItem("accounts", "Accounts", keywords: "accounts sign in sign out add account presence status"),
        SettingsSearchItem("notifications", "Notifications", keywords: "notifications mentions replies quiet hours sounds banners mute"),
        SettingsSearchItem("chats", "Chats", keywords: "chats return sends folders composer drafts scheduled send later"),
        SettingsSearchItem("calls", "Calls", keywords: "calls devices microphone speaker camera push to talk test call show calls"),
        SettingsSearchItem("apps", "Apps", keywords: "apps tabs pinned web"),
        SettingsSearchItem("ai", "AI", keywords: "ai catch up summary sparkles important"),
        SettingsSearchItem("advanced", "Advanced", keywords: "advanced storage cache logs diagnostics"),
    ]

    /// Panes matching `query` (label + keywords, case- and
    /// diacritic-insensitive, all words must match). Blank finds every
    /// pane but this tab itself.
    public static func matching(_ query: String) -> [SettingsSearchItem] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let panes = items.filter { $0.pane != "search" }
        guard !words.isEmpty else { return panes }
        return panes.filter { item in
            let hay = "\(item.label) \(item.keywords)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// The Search tab: field + matching panes (Return opens the first).
struct SettingsSearchPane: View {
    let open: (String) -> Void
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                TextField("Search Settings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { openFirst() }
            }
            Section("Panes") {
                let hits = SettingsSearch.matching(query)
                if hits.isEmpty {
                    Text("No settings match this search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hits, id: \.pane) { item in
                        Button {
                            open(item.pane)
                        } label: {
                            HStack {
                                Text(item.label)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openFirst() {
        if let first = SettingsSearch.matching(query).first { open(first.pane) }
    }
}
