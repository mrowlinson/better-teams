// AIPane.swift — Settings ▸ AI (UI-SPEC §9.4): catch-up on/off and
// provider (on-device, OpenCode CLI, OpenAI-compatible) with its
// endpoint and model, the API key (Keychain, through the core
// `CatchUpStore`), and whether the chosen provider is available now.
// Demo: the demo store (in-memory config and key, canned transport).
import OstMacCore
import SwiftUI

struct AIPane: View {
    @ObservedObject var catchUp: CatchUpStore
    @State private var onDevice = OnDeviceSummary.liveAvailability()

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let app = m?.app else { return AnyView(SettingsUnavailable(text: "Sign in to set up Catch Up.")) }
        // The key loads when Settings opens, never at launch (core rule).
        app.catchUp.ensureKeyLoaded()
        return AnyView(AIPane(catchUp: app.catchUp))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Catch Up", isOn: $catchUp.config.enabled)
                Picker("Provider", selection: Binding(get: { catchUp.config.provider },
                                                      set: { catchUp.selectProvider($0) })) {
                    ForEach(CatchUpProvider.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!catchUp.config.enabled)
            } footer: {
                Text("Catch Up summarizes a conversation and lists action items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if catchUp.config.provider == .openAICompatible {
                Section("Service") {
                    TextField("Base URL", text: $catchUp.config.baseURL)
                    TextField("Model", text: $catchUp.config.model)
                    SecureField("API key", text: $catchUp.config.apiKey)
                }
            } else if catchUp.config.provider == .openCodeCLI {
                Section("Service") {
                    TextField("Model", text: $catchUp.config.model)
                }
            }
            Section("Availability") {
                LabeledContent("Status", value: availability)
                if catchUp.config.provider == .openCodeCLI {
                    Button("Check Again") { catchUp.refreshCLIStatus() }
                } else if catchUp.config.provider == .onDevice {
                    Button("Check Again") { onDevice = OnDeviceSummary.liveAvailability() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var availability: String {
        switch catchUp.config.provider {
        case .onDevice:
            switch onDevice {
            case .available: "Ready"
            case .unsupportedOS, .unsupportedDevice: "Not supported on this Mac"
            case .disabled: "Apple Intelligence is off"
            case .downloading: "Model downloading"
            }
        case .openCodeCLI:
            catchUp.cliAvailable ? "OpenCode CLI found" : "OpenCode CLI not found"
        case .openAICompatible:
            catchUp.config.apiKey.isEmpty ? "Needs an API key" : "Ready"
        }
    }
}
