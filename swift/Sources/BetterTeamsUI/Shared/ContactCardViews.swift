// ContactCardViews.swift — the contact hover card (popover) and the
// full contact card (sheet), in Teams' card order: photo + presence,
// name, title, department, icon actions (chat, org chart, video call,
// audio call, LinkedIn), "Send a quick message" + Send, the bordered
// availability box (presence • availability, work hours, local time),
// contact fields. The sheet keeps header and Overview / Profile /
// Organization / LinkedIn tabs fixed above the scrolling tab content;
// empty fields (and an empty Organization tab) are hidden.
import AppKit
import OstMacCore
import SwiftUI

// MARK: - Actions

@MainActor
enum ContactActions {
    static let sheetName = "contactCard"

    static func member(_ ref: ContactRef) -> TeamMember {
        TeamMember(id: ref.userID ?? ref.email ?? ref.name, displayName: ref.name,
                   userId: ref.userID, email: ref.email)
    }

    static func isOwn(_ ref: ContactRef, _ m: WindowModel?) -> Bool {
        guard let own = m?.app?.ownUserID, let id = ref.userID else { return false }
        return own.caseInsensitiveCompare(id) == .orderedSame
    }

    private static func leaveCard(_ m: WindowModel) {
        ContactHover.shared.dismiss()
        if m.sheet?.name == sheetName { m.dismissSheet() }
    }

    /// Opens the full card; `tab` rides as a 4th U+001F field of the
    /// sheet argument (`ContactRef(encoded:)` ignores it).
    static func openCard(_ ref: ContactRef, _ m: WindowModel, tab: ContactCardSheet.Tab = .overview) {
        ContactHover.shared.dismiss()
        m.presentSheet(SheetRequest(sheetName, in: .chat, arg: sheetArg(ref, tab: tab)))
    }

    static func sheetArg(_ ref: ContactRef, tab: ContactCardSheet.Tab) -> String {
        tab == .overview ? ref.encoded : ref.encoded + "\u{1F}" + tab.rawValue
    }

    static func chat(_ ref: ContactRef, _ m: WindowModel) {
        leaveCard(m)
        m.app?.openSearchPerson(member(ref))
    }

    static func call(_ ref: ContactRef, _ m: WindowModel, video: Bool) {
        guard let app = m.app else { return }
        leaveCard(m)
        Task { @MainActor in
            _ = await app.startCall(with: [member(ref)]) { t in
                if video {
                    // Video goes through the Calls path (1:1 video); skip the audio placement.
                    CallsSection.call(CallsSection.Person(name: t.name, personID: ref.userID,
                                                          personKey: "name:" + t.name, thread: t.threadID),
                                      m, video: true)
                    return false
                }
                return m.beginCall(.person(name: t.name, thread: t.threadID)) != nil
            }
        }
    }

    static func email(_ address: String) {
        ContactHover.shared.dismiss()
        guard let url = URL(string: "mailto:" + address) else { return }
        NSWorkspace.shared.open(url)
    }

    /// `tel:` link for a directory phone number (digits and a leading +).
    static func telURL(_ number: String) -> URL? {
        let t = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = t.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:" + (t.hasPrefix("+") ? "+" : "") + digits)
    }

