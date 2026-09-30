// GeneralPane.swift — Settings ▸ General (UI-SPEC §9.4): launch at
// login · menu bar extra · Dock badge · banners while active · default
// section. Launch at login is the core's `LoginItemStore`
// (SMAppService); demo toggles an in-memory flag and never touches the
// login item.
import OstMacCore
import SwiftUI

struct GeneralPane: View {
    @Bindable var settings: AppSettings
    /// Nil in demo (in-memory toggle instead).
    let login: LoginItemStore?

    var body: some View {
        Form {
            Section {
                if let login {
                    LoginItemToggle(login: login)
                } else {
                    Toggle("Open at login", isOn: $settings.demoLaunchAtLogin)
                }
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Toggle(isOn: $settings.showDockBadge) {
                    InfoLabel(title: "Show unread count in the Dock", subject: "the Dock unread count",
                              text: "The Dock shows unread chats plus channels that mention you.")
                }
            }
            Section {
                Toggle(isOn: $settings.bannersWhileActive) {
                    InfoLabel(title: "Show banners while Better Teams is active", subject: "banners while active",
                              text: "Calls always show a banner. The conversation on screen never does.")
                }
            }
            Section {
                Picker("Open new windows in:", selection: $settings.defaultSection) {
                    ForEach(AppSettings.defaultSections, id: \.key) { s in
                        Text(s.key.capitalized).tag(s.key)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LoginItemToggle: View {
    @ObservedObject var login: LoginItemStore

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { login.enabled },
                                              set: { on in Task { await login.set(on) } }))
            .disabled(login.busy)
            .onAppear { login.refresh() }
        if let e = login.error {
            Text(e).font(.caption).foregroundStyle(.secondary)
        }
    }
}
