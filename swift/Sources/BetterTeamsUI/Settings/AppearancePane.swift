// AppearancePane.swift — Settings ▸ Appearance (GLASS lane): Glass-free
// swaps every Liquid Glass control (toolbar buttons, the rail pane,
// floating bars and buttons) for the plain standard macOS look, live in
// every open window (`Chrome`). Off by default.
import SwiftUI

struct AppearancePane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.glassFree) {
                    InfoLabel(title: "Glass-free", subject: "Glass-free",
                              text: "Uses the standard macOS look instead of Liquid Glass.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