    static func phone(_ number: String) {
        ContactHover.shared.dismiss()
        if let url = telURL(number) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "3:42 PM - Same time zone as you" / "… - 5 hr ahead of you" for
    /// people whose zone is known (their calendar's working-hours zone;
    /// demo people carry one).
    static func localTime(for card: ContactCard?, now: Date = Date(), viewer: TimeZone = .current) -> String? {
        guard let card, let zone = card.schedule?.timeZone ?? ContactDemo.timeZone(for: card.profile.id)
        else { return nil }
        let diff = zone.secondsFromGMT(for: now) - viewer.secondsFromGMT(for: now)
        guard diff != 0 else { return clock(now, in: zone) + " - Same time zone as you" }
        let hours = Double(abs(diff)) / 3600
        let amount = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
        return clock(now, in: zone) + " - \(amount) hr " + (diff > 0 ? "ahead of you" : "behind you")
    }

    /// "Free all day", "Free at 4:30 PM" (busy until then), "Out of
    /// office" — times in the viewer's zone, like Teams.
    static func availability(for card: ContactCard?, zone: TimeZone = .current) -> String? {
        guard let s = card?.schedule else { return nil }
        let until = s.until.map { " until " + clock($0, in: zone) } ?? ""
        switch s.state {
        case .free: return s.until == nil ? "Free all day" : "Free" + until
        case .busy: return s.until.map { "Free at " + clock($0, in: zone) } ?? "Busy all day"
        case .tentative: return "Tentative" + until
        case .outOfOffice: return "Out of office" + until
        case .workingElsewhere: return "Working elsewhere" + until
        }
    }

    /// "In a call • Free all day": presence, then calendar availability.
    static func statusLine(presence: ContactPresence?, card: ContactCard?) -> String? {
        let parts = [presence.map { $0.outOfOffice ? $0.label + " · Out of office" : $0.label },
                     availability(for: card)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// "9:00 AM - 5:30 PM" in the person's own zone.
    static func workingHours(for card: ContactCard?) -> String? {
        guard let s = card?.schedule, let a = s.workStart, let b = s.workEnd,
              let start = hourMinute(a), let end = hourMinute(b) else { return nil }
        let zone = s.timeZone ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.startOfDay(for: Date())
        guard let d1 = cal.date(byAdding: .minute, value: start, to: day),
              let d2 = cal.date(byAdding: .minute, value: end, to: day) else { return nil }
        return clock(d1, in: zone) + " - " + clock(d2, in: zone)
    }

    /// The person's LinkedIn profile when the lookup matched one, else a
    /// LinkedIn people search for their name and company.
    static func linkedIn(_ ref: ContactRef, _ card: ContactCard?) {
        ContactHover.shared.dismiss()
        let url = card?.linkedIn?.profileURL
            ?? ContactLinkedIn.searchURL(name: card?.profile.displayName ?? ref.name, company: card?.profile.companyName)
        if let url { NSWorkspace.shared.open(url) }
    }

    static func hourMinute(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    static func clock(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// SF Symbol for an insights file type.
    static func fileSymbol(_ type: String?) -> String {
        switch type?.lowercased() {
        case "word": "doc.text"
        case "excel": "tablecells"
        case "powerpoint": "rectangle.on.rectangle"
        case "pdf": "doc.richtext"
        case "onenote": "book.closed"
        default: "doc"
        }
    }
}

// MARK: - Shared pieces (Teams card order)

/// Avatar with presence, name, title and department (stacked on the
/// hover card, "Title • Department" on the full card), status note and
/// out-of-office reply.
private struct ContactHeader: View {
    let ref: ContactRef
    let card: ContactCard?
    let presence: ContactPresence?
    var diameter: CGFloat = 56

    @Environment(\.contentTextScale) private var scale

    private var name: String { card?.profile.displayName ?? ref.name }
    private var large: Bool { diameter > 60 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: name, diameter: diameter, person: card?.ref ?? ref)
                .overlay(alignment: .bottomTrailing) {
                    if let status = presence?.status {
                        PresenceBadge(status: status, size: diameter * 0.26)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(large ? AppFont.title(scale) : AppFont.title3(scale))
                    .textSelection(.enabled)
                    .lineLimit(2)
                let title = card?.profile.jobTitle?.nonEmpty
                let department = card?.profile.department?.nonEmpty
                if large {
                    if let line = [title, department].compactMap({ $0 }).joined(separator: " • ").nonEmpty {
                        secondary(line)
                    }
                } else {
                    if let title { secondary(title) }
                    if let department { secondary(department) }
                }
                if let note = presence?.statusMessage {
                    Label(note, systemImage: "text.bubble")
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let reply = presence?.outOfOfficeNote {
                    Label(reply, systemImage: "airplane")
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(reply)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(AppFont.subheadline(scale))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// Teams' header icons: Chat, Org chart, Video call, Audio call,
/// LinkedIn (email lives in the contact fields). Org chart opens the
/// full card's Organization tab (`orgChart` overrides that inside the
/// card).
private struct ContactActionBar: View {
    let ref: ContactRef
    let card: ContactCard?
    let own: Bool
    var orgChart: (() -> Void)?

    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            if !own {
                action("Chat", "bubble.left") { if let m = model { ContactActions.chat(ref, m) } }
            }
            action("Organization", "flowchart") {
                if let orgChart { orgChart() } else if let m = model { ContactActions.openCard(ref, m, tab: .organization) }
            }
            .disabled(orgChart == nil && model?.sheet != nil)
            if !own {
                action("Video call", "video") { if let m = model { ContactActions.call(ref, m, video: true) } }
                action("Audio call", "phone") { if let m = model { ContactActions.call(ref, m, video: false) } }
            }
            Button { ContactActions.linkedIn(ref, card) } label: {
                Text("in")
                    .font(AppFont.headline(scale))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(card?.linkedIn?.profileURL != nil ? "LinkedIn profile" : "Find on LinkedIn")
            .accessibilityLabel("LinkedIn")
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Quick-message state, owned by the card so the hover card's hidden
/// sizing copy (`CappedScroll`) sees the same text and result line.
@MainActor
final class QuickMessageDraft: ObservableObject {
    @Published var text = ""
    @Published var sending = false
    @Published var result: Bool?
}

/// "Send a quick message": posts to the 1:1 chat without leaving the
/// current view (demo records instead of sending).
private struct QuickMessageField: View {
    let ref: ContactRef
    @ObservedObject var draft: QuickMessageDraft

    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Send a quick message", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.sending)
                    .onSubmit(send)
                    .onChange(of: draft.text) { _, next in if !next.isEmpty { draft.result = nil } }
                    .accessibilityLabel("Send a quick message")
                Button(action: send) {
                    Image(systemName: "paperplane")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(draft.sending || !canSend)
                .help("Send")
                .accessibilityLabel("Send")
            }
            if let result = draft.result {
                HStack(spacing: 6) {
                    Text(result ? "Message sent" : "Couldn't send the message")
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                    if result {
                        Button("Go to chat") { if let m = model { ContactActions.chat(ref, m) } }
                            .buttonStyle(.link)
                            .font(AppFont.caption(scale))
                    }
                }
            }
        }
    }

    private var canSend: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard let app = model?.app, !draft.sending, canSend else { return }
        draft.sending = true
        let body = draft.text
        Task { @MainActor in
            let id = await app.sendQuickMessage(body, to: ContactActions.member(ref))
            draft.sending = false
            draft.result = id != nil
            if id != nil { draft.text = "" }
        }
    }
}

/// Teams' availability box: bordered, presence dot + bold
/// "presence • availability", work hours, then a divider and the
/// person's local time.
private struct ContactStatusLines: View {
    let card: ContactCard?
    let presence: ContactPresence?

    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let line = ContactActions.statusLine(presence: presence, card: card)
        let hours = ContactActions.workingHours(for: card)
        let time = ContactActions.localTime(for: card)
        if line != nil || hours != nil || time != nil {
            VStack(alignment: .leading, spacing: 8) {
                if line != nil || hours != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if let line {
                            HStack(spacing: 6) {
                                if let status = presence?.status {
                                    PresenceBadge(status: status, size: 11)
                                } else {
                                    Image(systemName: "calendar").foregroundStyle(.secondary)
                                }
                                Text(line)
                                    .font(AppFont.subheadline(scale).weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        if let hours {
                            Text("Work hours: " + hours).foregroundStyle(.secondary)
                        }
                    }
                }
                if let time {
                    if line != nil || hours != nil { Divider() }
                    Label(time, systemImage: "clock").foregroundStyle(.secondary)
                }
            }
            .font(AppFont.subheadline(scale))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.panelEdge))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Content-sized up to `maxHeight`, scrolling beyond it. A bare
/// ScrollView in a popover under-reports its ideal height (the popover
/// clipped the card's Contact rows), so a hidden copy of the content
/// sets the height and the scroll view fills it.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .frame(maxHeight: maxHeight, alignment: .top)
            .overlay(alignment: .top) {
                ScrollView { content() }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Hover card

struct ContactHoverCard: View {
    let ref: ContactRef
    var hover: ContactHover = .shared

    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale
    @StateObject private var draft = QuickMessageDraft()

    var body: some View {
        if let store = model?.app?.contactCards {
            // Teams' card scrolls once it is taller than the cap.
            CappedScroll(maxHeight: 480) {
                Content(ref: ref, store: store, draft: draft)
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
            }
        }
    }

    private struct Content: View {
        let ref: ContactRef
        @ObservedObject var store: ContactStore
        @ObservedObject var draft: QuickMessageDraft
        @Environment(\.windowModel) private var model
        @Environment(\.contentTextScale) private var scale

        var body: some View {
            let card = store.card(for: ref)
            let target = card?.ref ?? store.directory.enrich(ref)
            let own = ContactActions.isOwn(target, model)
            let presence = store.presence(for: ref)
            VStack(alignment: .leading, spacing: 10) {
                ContactHeader(ref: ref, card: card, presence: presence)
                ContactActionBar(ref: target, card: card, own: own)
                Divider()
                if card == nil, case .failed(let why) = store.phase(for: ref) {
                    Text(why).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                } else if card == nil {
                    ProgressView().controlSize(.small)
                }
                if !own { QuickMessageField(ref: target, draft: draft) }
                ContactStatusLines(card: card, presence: presence)
                contact(card, target: target)
            }
            .onAppear { store.load(ref) }
        }

        /// "Contact >" (drills into the full card), then email and work
        /// phone as links and the work location as plain text.
        @ViewBuilder private func contact(_ card: ContactCard?, target: ContactRef) -> some View {
            let p = card?.profile
            let email = p?.email ?? ref.email
            let phone = p?.workPhone
            let office = p?.officeLocation?.nonEmpty
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if let m = model { ContactActions.openCard(target, m) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Contact").font(AppFont.headline(scale))
                        Image(systemName: "chevron.right").font(AppFont.caption(scale))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model?.sheet != nil)
                .help(model?.sheet != nil ? "Close the open sheet to view the full profile" : "Open the full contact card")
                .accessibilityLabel("Contact, open the full contact card")
                if let email {
                    Button { ContactActions.email(email) } label: { Label(email, systemImage: "envelope") }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help("Email \(email)")
                }
                if let phone {
                    Button { ContactActions.phone(phone) } label: { Label(phone, systemImage: "phone") }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help("Call \(phone)")
                        .contextMenu { Button("Copy phone number") { ContactActions.copy(phone) } }
                }
                if let office { Label(office, systemImage: "mappin.and.ellipse").textSelection(.enabled) }
            }
            .font(AppFont.subheadline(scale))
        }
    }
}

// MARK: - Full contact card (sheet)

struct ContactCardSheet: View {
    let initial: ContactRef

    @Environment(\.windowModel) private var model
    @State private var history: [ContactRef] = []

    private var current: ContactRef { history.last ?? initial }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let store = model?.app?.contactCards {
                CardBody(ref: current, store: store, initialTab: Self.tab(fromArg: model?.sheet?.arg),
                         back: history.isEmpty ? nil : { history.removeLast() }) { next in history.append(next) }
            }
            Button { model?.dismissSheet() } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .padding(12)
        }
        .frame(width: 560, height: 640)
    }

    enum Tab: String, CaseIterable, Identifiable {
        var id: String { rawValue }
        case overview = "Overview", profile = "Profile", organization = "Organization", linkedIn = "LinkedIn"
    }

    /// The tab named by the sheet argument's 4th field (org-chart icon).
    static func tab(fromArg arg: String?) -> Tab {
        let parts = arg?.components(separatedBy: "\u{1F}") ?? []
        return parts.count > 3 ? Tab(rawValue: parts[3]) ?? .overview : .overview
    }

    /// Tabs in Teams order. Overview, Profile (the full contact fields,
    /// plus about/skills when set) and LinkedIn always show; Organization
    /// hides when the directory has no manager or reports.
    static func tabs(for card: ContactCard?) -> [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .overview, .profile, .linkedIn: true
            case .organization:
                card.map { !$0.orgLoaded || !$0.managers.isEmpty || !$0.reports.isEmpty || $0.failures[.organization] != nil }
                    ?? false
            }
        }
    }

    /// Teams' underline tabs: brand-colored label and bar on the selected tab.
    private struct TabStrip: View {
        let tabs: [Tab]
        @Binding var selection: Tab
        @Environment(\.contentTextScale) private var scale

        var body: some View {
            HStack(spacing: 18) {
                ForEach(tabs) { tab in
                    let on = tab == selection
                    Button { selection = tab } label: {
                        VStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(on ? AppFont.bodyEmphasized(scale) : AppFont.body(scale))
                                .foregroundStyle(on ? Palette.mention : Color.secondary)
                            Rectangle()
                                .fill(on ? Palette.mention : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct CardBody: View {
        let ref: ContactRef
        @ObservedObject var store: ContactStore
        let back: (() -> Void)?
        let open: (ContactRef) -> Void

        @Environment(\.windowModel) private var model
        @Environment(\.contentTextScale) private var scale
        @State private var tab: Tab
        @State private var moreContact = false
        @StateObject private var draft = QuickMessageDraft()

        init(ref: ContactRef, store: ContactStore, initialTab: Tab, back: (() -> Void)?,
             open: @escaping (ContactRef) -> Void) {
            self.ref = ref
            self.store = store
            self.back = back
            self.open = open
            _tab = State(initialValue: initialTab)
        }

        var body: some View {
            let card = store.card(for: ref)
            let target = card?.ref ?? store.directory.enrich(ref)
            let own = ContactActions.isOwn(target, model)
            let tabs = ContactCardSheet.tabs(for: card)
            let shown = tabs.contains(tab) ? tab : .overview
            VStack(alignment: .leading, spacing: 0) {
                // Fixed: header, actions and tabs; only the tab content scrolls.
                VStack(alignment: .leading, spacing: 14) {
                    if let back {
                        Button(action: back) { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(.borderless)
                            .help("Back to the previous contact card")
                    }
                    ContactHeader(ref: ref, card: card, presence: store.presence(for: ref), diameter: 88)
                        .padding(.trailing, 28)
                    ContactActionBar(ref: target, card: card, own: own) { tab = .organization }
                    TabStrip(tabs: tabs, selection: $tab)
                }
                .padding([.horizontal, .top], 20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if card == nil {
                            if case .failed(let why) = store.phase(for: ref) {
                                Text(why).font(AppFont.body(scale)).foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        switch shown {
                        case .overview: overview(card, target: target, own: own)
                        case .profile: if let card { profile(card, target: target) }
                        case .organization: if let card { org(card) }
                        case .linkedIn: linkedIn(card)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear { store.load(ref, org: true) }
            .onChange(of: ref) { _, next in
                tab = .overview
                moreContact = false
                store.load(next, org: true)
            }
        }

        // MARK: Overview

        @ViewBuilder private func overview(_ card: ContactCard?, target: ContactRef, own: Bool) -> some View {
            if !own { QuickMessageField(ref: target, draft: draft) }
            ContactStatusLines(card: card, presence: store.presence(for: ref))
            if let why = card?.failures[.schedule] { failureRow("Local time and availability", why) }
            if let card {
                contactInfo(card, target: target)
                orgSummary(card)
                files(card)
            }
            chats(card?.profile.displayName ?? ref.name)
        }

        /// One contact field: outline icon, grey label, value. Email, Chat
        /// and Work phone are links (mail, open chat, call).
        struct Field {
            let label: String
            let value: String
            let symbol: String
        }

        static func mainFields(_ p: ContactProfile) -> [Field] {
            fields([("Email", p.email, "envelope"), ("Chat", p.chatAddress, "bubble.left"),
                    ("Work phone", p.workPhone, "phone"),
                    ("Work location", p.officeLocation?.nonEmpty, "mappin.and.ellipse"),
                    ("Job title", p.jobTitle?.nonEmpty, "person.text.rectangle"),
                    ("Department", p.department?.nonEmpty, "person.2")])
        }

        static func moreFields(_ p: ContactProfile) -> [Field] {
            fields([("Mobile", p.mobilePhone?.nonEmpty, "iphone"), ("Company", p.companyName?.nonEmpty, "building.2"),
                    ("Location", p.location, "map")])
        }

        private static func fields(_ raw: [(String, String?, String)]) -> [Field] {
            raw.compactMap { label, value, symbol in value.map { Field(label: label, value: $0, symbol: symbol) } }
        }

        /// Teams' fields first (3-column grid); the rest behind "Show more
        /// contact information". Empty fields are left out.
        @ViewBuilder private func contactInfo(_ card: ContactCard, target: ContactRef) -> some View {
            let first = Self.mainFields(card.profile)
            let more = Self.moreFields(card.profile)
            let rows = first + (moreContact ? more : [])
            if !rows.isEmpty {
                section("Contact information") {
                    fieldGrid(rows, target: target)
                    if !more.isEmpty {
                        Button(moreContact ? "Show less contact information" : "Show more contact information") {
                            moreContact.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }

        private func fieldGrid(_ rows: [Field], target: ContactRef) -> some View {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                let lines = stride(from: 0, to: rows.count, by: 3).map { Array(rows[$0..<min($0 + 3, rows.count)]) }
                ForEach(lines, id: \.first?.label) { line in
                    GridRow {
                        ForEach(line, id: \.label) { field($0, target: target) }
                    }
                }
            }
        }

        private func field(_ f: Field, target: ContactRef) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: f.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                    switch f.label {
                    case "Email":
                        link(f.value, help: "Email \(f.value)") { ContactActions.email(f.value) }
                    case "Chat":
                        link(f.value, help: "Chat with \(target.name)") {
                            if let m = model { ContactActions.chat(target, m) }
                        }
                    case "Work phone", "Mobile":
                        link(f.value, help: "Call \(f.value)") { ContactActions.phone(f.value) }
                    default:
                        Text(f.value).font(AppFont.body(scale)).lineLimit(2).textSelection(.enabled).help(f.value)
                    }
                }
            }
            .frame(width: 160, alignment: .leading)
            .contextMenu {
                Button("Copy \(f.label.lowercased())") { ContactActions.copy(f.value) }
            }
        }

        private func link(_ title: String, help: String, _ run: @escaping () -> Void) -> some View {
            Button(title, action: run)
                .buttonStyle(.link)
                .lineLimit(1)
                .help(help)
        }

        /// Manager, then the full chain on the Organization tab.
        @ViewBuilder private func orgSummary(_ card: ContactCard) -> some View {
            if !card.orgLoaded {
                Divider()
                section("Organization") { ProgressView().controlSize(.small) }
            } else if let why = card.failures[.organization] {
                Divider()
                section("Organization") {
                    failureRow(nil, why)
                    if let manager = card.managers.first { personRow(manager, indent: 0) }
                }
            } else if let manager = card.managers.first {
                Divider()
                section("Organization") {
                    Text("Manager").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                    personRow(manager, indent: 0)
                    Button("Show organization") { tab = .organization }
                        .buttonStyle(.link)
                }
            }
        }

        // MARK: Profile

        /// Every contact field (nothing folded away), then the profile
        /// details the directory has (about me, skills, …).
        @ViewBuilder private func profile(_ card: ContactCard, target: ContactRef) -> some View {
            let contact = Self.mainFields(card.profile) + Self.moreFields(card.profile)
            if !contact.isEmpty {
                section("Contact information") { fieldGrid(contact, target: target) }
            }
            if let why = card.failures[.about] {
                Divider()
                failureRow("Profile details", why)
            } else if let about = card.about, !about.isEmpty {
                Divider()
                aboutRows(about)
            }
        }

        @ViewBuilder private func aboutRows(_ about: ContactAbout) -> some View {
            let rows: [(String, String?)] = [
                ("About me", about.aboutMe),
                ("Birthday", about.birthday.map { $0.formatted(.dateTime.month(.wide).day()) }),
                ("Hire date", about.hireDate.map { $0.formatted(date: .long, time: .omitted) }),
                ("Skills", list(about.skills)), ("Interests", list(about.interests)),
                ("Schools", list(about.schools)), ("Past projects", list(about.pastProjects)),
                ("Responsibilities", list(about.responsibilities)),
            ]
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows.compactMap { k, v in v.map { (k, $0) } }, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                        Text(row.1).font(AppFont.body(scale)).textSelection(.enabled)
                    }
                }
            }
        }

        private func list(_ items: [String]) -> String? { items.isEmpty ? nil : items.joined(separator: ", ") }

        // MARK: Organization

        @ViewBuilder private func org(_ card: ContactCard) -> some View {
            if !card.orgLoaded {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let why = card.failures[.organization] { failureRow("Organization", why) }
                    // Top of the chain first, then this person, then reports.
                    ForEach(Array(card.managers.reversed().enumerated()), id: \.element.id) { i, person in
                        personRow(person, indent: CGFloat(i))
                    }
                    selfRow(card, indent: CGFloat(card.managers.count))
                    if !card.reports.isEmpty {
                        Text("Direct reports (\(card.reports.count))")
                            .font(AppFont.caption(scale)).foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(card.reports) { person in personRow(person, indent: 0) }
                    }
                }
            }
        }

        // MARK: LinkedIn

        @ViewBuilder private func linkedIn(_ card: ContactCard?) -> some View {
            let name = card?.profile.displayName ?? ref.name
            VStack(alignment: .leading, spacing: 10) {
                if card?.linkedIn?.profileURL != nil {
                    Text("LinkedIn profile matched from the directory.")
                        .font(AppFont.body(scale)).foregroundStyle(.secondary)
                    Button("View LinkedIn profile") { ContactActions.linkedIn(ref, card) }
                } else {
                    Text("No LinkedIn profile is matched to \(name).")
                        .font(AppFont.body(scale)).foregroundStyle(.secondary)
                    Button("Find \(name) on LinkedIn") { ContactActions.linkedIn(ref, card) }
                    if let li = card?.linkedIn, !li.bound, let bind = li.bindURL {
                        Button("Connect your LinkedIn account") { NSWorkspace.shared.open(bind) }
                            .buttonStyle(.link)
                            .help("Opens LinkedIn in the browser to link your account, so matched profiles show here")
                    }
                }
            }
        }

        // MARK: Files and chats

        /// Files this person shared with you (item insights); hidden when none.
        @ViewBuilder private func files(_ card: ContactCard) -> some View {
            if let why = card.failures[.files] {
                section("Shared files") { failureRow(nil, why) }
            } else if let files = card.sharedFiles, !files.isEmpty {
                section("Shared files") {
                    ForEach(files) { file in fileRow(file) }
                }
            }
        }

        private func fileRow(_ file: ContactSharedFile) -> some View {
            Button {
                if let url = file.webURL { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: ContactActions.fileSymbol(file.type))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.title).font(AppFont.body(scale)).lineLimit(1)
                        if let at = file.sharedAt {
                            Text("Shared \(at.formatted(date: .abbreviated, time: .omitted))")
                                .font(AppFont.caption(scale)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if file.webURL != nil {
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(file.webURL == nil)
            .help(file.webURL == nil ? file.title : "Open \(file.title) in the browser")
        }

        private func selfRow(_ card: ContactCard, indent: CGFloat) -> some View {
            HStack(spacing: 8) {
                Avatar(name: card.profile.displayName ?? ref.name, diameter: 24, person: card.ref)
                Text(card.profile.displayName ?? ref.name).font(AppFont.bodyEmphasized(scale))
                Spacer(minLength: 0)
            }
            .padding(.leading, indent * 14)
        }

        private func personRow(_ person: ContactPerson, indent: CGFloat) -> some View {
            Button { open(person.ref) } label: {
                HStack(spacing: 8) {
                    Avatar(name: person.displayName, diameter: 24, person: person.ref)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(person.displayName).font(AppFont.body(scale))
                        if let title = person.jobTitle {
                            Text(title).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, indent * 14)
            .help("View \(person.displayName)'s contact card")
        }

        @ViewBuilder private func chats(_ name: String) -> some View {
            let recent = (model?.graph.chats.chats ?? [])
                .filter { $0.name.range(of: name, options: .caseInsensitive) != nil }
                .prefix(5)
            if !recent.isEmpty, !name.isEmpty {
                section("Recent chats") {
                    ForEach(Array(recent), id: \.id) { chat in
                        Button {
                            guard let m = model else { return }
                            m.dismissSheet()
                            m.navigator?.select(SectionSelection(id: chat.id), in: .chat)
                            m.navigator?.select(section: .chat)
                        } label: {
                            HStack(spacing: 8) {
                                Avatar(name: chat.name, isGroup: chat.is_group, diameter: 24)
                                Text(chat.name).font(AppFont.body(scale)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        /// A section whose read failed: why, and a Retry that reloads the
        /// whole card (never a silently empty section).
        private func failureRow(_ title: String?, _ why: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(AppFont.headline(scale)) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text(why).font(AppFont.body(scale)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.isRetrying(ref) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Retry") { store.load(ref, org: true, force: true) }
                            .buttonStyle(.link)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(AppFont.headline(scale))
                content()
            }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
