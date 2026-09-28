// ComposerPopovers.swift — transient pickers anchored to the composer
// (UI-SPEC §6.2.2, §9.5): @-mention suggestions, reaction More…, GIF
// search, Send Later. One at a time (`ComposerPopover`); work is kept
// when a popover auto-closes (the draft lives in `ComposerModel`).
import OstMacCore
import SwiftUI

struct ComposerPopoverContent: View {
    let popover: ComposerPopover
    let chatID: String
    let chatName: String
    let conv: ConversationStore
    @ObservedObject var composer: ComposerModel
    let services: ConversationServices
    let roster: [String]
    let mentionIndex: Int
    let pickMention: (String) -> Void
    @Environment(\.windowModel) private var model

    var body: some View {
        switch popover {
        case .mention:
            MentionPicker(names: roster, selected: mentionIndex, pick: pickMention)
        case .reaction(let id):
            ReactionPicker { emoji in
                conv.react(messageID: id, emoji: emoji)
                composer.popover = nil
            }
        case .gif:
            GIFPicker(services: services) { gif in
                let d = composer.draft(chatID)
                composer.setDraft(d.isEmpty ? gif.fullURL : "\(d) \(gif.fullURL)", for: chatID)
                composer.popover = nil
                composer.focusRequest += 1
            }
        case .sendLater:
            if let scheduled = services.scheduled(model) {
                SendLaterPicker(text: composer.draft(chatID)) { date in
                    if scheduled.enqueue(chatID: chatID, chatName: chatName, text: composer.draft(chatID),
                                         fireAt: date) != nil
                    {
                        composer.setDraft("", for: chatID)
                    }
                    composer.popover = nil
                } cancel: {
                    composer.popover = nil
                }
            }
        }
    }
}

/// @-mention suggestions: people in this conversation, filtered by the
/// text after `@`. Arrows/Return/Esc arrive from the composer's field.
struct MentionPicker: View {
    let names: [String]
    let selected: Int
    let pick: (String) -> Void

    var body: some View {
        Group {
            if names.isEmpty {
                Text("No Matching People")
                    .foregroundStyle(.secondary)
                    .frame(width: 240, height: 60)
            } else {
                // System selection (no custom row background, §6): the
                // composer's arrows move it; a click or Return picks.
                // Plain list, no separators: rows sit evenly, edge to edge.
                List(selection: Binding<String?>(
                    get: { names.indices.contains(selected) ? names[selected] : nil },
                    set: { if let n = $0 { pick(n) } })) {
                    ForEach(Indexed.wrap(names)) { n in
                        let on = names.indices.contains(selected) && names[selected] == n.value
                        HStack(spacing: 8) {
                            Avatar(name: n.value, diameter: 22)
                            Text(n.value).lineLimit(1)
                                .foregroundStyle(on ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                        }
                        .frame(height: Self.rowHeight - 4)
                        .listRowSeparator(.hidden)
                        // Focus stays in the composer, so the list draws its
                        // unemphasized (gray) selection, lost on the dark
                        // popover: the arrow-key row gets the emphasized
                        // system selection color instead.
                        .listRowBackground(on ? RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .selectedContentBackgroundColor))
                            .padding(.horizontal, 4) : nil)
                        .tag(n.value)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .scrollContentBackground(.hidden)
                .scrollIndicators(names.count > 6 ? .automatic : .never)
                .frame(width: 240, height: CGFloat(min(names.count, 6)) * Self.rowHeight + 8)
            }
        }
        .accessibilityLabel("Mention Suggestions")
    }

    static let rowHeight: CGFloat = 30
}

/// Reaction More…: the full catalog with a filter field.
struct ReactionPicker: View {
    let pick: (String) -> Void
    @State private var query = ""

