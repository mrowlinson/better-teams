// NewChatSheet.swift — New Chat (UI-SPEC §6.2, §9.5): recent contacts
// filtered by name, or people from the directory as you type. One
// recent contact opens that chat; picked people start a chat (two or
// more = a group, with an optional name) via `AppState.openNewChat`
// (core-a G5). Presented by SheetPresenter as a window sheet
// (`presentAsSheet`), never an overlay.
import OstMacCore
import SwiftUI

struct NewChatSheet: View {
    @ObservedObject var chats: ChatListViewModel
    /// Directory search (active account only; nil in side windows).
    /// The sheet's own store (`directory(_:demo:)`), never
    /// `app.contacts`: Calls Speed Dial shows that store's results, so a
    /// sheet search must not replace them.
    let contacts: ContactsStore?
    /// Recent contacts badge the person's status, like their list row.
    @ObservedObject var presence: PresenceStore

    /// A search-only directory store for one sheet: same searcher as the
    /// app's contacts (demo = canned people), in-memory defaults so it
    /// never reads or writes the Speed Dial pins.
    static func directory(_ app: AppState?, demo: Bool) -> ContactsStore? {
        guard app != nil else { return nil }
        guard demo else { return ContactsStore(defaults: MemoryDefaults()) }
        return ContactsStore(peopleSearcher: { query, _ in DemoData.peopleSearchResponse(for: query) },
                             defaults: MemoryDefaults())
    }
    @State private var query = ""
    @State private var picked: String?
    @State private var people: [TeamMember] = []
    @State private var topic = ""
    @State private var starting = false
    @State private var failure: String?
    @State private var debounce = Debounce(milliseconds: 250)
    @Environment(\.windowModel) private var model

    private var candidates: [ChatItem] {
        let direct = chats.chats.filter { !$0.is_group }
        return ChatListFormat.filter(direct, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Chat").font(.headline)
            SearchField(text: $query, placeholder: "Search People")
                .frame(height: 24)
            if !people.isEmpty {
                PickedPeople(people: $people)
            }
            if people.count > 1 {
                TextField("Group Name", text: $topic, prompt: Text("Optional"))
            }
            if let contacts, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                DirectoryResults(contacts: contacts, people: $people)
            } else {
                recentContacts
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.failed)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(people.count > 1 ? "Start Group Chat" : "Open Chat") { primary() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || (people.isEmpty && picked == nil))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: query) { _, q in
            guard let contacts else { return }
            debounce.schedule { Task { await contacts.search(query: q) } }
        }
    }

    // Group label above a bordered list (the in-sheet list idiom), not
    // an inset-list section header with its full-width rule.
    private var recentContacts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Contacts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            List(selection: $picked) {
                ForEach(candidates) { c in
                    HStack(spacing: 8) {
                        Avatar(name: c.name)
                            .contactHover(name: c.is_group ? "" : c.name)
                            .overlay(alignment: .bottomTrailing) {
                                if let status = presence.availabilityForChat(c.id)
                                    .flatMap(PresenceStatus.from(availability:)) {
                                    PresenceBadge(status: status, size: 10).offset(x: 2, y: 2)
                                }
                            }
                        Text(c.name)
                    }
                    .tag(c.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 200)
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func primary() {
        guard let model else { return }
        if people.isEmpty {
            guard let id = picked else { return }
            model.dismissSheet()
            model.navigator?.select(section: .chat)
            model.navigator?.select(SectionSelection(id: id), in: .chat)
            return
        }
        guard let app = model.app else { return }
        starting = true
        failure = nil
        let chosen = people
        let name = chosen.count > 1 ? topic : nil
        Task { @MainActor in
            let ok = await app.openNewChat(people: chosen, topic: name)
            starting = false
            guard ok else {
                failure = app.newChatError ?? "Couldn't start the chat."
                return
            }
            model.dismissSheet()
            model.navigator?.select(section: .chat)
            if let id = app.openChatID {
                model.navigator?.select(SectionSelection(id: id), in: .chat)
            }
        }
    }
}

/// "To:" line: the picked people, each removable (also New Call).
struct PickedPeople: View {
    @Binding var people: [TeamMember]

    var body: some View {
        HStack(spacing: 6) {
            Text("To:").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(people) { p in
                        Button {
                            people.removeAll { $0.id == p.id }
                        } label: {
                            Label(p.displayName, systemImage: "xmark.circle.fill")
                                .labelStyle(TrailingIconLabel())
                                .contactHover(ContactRef(p), arrowEdge: .bottom)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Remove \(p.displayName)")
                        .accessibilityLabel("Remove \(p.displayName)")
                    }
                }
            }
        }
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.foregroundStyle(.secondary)
        }
    }
}

/// Directory hits for the query; clicking one adds (or removes) them
/// (also New Call).
struct DirectoryResults: View {
    @ObservedObject var contacts: ContactsStore
    @Binding var people: [TeamMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("People")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            List {
                ForEach(contacts.results) { p in
                    let added = people.contains { $0.id == p.id }
                    Button {
                        if added { people.removeAll { $0.id == p.id } } else { people.append(p) }
                    } label: {
                        HStack(spacing: 8) {
                            Avatar(name: p.displayName, person: ContactRef(p))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.displayName)
                                if let email = p.email, !email.isEmpty {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(added ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .contactHover(ContactRef(p))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(added ? "Remove \(p.displayName)" : "Add \(p.displayName)")
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 200)
            .overlay {
                if contacts.isSearching && contacts.results.isEmpty {
                    ProgressView().controlSize(.small)
                } else if let error = contacts.error, contacts.results.isEmpty {
                    ContentUnavailableView("Couldn't Search People", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if contacts.results.isEmpty {
                    ContentUnavailableView.search(text: contacts.lastQuery)
                }
            }
        }
    }
}
