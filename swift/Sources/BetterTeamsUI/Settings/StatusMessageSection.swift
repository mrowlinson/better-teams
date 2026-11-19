// StatusMessageSection.swift — Settings ▸ Notifications: own status
// message (note under your name in chats and contact cards) with a
// duration picker. Saves via POST /me/presence/setStatusMessage: live
// Set/Clear need Presence.ReadWrite, which the Teams token does not
// carry, so a 403 pins the live-disabled reason (never retried). Demo
// binds a network-free store (setter proven by stub tests).
import OstMacCore
import SwiftUI

struct StatusMessageSection: View {
    @ObservedObject var presence: PresenceStore
    @StateObject private var saver = StatusMessageStore()
    let live: Bool
    @State private var message = ""
    @State private var duration: StatusMessageDuration = .oneHour

    /// Server echo first, local echo after a save, demo/tests last.
    private var current: String? {
        presence.own?.statusMessage ?? saver.savedMessage
    }

    private var draft: StatusMessageDraft {
        StatusMessageDraft(message: message, duration: duration)
    }

    private var overLimit: Bool {
        draft.trimmed.count > StatusMessageDraft.maxLength
    }

    var body: some View {
        Section {
            LabeledContent("Current", value: current.map { String($0.prefix(59)) + ($0.count > 60 ? "…" : "") } ?? "None")
            TextField("Status message", text: $message, prompt: Text("What are you working on?"))
                .textFieldStyle(.roundedBorder)
                .disabled(!live || saver.saving)
                .onChange(of: message) { _, _ in saver.noteEdited() }
            Picker("Duration", selection: $duration) {
                ForEach(StatusMessageDuration.allCases, id: \.rawValue) {
                    Text($0.label).tag($0)
                }
            }
            .disabled(!live || saver.saving)
            HStack {
                Button("Set Status Message") {
                    saver.save(draft)
                    if live { presence.refreshOwnSoon() }
                }
                .disabled(!live || saver.saving || !draft.isSettable || (live && saver.liveDisabledReason != nil))
                Button("Clear", role: .destructive) {
                    saver.clear()
                    if live { presence.refreshOwnSoon() }
                }
                .disabled(!live || saver.saving || (live && saver.liveDisabledReason != nil))
            }
            if overLimit {
                Text("Over 280 characters").font(.caption).foregroundStyle(.secondary)
            }
            if let error = saver.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let reason = saver.liveDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            InfoHeader(title: "Status Message", subject: "status message",
                       text: "A note under your name until it expires. Setting it needs extra permission.")
        }
    }
}