    private var entries: [ReactionEntry] {
        query.isEmpty ? ReactionCatalog.all : ReactionCatalog.search(query)
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchField(text: $query, placeholder: "Search Reactions")
                .frame(height: 24)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8), spacing: 4) {
                    ForEach(entries, id: \.emoji) { e in
                        Button { pick(e.emoji) } label: {
                            Text(e.emoji).font(.title2).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .help(e.keywords)
                        .accessibilityLabel(e.keywords)
                    }
                }
            }
            .overlay {
                if entries.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .padding(12)
        .frame(width: 320, height: 300)
    }
}

/// GIF search (Klipy). Results load when the person searches, never
/// on appear (R24).
struct GIFPicker: View {
    let services: ConversationServices
    let pick: (KlipyGIF) -> Void
    @State private var query = ""
    @State private var results: [KlipyGIF] = []
    @State private var searched = ""
    @State private var searching = false

    var body: some View {
        VStack(spacing: 8) {
            // Return searches (a network call per query, not per keystroke).
            SearchField(text: $query, placeholder: "Search GIFs", onSubmit: search)
                .frame(height: 24)
            Group {
                if searching && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(searched.isEmpty ? "Search for a GIF" : "No GIFs Found",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text(searched.isEmpty ? "Results come from Klipy." : ""))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                            ForEach(results) { g in
                                Button { pick(g) } label: {
                                    GIFThumb(model: services.media.image(url: g.previewURL, messageID: "gif-picker"))
                                }
                                .buttonStyle(.plain)
                                .help(g.title)
                                .accessibilityLabel(g.title.isEmpty ? "GIF" : g.title)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(width: 380, height: 320)
    }

    private func search() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task { @MainActor in
            let found = await services.searchGIFs(q)
            // Stale results are dropped (R12): only the latest query lands.
            guard q == query else { return }
            results = found
            searched = q
            searching = false
            for g in found { services.media.image(url: g.previewURL, messageID: "gif-picker").load() }
        }
    }
}

private struct GIFThumb: View {
    @ObservedObject var model: RemoteImageModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.fill.quaternary)
            if let img = model.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if case .failed = model.phase {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 110, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Send Later: preset choice (the chosen one shown selected) plus a
/// graphical date and a time; Cancel + Schedule (default button).
/// Fixed width so the composer can keep it inside the window.
struct SendLaterPicker: View {
    let text: String
    let schedule: (Date) -> Void
    let cancel: () -> Void
    @State private var preset: Preset = .tomorrow
    @State private var date = ScheduledPresets.tomorrow9AM()

    static let width: CGFloat = 250

    enum Preset: Hashable, CaseIterable {
        case oneHour, tonight, tomorrow, custom

        var title: String {
            switch self {
            case .oneHour: "In 1 Hour"
            case .tonight: "Tonight at 8 PM"
            case .tomorrow: "Tomorrow at 9 AM"
            case .custom: "Custom"
            }
        }

        var date: Date? {
            switch self {
            case .oneHour: ScheduledPresets.inOneHour()
            case .tonight: ScheduledPresets.tonight8PM()
            case .tomorrow: ScheduledPresets.tomorrow9AM()
            case .custom: nil
            }
        }
    }

    private var canSchedule: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && date > Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send Later").font(.headline)
            Picker("Send", selection: Binding(get: { preset }, set: { p in
                preset = p
                if let d = p.date { date = d }
            })) {
                ForEach(Preset.allCases, id: \.title) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            // Date and time are the Custom choice's fields: live only
            // while Custom is picked; aligned with the radio column.
            Group {
                DatePicker("Date", selection: customDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatePicker("Time", selection: customDate, displayedComponents: .hourAndMinute)
                    .fixedSize()
            }
            .disabled(preset != .custom)
            Text("Sends \(ScheduledPresets.fireLabel(for: date))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") { schedule(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSchedule)
            }
        }
        .padding(16)
        .frame(width: Self.width)
    }

    /// Editing the date or time makes the choice Custom.
    private var customDate: Binding<Date> {
        Binding(get: { date }, set: { d in
            date = d
            preset = .custom
        })
    }
}
