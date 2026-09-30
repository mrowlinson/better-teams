// NotificationsPane.swift — Settings ▸ Notifications (UI-SPEC §9.4):
// enable / preview / sounds (`MessageNotifications`), mention alerts
// (channel mentions in quiet chats, name matching: `RulesStore` switch
// rules), keyword alerts (always / never lists, `RulesStore`), per-chat levels (the chats set
// to Mentions or Muted, `RulesStore`), quiet-hours windows (`QuietHoursStore`),
// Do Not Disturb with auto-expire, Focus sync
// (`FocusSyncStore`), own status + idle Away + lock (`PresenceTruthStore`)
// and the presence schedule (`PresenceScheduleStore`). All core stores; the rules engine reads
// them unchanged. Demo binds to the demo stores (in-memory).
import OstMacCore
import SwiftUI

struct NotificationsPane: View {
    @ObservedObject var notifs: MessageNotifications
    @ObservedObject var rules: RulesStore
    @ObservedObject var quiet: QuietHoursStore
    @ObservedObject var focus: FocusSyncStore
    @ObservedObject var schedule: PresenceScheduleStore
    @ObservedObject var truth: PresenceTruthStore
    @ObservedObject var presence: PresenceStore
    /// Presence writes go to the real account only when signed in (not demo).
    let live: Bool
    let chatName: (String) -> String
    @State private var newAllow = ""
    @State private var newBlock = ""
    @State private var keywordIssue: String?

    @MainActor
    static func make(_ m: WindowModel?) -> AnyView {
        guard let m, let app = m.app else { return AnyView(SettingsUnavailable(text: "Sign in to set notifications.")) }
        let chats = m.graph.chats
        return AnyView(NotificationsPane(notifs: app.notifs, rules: app.rules, quiet: app.quietHours,
                                         focus: app.focusSync, schedule: app.presenceSchedule,
                                         truth: app.presenceTruth, presence: app.presence, live: !m.options.demo,
                                         chatName: { id in chats.chats.first { $0.id == id }?.name ?? "Conversation" }))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow notifications", isOn: $notifs.enabled)
                Toggle("Show message previews", isOn: $notifs.showPreview)
                    .disabled(!notifs.enabled)
                Toggle("Play sounds", isOn: $notifs.sound)
                    .disabled(!notifs.enabled)
            }
            Section {
                Toggle("Channel, team and everyone mentions", isOn: Binding(
                    get: { rules.config.noisyChannelMentions },
                    set: { rules.setSwitch(NotifyRule.noisyChannel, on: $0) }))
                Toggle("Match my name when a mention has no ID", isOn: Binding(
                    get: { rules.config.matchByDisplayName },
                    set: { rules.setSwitch(NotifyRule.nameBackup, on: $0) }))
            } header: {
                InfoHeader(title: "Mention Alerts", subject: "mention alerts",
                           text: "Mentions of you always alert unless the chat is muted. In chats set to Mentions, channel, team and everyone mentions alert only when that switch is on.")
            }
            Section {
                KeywordList(title: "Always alert for", words: rules.config.allowKeywords, text: $newAllow,
                            add: { keywordIssue = rules.addAllowKeyword($0) },
                            remove: { rules.removeAllowKeyword($0) })
                KeywordList(title: "Never alert for", words: rules.config.blockKeywords, text: $newBlock,
                            add: { keywordIssue = rules.addBlockKeyword($0) },
                            remove: { rules.removeBlockKeyword($0) })
            } header: {
                InfoHeader(title: "Keyword Alerts", subject: "keyword alerts",
                           text: "Never beats Always.")
            } footer: {
                if let keywordIssue { Text(keywordIssue).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                let ids = (rules.config.mentionOnlyChatIDs.union(rules.config.mutedChatIDs)).sorted()
                if ids.isEmpty {
                    Text("No chats are muted.").foregroundStyle(.secondary)
                } else {
                    ForEach(ids, id: \.description) { id in
                        Picker(chatName(id), selection: Binding(get: { rules.level(chatID: id) },
                                                                set: { rules.setLevel(chatID: id, level: $0) })) {
                            Text("All Messages").tag(ChatNotifyLevel.all)
                            Text("Mentions").tag(ChatNotifyLevel.mentions)
                            Text("Muted").tag(ChatNotifyLevel.muted)
                        }
                    }
                }
            } header: {
                InfoHeader(title: "Chats", subject: "chat notifications",
                           text: "Change a chat\u{2019}s alerts from its Notifications menu.")
            }
            DoNotDisturbSection(quiet: quiet)
            QuietHoursSection(quiet: quiet, focus: focus)
            PresenceStatusSection(truth: truth, presence: presence, live: live)
            PresenceScheduleSection(schedule: schedule)
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.paneWidth, height: 640)
    }
}

/// One keyword list: removable words + an Add field.
private struct KeywordList: View {
    let title: String
    let words: [String]
    @Binding var text: String
    let add: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(words, id: \.description) { w in
                    HStack {
                        Text(w)
                        Button {
                            remove(w)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(w)")
                    }
                }
                HStack {
                    TextField("Keyword", text: $text, prompt: Text("Keyword"))
                        .labelsHidden()
                        .frame(width: 140)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commit() {
        add(text)
        text = ""
    }
}
