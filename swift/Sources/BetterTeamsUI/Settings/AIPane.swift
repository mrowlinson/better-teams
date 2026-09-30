// AIPane.swift — Settings ▸ AI (UI-SPEC §9.4): the one Catch Up
// setting (Off / When I click the AI button / Always up to date) and
// whether this Mac can run it now. Catch Up runs on this Mac only;
// nothing here offers an engine or model choice (AICATCH).
// The deprecated provider picker (OpenCode CLI, OpenAI-compatible)
// appears only behind the hidden `CatchUp.deprecatedProvidersKey`.
// Demo: the demo store (in-memory config and key, canned transport).
import AppKit
import OstMacCore
import SwiftUI

struct AIPane: View {
    @ObservedObject var catchUp: CatchUpStore
    @ObservedObject var feedback: CatchUpFeedbackStore
    @State private var availability = Self.currentAvailability()

    /// Demo evidence (`settings/ai?ai=…`): the status row to show instead
    /// of this Mac's live state.
    @MainActor static var demoAvailability: OnDeviceAvailability?

    @MainActor static func currentAvailability() -> OnDeviceAvailability {
        demoAvailability ?? OnDeviceSummary.liveAvailability()
    }

    /// System Settings ▸ Apple Intelligence & Siri.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let app = m?.app else { return AnyView(SettingsUnavailable(text: "Sign in to set up Catch Up.")) }
        // Deprecated providers only: the key loads when Settings opens,
        // never at launch (core rule).
        if app.catchUp.deprecatedProvidersEnabled { app.catchUp.ensureKeyLoaded() }
        return AnyView(AIPane(catchUp: app.catchUp, feedback: app.catchUpFeedback))
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $catchUp.mode) {
                    ForEach(CatchUpMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel(title: "Catch Up", subject: "Catch Up", text: Self.footer(catchUp.mode))
                }
                .pickerStyle(.radioGroup)
            }
            if catchUp.mode != .off {
                Section {
                    LabeledContent("Status", value: Self.status(availability))
                    // One trailing button row, as in System Settings.
                    if availability != .available {
                        HStack {
                            Spacer()
                            if availability == .disabled || availability == .downloading {
                                Button("Open System Settings\u{2026}") { TeamsLinkRouter.open(Self.systemSettingsURL) }
                            }
                            Button("Check Again") { availability = Self.currentAvailability() }
                        }
                    }
                }
                // CATCHTABS: "Not important" dismissals, stored on this Mac.
                Section {
                    LabeledContent("Items marked Not Important") {
                        HStack(spacing: 8) {
                            Text("\(feedback.count)").monospacedDigit().foregroundStyle(.secondary)
                            Button("Reset") { feedback.reset() }
                                .disabled(feedback.count == 0)
                        }
                    }
                } header: {
                    InfoHeader(title: "Not Important", subject: "Not Important items",
                               text: "Catch Up hides items you mark Not Important and shows fewer like them. Reset brings them back.")
                }
            }
            if catchUp.deprecatedProvidersEnabled {
                deprecatedProviderSection
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsWindowController.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the chosen setting does, in plain words.
    static func footer(_ mode: CatchUpMode) -> String {
        switch mode {
        case .off:
            "The Catch Up button is hidden and nothing is summarized."
        case .onClick:
            "Click Catch Up in a conversation to get a summary and its action items. Messages that mention you or everyone are listed first. Everything stays on this Mac."
        case .alwaysUpToDate:
            "Conversations with new messages are summarized in the background, so you can keep Catch Up open in its own window (Window \u{25B8} Open Catch Up in New Window). Messages that mention you or everyone are listed first. Updates pause in Low Power Mode and while this Mac is hot. Everything stays on this Mac."
        }
    }

    static func status(_ a: OnDeviceAvailability) -> String {
        switch a {
        case .available: "Ready"
        case .unsupportedOS, .unsupportedDevice: "Not available on this Mac"
        case .disabled: "Turn on Apple Intelligence in System Settings"
        case .downloading: "Getting ready \u{2014} Apple Intelligence is still downloading"
        }
    }

    // MARK: - Deprecated: kept for possible return

    /// The pre-AICATCH provider picker, reachable only with the hidden
    /// defaults key set.
    @ViewBuilder private var deprecatedProviderSection: some View {
        Section("Provider (Deprecated)") {
            Picker("Provider", selection: Binding(get: { catchUp.config.provider },
                                                  set: { catchUp.selectProvider($0) })) {
                ForEach(CatchUpProvider.allCases) { Text($0.title).tag($0) }
            }
            if catchUp.config.provider == .openAICompatible {
                TextField("Base URL", text: $catchUp.config.baseURL)
                TextField("Model", text: $catchUp.config.model)
                SecureField("API key", text: $catchUp.config.apiKey)
            } else if catchUp.config.provider == .openCodeCLI {
                TextField("Model", text: $catchUp.config.model)
                LabeledContent("CLI", value: catchUp.cliAvailable ? "Found" : "Not found")
                Button("Check Again") { catchUp.refreshCLIStatus() }
            }
        }
    }
}
