// ActivitySection.swift — Activity section provider (UI-SPEC §6.1).
//
// List = the feed (filter pop-up + Mark All as Read); detail = the
// conversation landed on the item's message (jump API + highlight), a
// missed call's person with Call Back, or "No Item Selected"; inspector
// = the item's conversation info (§5.3). The rail badge and the list
// read one source: `ActivityStore` unreviewed items. Loads and jumps
// start in `selectionDidChange` (R24).
import Combine
import Observation
import OstMacCore
import SwiftUI

@Observable
@MainActor
final class ActivitySectionState {
    var filter: ActivityFilter = .all
    /// Evidence only (`activity?state=error&cached=0`): the load failed
    /// with nothing cached, so the error pane replaces the list.
    var evidenceNoCache = false
}

@MainActor
final class ActivitySection: SectionProvider, InspectorCapable {
    let section: SectionID = .activity
    let title = "Activity"
    let hasInspector = true
    let state = ActivitySectionState()

    /// Conversation info (§5.3) for a selected conversation item only:
    /// with nothing selected, or a missed call (its detail is the
    /// caller, not a conversation), the toggle validates off.
    func hasInspector(for sel: SectionSelection?) -> Bool {
        guard let id = sel?.id else { return false }
        return !id.hasPrefix(ActivityKind.missedCall.rawValue + ":")
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(ActivityInspectorPane(activity: app.activity, saved: m.graph.savedMessages,
                                             chats: m.graph.chats, unread: m.graph.unread))
    }

    func subtitle(_ m: WindowModel) -> String {
        let n = unread(m)
        return n > 0 ? "\(n) unread" : ""
    }

    /// Unreviewed feed items: the one source for the rail badge, the
    /// subtitle, Mark All as Read and the listed rows. A failed refresh
    /// keeps the cached feed listed (R12), so its count stays; a forced
    /// empty/loading state, or an error with nothing cached, has no
    /// listed feed, so no count.
    private func unread(_ m: WindowModel) -> Int {
        guard showsFeed(m) else { return 0 }
        return m.app?.activity.unreviewedCount ?? 0
    }

