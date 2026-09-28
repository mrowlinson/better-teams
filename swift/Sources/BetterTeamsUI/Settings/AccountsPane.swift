// AccountsPane.swift — Settings ▸ Accounts (UI-SPEC §9.4): the signed-in
// accounts (core `AccountStore`: the active one checked, drag to reorder;
// Add Account…, Sign Out… and Remove… act through the window's commands
// and the store) and the account's web data (Sign In to Web Apps… opens
// Teams on the web in the account's `FrameHost` store in a sheet on the
// main window; Clear Website Data… empties that store). Demo stores
// nothing and changes nothing.
import AppKit
import OstMacCore
import SwiftUI
import WebKit

struct AccountsPane: View {
    @ObservedObject var accounts: AccountStore
    let model: WindowModel?
    @State private var selection: String?
    @State private var cleared = false

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let app = m?.app else { return AnyView(SettingsUnavailable(text: "Sign in to manage accounts.")) }
        return AnyView(AccountsPane(accounts: app.accounts, model: m))
    }

    private var demo: Bool { model?.options.demo != false }

    var body: some View {
        Form {
            Section("Accounts") {
                if accounts.accounts.isEmpty {
                    Text(demo ? "The demo doesn\u{2019}t store accounts." : "No accounts.")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $selection) {
                        ForEach(accounts.accounts) { a in
                            HStack {
                                Image(systemName: a.id == accounts.activeID ? "checkmark" : "person.crop.circle")
                                    .foregroundStyle(a.id == accounts.activeID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(a.displayName)
                                    if let upn = a.upn { Text(upn).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .accessibilityLabel(a.id == accounts.activeID ? "\(a.displayName), active" : a.displayName)
                            .tag(a.id)
                        }
                        .onMove { accounts.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(height: 120)
                }
                HStack {
                    Button("Add Account\u{2026}") { shell(arg: "add") }
                        .disabled(demo)
                    Button("Sign Out\u{2026}") { signOut() }
                        .disabled(demo || accounts.activeID == nil)
                    Button("Remove\u{2026}") { remove() }
                        .disabled(demo || selection == nil || selection == accounts.activeID)
                }
            }
            Section {
                LabeledContent("Sign-in") {
                    Button("Sign In to Web Apps\u{2026}") { shell(arg: "webSignIn") }
                        .disabled(demo || model == nil)
                }
                LabeledContent("Website data") {
                    Button("Clear Website Data\u{2026}") { clearWebData() }
                        .disabled(demo || model == nil)
                }
            } header: {
                Text("Web Apps")
            } footer: {
                Text(cleared ? "Website data cleared. Web apps sign in again when you open them."
                     : "Sign in once and every web app in this account uses that sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Account menu actions (Add Account…, Sign In to Web Apps…) run on
    /// the main window: their sheets need its sheet host (R23).
    private func shell(arg: String) {
        (model?.navigator?.host as? ShellWindowController)?.perform(ShellCommand.account, arg: arg)
    }

    private func signOut() {
        (model?.navigator?.host as? ShellWindowController)?.perform(ShellCommand.signOut, arg: nil)
    }

    private func remove() {
        guard let id = selection, let a = accounts.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(a.displayName)\u{201D}?"
        alert.informativeText = "Better Teams signs out of this account and deletes its local data."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = accounts.removeAccount(id)
        selection = nil
    }

    private func clearWebData() {
        guard let host = model?.frameHost else { return }
        let alert = NSAlert()
        alert.messageText = "Clear website data for this account?"
        alert.informativeText = "Web apps sign in again the next time you open them."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        host.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            cleared = true
        }
    }
}

/// A pane with nothing to edit yet (no account signed in).
struct SettingsUnavailable: View {
    let text: String

    var body: some View {
        Form {
            Text(text).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
