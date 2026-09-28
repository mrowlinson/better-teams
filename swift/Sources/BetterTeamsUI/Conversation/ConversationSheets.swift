// ConversationSheets.swift — sheets the conversation presents through
// the one `SheetPresenter` (UI-SPEC §9.5, R17): Forward… and the
// scheduled-messages queue. Names are declared in `ChatCommands`.
// Buttons: Cancel + a default action, never a lone Done.
import OstMacCore
import SwiftUI

@MainActor
enum ConversationSheets {
    /// Sheet body for a conversation sheet request, nil for other names.
    static func view(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        switch r.name {
        case ChatCommands.forwardSheet:
            let conv = m.graph.conv
            let id = r.arg ?? conv.messages.last(where: { !$0.isOwn && !$0.deleted })?.id
            guard let message = id.flatMap({ i in conv.messages.first { $0.id == i } }) else { return nil }
            return AnyView(ForwardSheet(message: message, conv: conv, chats: m.graph.chats))
        case ChatCommands.scheduledSheet:
            guard let store = ConversationServices.of(m).scheduled(m) else { return nil }
            return AnyView(ScheduledQueueSheet(store: store, conv: m.graph.conv, chatID: m.graph.conv.chatID))
        case ChatCommands.snoozeCustomSheet:
            // The chat named by the request (inspector), else the open one.
            guard let id = r.arg ?? m.nav.selection(in: .chat)?.id else { return nil }
            return AnyView(SnoozeCustomSheet(chatID: id, name: m.graph.chats.chat(id: id)?.name,
                                             snooze: ConversationServices.of(m).snooze(m)))
        default:
            return nil
        }
    }
}

struct ForwardSheet: View {
    let message: ChatMessage
    let conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @State private var query = ""
    @State private var picked: String?
    @Environment(\.windowModel) private var model

    private var candidates: [ChatItem] {
        ChatListFormat.filter(chats.chats.filter { $0.id != conv.chatID }, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward Message").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.isOwn ? "You" : message.sender).font(.caption.weight(.semibold))
                Text(MessageActions.forwardPreview(for: message))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SearchField(text: $query, placeholder: "Search Chats")
                .frame(height: 24)
            // Group label over a bordered list (the in-sheet list idiom,
            // as New Chat): its edge lines up with the title and quote.
            VStack(alignment: .leading, spacing: 6) {
                Text("Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                List(selection: $picked) {
                    ForEach(candidates) { c in
                        HStack(spacing: 8) {
                            Avatar(name: c.name, isGroup: c.is_group)
                            Text(c.name).lineLimit(1)
                        }
                        .tag(c.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 220)
                .overlay {
                    if candidates.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Forward") { forward() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func forward() {
        guard let id = picked else { return }
        conv.forward(message, toChatID: id, destName: chats.chat(id: id)?.name)
        model?.dismissSheet()
    }
}

/// Scheduled messages for this chat: send one now (default), delete
/// one, or close. The first message starts selected, so the actions
/// always say what they act on; the list is as tall as its rows.
struct ScheduledQueueSheet: View {
    @ObservedObject var store: ScheduledSendStore
    let conv: ConversationStore
    let chatID: String?
    @State private var picked: String?
    @Environment(\.windowModel) private var model

    private var items: [ScheduledItem] {
        chatID.map { store.pending(for: $0) } ?? store.items
    }

    private static let rowHeight: CGFloat = 44

    private var listHeight: CGFloat {
        items.isEmpty ? 150 : CGFloat(min(items.count, 5)) * Self.rowHeight + 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scheduled Messages").font(.headline)
            List(selection: $picked) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).lineLimit(1)
                        Label(ScheduledPresets.fireLabel(for: item.fireAt), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: Self.rowHeight - 8)
                    .tag(item.id)
                    .contextMenu {
                        Button("Send Now") { sendNow(item) }
                        Button("Delete Message", role: .destructive) { delete(item) }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No Scheduled Messages", systemImage: "clock",
                                           description: Text("Use Send Later in the composer to schedule one."))
                }
            }
            HStack {
                Button("Delete Message", role: .destructive) { if let item = selected { delete(item) } }
                    .disabled(selected == nil)
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Now") { if let item = selected { sendNow(item) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if picked == nil { picked = items.first?.id } }
    }

    private var selected: ScheduledItem? { picked.flatMap { p in items.first { $0.id == p } } }

    /// Removes one from the queue; the next one takes the selection.
    private func delete(_ item: ScheduledItem) {
        let next = items.first { $0.id != item.id }?.id
        store.cancel(id: item.id)
        picked = next
    }

    /// Sends into the open chat only (the queue lists this chat's items).
    private func sendNow(_ item: ScheduledItem) {
        guard item.chatID == conv.chatID, let taken = store.takeForEdit(id: item.id) else { return }
        conv.send(text: taken.text)
        picked = items.first?.id
    }
}

/// Snooze Custom (§6.2 Snooze ▸ Custom…, §9.5): pick the date and time
/// the chat's notifications resume. Starts one hour from now (or the
/// live snooze's end); Snooze is disabled for a time already past.
struct SnoozeCustomSheet: View {
    let chatID: String
    let name: String?
    @ObservedObject var snooze: SnoozeStore
    @State private var until: Date
    @Environment(\.windowModel) private var model

    init(chatID: String, name: String?, snooze: SnoozeStore, now: Date = Date()) {
        self.chatID = chatID
        self.name = name
        self.snooze = snooze
        _until = State(initialValue: snooze.expiry(for: chatID, now: now) ?? now.addingTimeInterval(3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze Until").font(.headline)
            Text(name.map { "Notifications from \($0) resume at the time you choose." }
                 ?? "Notifications from this chat resume at the time you choose.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Snooze Until", selection: $until, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Snooze") {
                    snooze.snooze(chatID: chatID, until: until)
                    model?.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(until <= Date())
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