    /// True when the list pane shows the feed (normal, or the cached
    /// feed under an offline/error banner).
    func showsFeed(_ m: WindowModel) -> Bool {
        switch m.forced(.activity) {
        case nil: true
        case .error: !state.evidenceNoCache && !(m.app?.activity.items.isEmpty ?? true)
        case .empty, .loading: false
        }
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane("No Activity", systemImage: "bell",
                                     message: "Mentions, replies and reactions appear here."))
        }
        return AnyView(ActivityListPane(activity: app.activity, saved: m.graph.savedMessages, state: state,
                                        showsFeed: { [weak self] in self?.showsFeed($0) ?? false }))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane("No Item Selected")) }
        return AnyView(ActivityDetailPane(activity: app.activity, saved: m.graph.savedMessages,
                                          conv: m.graph.conv, chats: m.graph.chats, presence: app.presence,
                                          showsFeed: { [weak self] in self?.showsFeed($0) ?? false }))
    }

    var allToolbarItems: [CommandID] { [ActivityCommands.filter, ActivityCommands.markAllRead] }

    /// Try Again (R18): the feed is built from live events, so a retry
    /// is a fresh look at the store; in demo it clears the forced state.
    static func retry(_ m: WindowModel) {
        m.setForced(nil, for: .activity)
        m.navigator?.applyAll()
        if let a = m.app?.activity { Task { await a.refresh() } }
    }

    /// True when the listed feed has anything the filter can narrow
    /// (feed items or saved messages).
    private func hasItems(_ m: WindowModel) -> Bool {
        guard showsFeed(m), let app = m.app else { return false }
        return !app.activity.items.isEmpty || !m.graph.savedMessages.saves.isEmpty
    }

    func selection(for route: Route) -> SectionSelection? {
        state.evidenceNoCache = route.query["cached"] == "0"
        return route.tail.first.map { SectionSelection(id: $0) }
    }

    /// Opening a row reviews it and lands on its message (§6.1).
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard let id = sel?.id, showsFeed(m), let app = m.app else { return }
        if id.hasPrefix(ActivityRowModel.savedPrefix) {
            guard let s = m.graph.savedMessages.saves.first(where: { ActivityRowModel.savedPrefix + $0.id == id })
            else { return }
            app.jumpToSaved(SearchHit(messageID: s.messageID, chatID: s.chatID, teamID: s.teamID,
                                      channelID: s.channelID, sender: s.sender, timestamp: s.timestamp,
                                      preview: s.preview))
            return
        }
        guard let item = app.activity.item(id: id) else { return }
        if !item.reviewed { app.activity.markReviewed(id: id) }
        // A missed call shows the caller's card, not the thread.
        guard item.kind != .missedCall else { return }
        if let target = app.activity.jumpTarget(id: id), target.canJump {
            app.jumpToActivity(target)
        }
    }

    func badge(_ m: WindowModel) -> Int? {
        let n = unread(m)
        return n > 0 ? n : nil
    }

    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] {
        guard let a = m.app?.activity else { return [] }
        return [a.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
    }

    // MARK: commands

    private func selectedItem(_ m: WindowModel) -> ActivityItem? {
        guard m.nav.search == nil, let id = m.nav.selection(in: .activity)?.id else { return nil }
        return m.app?.activity.item(id: id)
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let activity = m.app?.activity else { return false }
        switch c {
        case ActivityCommands.filter:
            state.filter = ActivityFilter(rawValue: arg ?? "") ?? .all
        case ActivityCommands.markAllRead:
            activity.markAllReviewed()
        case ActivityCommands.markRead:
            guard let item = selectedItem(m) else { return false }
            Self.toggleRead(item, activity)
        default:
            return false
        }
        return true
    }

    static func toggleRead(_ item: ActivityItem, _ activity: ActivityStore) {
        if item.reviewed { activity.markUnreviewed(id: item.id) } else { activity.markReviewed(id: item.id) }
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        let here = m.nav.section == .activity && m.nav.search == nil && m.app != nil
        switch c {
        case ActivityCommands.filter: return CommandValidation(enabled: here && hasItems(m))
        case ActivityCommands.markAllRead:
            return CommandValidation(enabled: here && unread(m) > 0)
        case ActivityCommands.markRead:
            guard here, let item = selectedItem(m) else { return .disabled }
            return CommandValidation(enabled: true, title: item.reviewed ? "Mark Item as Unread" : "Mark Item as Read")
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        guard c == ActivityCommands.filter else { return [] }
        let enabled = m.nav.section == .activity && hasItems(m)
        return ActivityFilter.allCases.map {
            SubmenuItem($0.title, arg: $0.rawValue, checked: state.filter == $0, enabled: enabled,
                        separatorBefore: $0 == .mentions || $0 == .saved)
        }
    }
}

// MARK: list

struct ActivityListPane: View {
    @ObservedObject var activity: ActivityStore
    @ObservedObject var saved: SavedMessageStore
    let state: ActivitySectionState
    let showsFeed: (WindowModel) -> Bool
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            // Opening Activity re-reads the Teams feed in the background
            // (live only; rows merge in place, nothing clears).
            content(model).task { await activity.refresh() }
        }
    }

    @ViewBuilder
    private func content(_ m: WindowModel) -> some View {
        let forced = m.forced(.activity)
        let feed = showsFeed(m)
        let rows = !feed ? [] : ActivityRowModel.rows(
            activity.items, saved: saved.saves, filter: state.filter,
            place: { m.app?.chatNameOrNil(for: $0) ?? DemoFixture.name(for: $0, demo: m.options.demo) ?? "Conversation" },
            isGroup: { id in
                m.graph.chats.chat(id: id)?.is_group ?? DemoFixture.isGroup(id, demo: m.options.demo) ?? false
            })
        if forced == .loading {
            LoadingPane("Loading Activity\u{2026}")
        } else if forced == .error, !feed {
            ErrorPane(title: "Couldn't Load Activity",
                      message: m.connection == .offline ? "You\u{2019}re offline." : "Something went wrong.") {
                ActivitySection.retry(m)
            }
        } else if forced == .error || activity.lastError != nil {
            // R12: a failed refresh keeps the cached feed on screen under
            // an inline notice (ConversationDetail's jump-miss strip idiom)
            // with Try Again (R18, §6 pane states).
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(m.connection == .offline ? "You\u{2019}re offline" : "Couldn\u{2019}t refresh",
                          systemImage: m.connection == .offline ? "wifi.slash" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Try Again") { ActivitySection.retry(m) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help("Showing saved activity")
                Divider()
                if rows.isEmpty {
                    EmptyPane(state.filter.emptyTitle, systemImage: "bell")
                } else {
                    list(rows, m)
                }
            }
        } else if rows.isEmpty {
            if state.filter == .all || forced == .empty {
                EmptyPane("No Activity", systemImage: "bell", message: "Mentions, replies and reactions appear here.")
            } else {
                EmptyPane(state.filter.emptyTitle, systemImage: "line.3.horizontal.decrease") {
                    Button("Show All Activity") { state.filter = .all }
                }
            }
        } else {
            list(rows, m)
        }
    }

    private func list(_ rows: [ActivityRowModel], _ m: WindowModel) -> some View {
        let now = RelativeClock.shared.now
        let selection = Binding<String?>(
            get: { m.nav.selection(in: .activity)?.id },
            set: { id in m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .activity) })
        return List(selection: selection) {
            ForEach(rows) { r in
                ActivityRow(row: r, now: now).tag(r.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open") { m.navigator?.select(SectionSelection(id: id), in: .activity) }
                if let item = activity.item(id: id) {
                    Button(item.reviewed ? "Mark as Unread" : "Mark as Read") {
                        ActivitySection.toggleRead(item, activity)
                    }
                }
                if let s = saved.saves.first(where: { ActivityRowModel.savedPrefix + $0.id == id }) {
                    Button("Remove from Saved") { saved.unsave(chatID: s.chatID, messageID: s.messageID) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { m.navigator?.select(SectionSelection(id: id), in: .activity) }
        }
    }
}

// MARK: detail

struct ActivityDetailPane: View {
    @ObservedObject var activity: ActivityStore
    @ObservedObject var saved: SavedMessageStore
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var presence: PresenceStore
    let showsFeed: (WindowModel) -> Bool
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let id = model.nav.selection(in: .activity)?.id, showsFeed(model) {
            if let item = activity.item(id: id) {
                if item.kind == .missedCall {
                    missedCall(item, model)
                } else if item.chatID.isEmpty {
                    // A feed notification with no source conversation
                    // (app / system items): the item itself.
                    let when = ActivityRow.time(Date(timeIntervalSince1970: TimeInterval(item.at)),
                                                now: RelativeClock.shared.now)
                    PersonCard(name: item.actor.isEmpty ? item.kind.label : item.actor,
                               detail: "\(item.kind.label) \u{00B7} \(when)", detailSymbol: item.kind.systemImage,
                               note: item.snippet.isEmpty ? nil : item.snippet) { EmptyView() }
                } else {
                    ConversationDetail(ref: item.chatID, conv: conv, chats: chats)
                }
            } else if let s = saved.saves.first(where: { ActivityRowModel.savedPrefix + $0.id == id }) {
                ConversationDetail(ref: s.chatID, conv: conv, chats: chats)
            } else {
                NoSelectionPane("No Item Selected")
            }
        } else {
            NoSelectionPane("No Item Selected")
        }
    }

    /// A missed call shows the caller (§6.1): avatar + presence (shape
    /// + color), the missed-call symbol with the word "Missed" and the
    /// time (§10), Call Back (placed on the call's 1:1 thread, as Calls ▸
    /// Call Back; off while a call runs) and Message when that chat is
    /// known (the call thread, else the 1:1 named after the caller).
    private func missedCall(_ item: ActivityItem, _ m: WindowModel) -> some View {
        let when = ActivityRow.time(Date(timeIntervalSince1970: TimeInterval(item.at)), now: RelativeClock.shared.now)
        let chatID = item.chatID.isEmpty
            ? chats.chats.first(where: { !$0.is_group && $0.name == item.actor })?.id
            : item.chatID
        let status = PeerPresence.status(presence, chatID: chatID, userID: item.callerID)
        return PersonCard(name: item.actor, presence: status, detail: "Missed call \u{00B7} \(when)",
                          detailSymbol: ActivityKind.missedCall.systemImage, note: nil) {
            let person = CallsSection.Person(name: item.actor, personID: item.callerID,
                                             personKey: (item.callerID ?? item.actor).lowercased(),
                                             thread: chatID ?? "")
            Button("Call Back") { CallsSection.call(person, m) }
                .disabled(person.thread.isEmpty || !(m.call.map(\.ended) ?? true))
            if let chatID {
                Button("Message") {
                    m.navigator?.select(SectionSelection(id: chatID), in: .chat)
                    m.navigator?.select(section: .chat)
                }
            }
        }
    }
}

// MARK: inspector

/// Conversation info for the selected item's conversation (§5.3).
struct ActivityInspectorPane: View {
    @ObservedObject var activity: ActivityStore
    @ObservedObject var saved: SavedMessageStore
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @Environment(\.windowModel) private var model

    var body: some View {
        ConversationInspector(ref: ref, chats: chats, unread: unread)
    }

    private var ref: String? {
        guard let id = model?.nav.selection(in: .activity)?.id else { return nil }
        if let item = activity.item(id: id) {
            return item.kind == .missedCall || item.chatID.isEmpty ? nil : item.chatID
        }
        return saved.saves.first { ActivityRowModel.savedPrefix + $0.id == id }?.chatID
    }
}
