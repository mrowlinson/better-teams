// ChatsPane.swift — Settings ▸ Chats (UI-SPEC §9.4): Return-to-send ·
// density · text size · translation language · templates (list + edit
// fields) · scheduled messages · read receipts and presence (ghost
// mode) · blocked people · quick composer (enable, hotkey recorder) ·
// GIF key (Keychain). Core stores where they exist (`DensityStore`,
// `TranslationStore`, `CannedResponsesStore`, `ScheduledSendStore`,
// `GhostStore`, `BlockedStore`, `KlipyClient` key); app settings
// otherwise. Demo binds to the demo stores and never reads the Keychain.
import OstMacCore
import SwiftUI

struct ChatsPane: View {
    @Bindable var settings: AppSettings
    @ObservedObject var density: DensityStore
    @ObservedObject var translation: TranslationStore
    @ObservedObject var canned: CannedResponsesStore
    @ObservedObject var scheduled: ScheduledSendStore
    @ObservedObject var ghost: GhostStore
    @ObservedObject var blocked: BlockedStore
    let model: WindowModel
    @State private var template: UUID?
    @State private var templateTitle = ""
    @State private var templateBody = ""
    @State private var templateIssue: String?
    @State private var combo = QuickComposerController.combo()
    @State private var gifKey = ""
    @State private var gifSaved = false

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let m, let app = m.app else { return AnyView(SettingsUnavailable(text: "Sign in to set chat options.")) }
        return AnyView(ChatsPane(settings: .shared, density: app.density,
                                 translation: ConversationServices.of(m).translation, canned: app.canned,
                                 scheduled: app.scheduled, ghost: app.ghost, blocked: app.blocked, model: m))
    }

    /// Translation targets offered (plus the current one if elsewhere).
    static let languages = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "nb", "fi", "pl", "ja", "ko",
                            "zh-Hans"]

    private var demo: Bool { model.options.demo }

    var body: some View {
        Form {
            Section("Messages") {
                Toggle("Return sends the message", isOn: $settings.returnSends)
                Text(settings.returnSends ? "Shift-Return starts a new line." : "Shift-Return sends; Return starts a new line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Density", selection: $density.mode) {
                    ForEach(MessageDensity.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                Picker("Text size", selection: Binding(get: { model.textScale }, set: { model.setTextScale($0) })) {
                    ForEach(TextScaleSteps.steps, id: \.description) { v in
                        Text(v == 1.0 ? "Default" : "\(Int((v * 100).rounded()))%").tag(v)
                    }
                }
                Picker("Translate to", selection: $translation.targetLanguageCode) {
                    ForEach(languageCodes, id: \.description) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
            }
            Section {
                List(canned.templates, selection: $template) { t in
                    Text(t.title).tag(t.id)
                }
                .frame(height: 96)
                .onChange(of: template) { _, id in load(id) }
                TextField("Name", text: $templateTitle)
                TextField("Text", text: $templateBody, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Button(template == nil ? "Add Template" : "Save") { saveTemplate() }
                        .disabled(templateTitle.isEmpty || templateBody.isEmpty)
                    Button("Delete") { deleteTemplate() }
                        .disabled(template == nil)
                    if template != nil {
                        Button("New") { template = nil; templateTitle = ""; templateBody = "" }
                    }
                }
            } header: {
                Text("Templates")
            } footer: {
                if let templateIssue {
                    Text(templateIssue).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Scheduled Messages") {
                if scheduled.items.isEmpty {
                    Text("No scheduled messages.").foregroundStyle(.secondary)
                } else {
                    ForEach(scheduled.items) { item in
                        LabeledContent {
                            Button("Cancel") { scheduled.cancel(id: item.id) }
                        } label: {
                            Text(item.chatName)
                            Text("\(item.fireAt.formatted(date: .abbreviated, time: .shortened)) · \(item.text)")
                                .lineLimit(1)
                        }
                    }
                }
            }
            Section {
                Toggle("Ghost mode", isOn: $ghost.master)
                Toggle("Don\u{2019}t send read receipts", isOn: $ghost.suppressReceipts)
                    .disabled(!ghost.master)
                Toggle("Hold my presence and typing", isOn: $ghost.suppressPresence)
                    .disabled(!ghost.master)
            } header: {
                Text("Privacy")
            }
            Section("Blocked People") {
                if blocked.users.isEmpty {
                    Text("No one is blocked.").foregroundStyle(.secondary)
                } else {
                    ForEach(blocked.sortedUsers) { u in
                        LabeledContent(u.displayName) {
                            Button("Unblock") { blocked.unblock(chatID: u.chatID) }
                        }
                    }
                }
            }
            Section {
                Toggle("Quick composer", isOn: $settings.quickComposer)
                LabeledContent("Shortcut") {
                    HotKeyRecorder(combo: combo) { c in
                        combo = c
                        QuickComposerController.setCombo(c)
                        settings.noteQuickComposerChange()
                    }
                    .disabled(!settings.quickComposer)
                }
            } header: {
                Text("Quick Composer")
            } footer: {
                Text("A shortcut that opens a small window to message a recent chat from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if demo {
                    Text("The demo uses sample GIFs.").foregroundStyle(.secondary)
                } else {
                    SecureField("Klipy API key", text: $gifKey)
                    Button("Save Key") {
                        KlipyClient.saveKey(gifKey)
                        gifKey = ""
                        gifSaved = true
                    }
                    .disabled(gifKey.isEmpty)
                }
            } header: {
                Text("GIFs")
            } footer: {
                Text(gifSaved ? "Key saved in your Keychain." : "GIF search needs a Klipy key, kept in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 560)
    }

    private var languageCodes: [String] {
        let cur = translation.targetLanguageCode
        return Self.languages.contains(cur) || cur.isEmpty ? Self.languages : [cur] + Self.languages
    }

    private func load(_ id: UUID?) {
        guard let t = canned.templates.first(where: { $0.id == id }) else { return }
        templateTitle = t.title
        templateBody = t.body
    }

    /// Adds a new template, or saves the selected one (refusals shown).
    private func saveTemplate() {
        if let id = template {
            templateIssue = canned.update(id: id, title: templateTitle, body: templateBody)
        } else {
            templateIssue = canned.add(title: templateTitle, body: templateBody)
            if templateIssue == nil { template = canned.templates.last?.id }
        }
    }

    private func deleteTemplate() {
        guard let id = template else { return }
        canned.delete(id: id)
        template = nil
        templateTitle = ""
        templateBody = ""
    }
}
