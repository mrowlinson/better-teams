// ChatManageSheets.swift — GAPL2: group chat management, as Teams does
// it (behavior), with native sheets (HIG): Rename Chat…, Add People…
// (with the chat history choice) and Remove from Chat… on a roster row.
// Group chats only; 1:1 chats never offer these.
import OstMacCore
import SwiftUI

@MainActor
enum ChatManageActions {
    static let renameSheet = "renameChat"
    static let addPeopleSheet = "addPeople"

    static func rename(_ id: String, _ m: WindowModel?) {
        m?.presentSheet(SheetRequest(renameSheet, in: .chat, arg: id))
    }

    static func addPeople(_ id: String, _ m: WindowModel?) {
        m?.presentSheet(SheetRequest(addPeopleSheet, in: .chat, arg: id))
    }

    /// Confirm, then remove one other person from a group chat.
    static func remove(_ member: ChatMember, name: String, chatID: String, _ m: WindowModel?) {
        guard let m else { return }
        let chats = m.graph.chats
        guard ChatManageRule.canManage(chats.chat(id: chatID)) else { return }
        let roster = m.app?.chatRoster
        m.confirm(title: "Remove \(name) from the chat?",
                  message: "They won't get new messages from this chat.",
                  action: "Remove", perform: {
                      Task { _ = await chats.removeMember(chatID: chatID, member: member, roster: roster) }
                  })
    }
}

/// Rename Chat: the group name, prefilled; blank clears it.
struct RenameChatSheet: View {
    let chatID: String
    @ObservedObject var chats: ChatListViewModel
    /// Open chat's roster + own id: a cleared name falls back to the
    /// other members' first names.
    var roster: ChatRosterStore?
    var ownUserID: String?
    @State private var topic: String
    /// The field was filled from the chat's name (once; a sheet opened
    /// before the list loads fills when the name arrives).
    @State private var seeded: Bool
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.windowModel) private var model

    init(chatID: String, chats: ChatListViewModel, roster: ChatRosterStore? = nil, ownUserID: String? = nil) {
        self.chatID = chatID
        self.chats = chats
        self.roster = roster
        self.ownUserID = ownUserID
        let name = chats.chat(id: chatID)?.name ?? ""
        _topic = State(initialValue: name)
        _seeded = State(initialValue: !name.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Chat").font(.headline)
            TextField("Group Name", text: $topic, prompt: Text("Group Name"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.failed)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: chats.chat(id: chatID)?.name) { _, name in
            guard !seeded, let name, !name.isEmpty else { return }
            seeded = true
            if topic.isEmpty { topic = name }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        failure = nil
        Task { @MainActor in
            let ok = await chats.renameChat(chatID: chatID, topic: topic, roster: roster, ownUserID: ownUserID)
            saving = false
            if ok { model?.dismissSheet() } else { failure = chats.manageError }
        }
    }
}

/// Which history choice the Add People radio group shows.
enum AddPeopleHistoryMode: Hashable {
    case none, days, all
}

/// Add People: the New Chat people picker plus the history choice.
struct AddPeopleSheet: View {
    let chatID: String
    @ObservedObject var chats: ChatListViewModel
    let contacts: ContactsStore?
    let roster: ChatRosterStore?
    /// This chat's members when `roster` holds another chat.
    @StateObject private var chatMembers: ChatRosterStore
    @State private var query = ""
    @State private var people: [TeamMember] = []
    @State private var mode: AddPeopleHistoryMode = .none
    @State private var days = 1
    @State private var adding = false
    @State private var failure: String?
    @State private var debounce = Debounce(milliseconds: 250)
    @Environment(\.windowModel) private var model

    init(chatID: String, chats: ChatListViewModel, contacts: ContactsStore?, roster: ChatRosterStore?,
         demo: Bool = false) {
        self.chatID = chatID
        self.chats = chats
        self.contacts = contacts
        self.roster = roster
        _chatMembers = StateObject(wrappedValue: ChatRosterStore(demo: demo))
    }

    /// Roster holds this chat → its members (demo adds included), else
    /// the sheet's own load.
    private var rosterHoldsChat: Bool {
        roster?.chatID == chatID && roster?.state == .loaded
    }

    private var members: [ChatMember] {
        rosterHoldsChat ? (roster?.members ?? []) : chatMembers.members
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add People").font(.headline)
            SearchField(text: $query, placeholder: "Search People")
                .frame(height: 24)
            if !people.isEmpty {
                PickedPeople(people: $people)
            }
            if let contacts {
                DirectoryResults(contacts: contacts, people: $people, members: members)
            }
            Text("Chat History")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Chat History", selection: $mode) {
                Text("Don't include chat history").tag(AddPeopleHistoryMode.none)
                Text("Include all chat history").tag(AddPeopleHistoryMode.all)
                Text("Include history from the past number of days").tag(AddPeopleHistoryMode.days)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            // Directly under the option it sets, indented to its text.
            Stepper("\(days) \(days == 1 ? "day" : "days")", value: $days, in: 1...365)
                .disabled(mode != .days)
                .accessibilityLabel("Days of history")
                .padding(.leading, 20)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.failed)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding || people.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            if !rosterHoldsChat { await chatMembers.load(chatID: chatID) }
        }
        .onChange(of: query) { _, q in
            guard let contacts else { return }
            debounce.schedule { Task { await contacts.search(query: q) } }
        }
    }

    var history: ChatHistoryShare {
        switch mode {
        case .none: .none
        case .days: .days(days)
        case .all: .all
        }
    }

    private func add() {
        guard !adding, !people.isEmpty else { return }
        adding = true
        failure = nil
        let chosen = people
        let share = history
        Task { @MainActor in
            let failed = await chats.addPeople(chatID: chatID, people: chosen, history: share, roster: roster)
            adding = false
            if failed.isEmpty, chats.manageError == nil {
                model?.dismissSheet()
            } else {
                // Keep only the people who were not added, so Add again
                // retries just those (the others are already members).
                if !failed.isEmpty {
                    people = ChatManageRule.notAdded(chosen, failed: failed)
                }
                failure = chats.manageError
            }
        }
    }
}
