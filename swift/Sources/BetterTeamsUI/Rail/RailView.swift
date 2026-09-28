// RailView.swift — the Teams-style tab bar (UI-SPEC §5.2, D1, DL2).
//
// One top-aligned stack of square labeled buttons in the system sidebar
// slot: Activity … Files → divider → pinned apps → transient → (call
// item, P4a) → More (only when needed) → Apps. Not a source list. The
// only geometry reader in the UI target (R8): capacity depends on the
// container height only.
import OstMacCore
import SwiftUI

struct RailView: View {
    let navigator: Navigator
    @ObservedObject var badges: RailBadgeFeed
    @Environment(\.windowModel) private var model
    @Environment(\.sidebarRowSize) private var systemRowSize
    @State private var railHeight: CGFloat = 0

    var body: some View {
        if let model {
            let h = RailModel.itemHeight(model.options.railSize ?? RailSize(systemRowSize))
            let call = model.call.flatMap { $0.showsRailItem ? $0 : nil }
            let fixed = SectionID.builtIns.count + 1 + (model.rail.transient == nil ? 0 : 1) + (call == nil ? 0 : 1)
            let layout = RailModel.layout(railHeight: railHeight, itemHeight: h,
                                          pinnedCount: model.rail.pinned.count, fixedItems: fixed)
            // Search mode keeps the section it started from selected (it
            // is where Esc returns).
            let current = model.nav.section
            VStack(spacing: RailModel.spacing) {
                ForEach(SectionID.builtIns, id: \.key) { s in
                    item(s, title: RailInfo.title(s), symbol: RailInfo.symbol(s),
                         badge: model.provider(s).badge(model), current: current, height: h)
                }
                Rectangle()
                    .fill(Palette.railDivider)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .accessibilityHidden(true)
                    .padding(.vertical, (RailModel.dividerHeight - 1) / 2)
                ForEach(model.rail.pinned.prefix(layout.visiblePinned), id: \.key) { e in
                    item(e.section, title: e.title, symbol: e.symbol, badge: nil, current: current, height: h)
                }
                if let t = model.rail.transient {
                    item(t.section, title: t.title, symbol: t.symbol, badge: nil, current: current, height: h)
                }
                if let call {
                    CallRailItem(session: call, navigator: navigator, current: current, height: h)
                }
                if layout.showsMore {
                    more(Array(model.rail.pinned.dropFirst(layout.visiblePinned)), current: current, height: h)
                }
                item(.apps, title: "Apps", symbol: "square.grid.2x2", badge: nil, current: current, height: h)
            }
            .padding(.vertical, RailModel.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railHeight = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
            .onChange(of: h, initial: true) { _, new in navigator.railItemHeightDidChange(new) }
        }
    }

    private func item(_ s: SectionID, title: String, symbol: String, badge: Int?,
                      current: SectionID?, height: CGFloat) -> some View {
        let selected = current == s
        return Button {
            navigator.select(section: s)
        } label: {
            RailButtonLabel(title: title, symbol: symbol, badge: badge)
        }
        .buttonStyle(RailButtonStyle(selected: selected, height: height))
        .help(title)
        .accessibilityLabel(RailInfo.accessibilityLabel(title, badge: badge))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu { pinMenu(s) }
    }

    @ViewBuilder
    private func pinMenu(_ s: SectionID) -> some View {
        if let model, let e = model.rail.pinned.first(where: { $0.section == s }) {
            Button("Unpin from Tab Bar") { navigator.unpin(e) }
            Button("Move Up") { model.rail.move(e, by: -1) }
                .disabled(model.rail.pinned.first == e)
            Button("Move Down") { model.rail.move(e, by: 1) }
                .disabled(model.rail.pinned.last == e)
            Divider()
            Button("Customize Tab Bar…") {
                model.presentSheet(SheetRequest(AppsCommands.customizeTabBarSheet, in: .apps))
            }
        } else if let model, let t = model.rail.transient, t.section == s {
            Button("Keep in Tab Bar") { model.rail.pin(t) }
            Button("Close App") { navigator.closeTransient() }
        }
    }

    /// Overflowed pinned apps in rail order; takes the selected style
    /// when the active app is inside it.
    private func more(_ overflow: [RailEntry], current: SectionID?, height: CGFloat) -> some View {
        let active = overflow.contains { $0.section == current }
        return Menu {
            ForEach(overflow, id: \.key) { e in
                Toggle(isOn: Binding(get: { current == e.section },
                                     set: { _ in navigator.select(section: e.section) })) {
                    Label(e.title, systemImage: e.symbol)
                }
            }
        } label: {
            RailButtonLabel(title: "More", symbol: "ellipsis", badge: nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(RailButtonStyle(selected: active, height: height))
        .help("More Apps")
        .accessibilityLabel("More apps")
    }
}

enum RailInfo {
    static func title(_ s: SectionID) -> String {
        switch s {
        case .activity: "Activity"
        case .chat: "Chat"
        case .teams: "Teams"
        case .calendar: "Calendar"
        case .calls: "Calls"
        case .files: "Files"
        case .apps: "Apps"
        case .native(let n): n.title
        case .web(let id): RailModel.webTitle(id)
        case .call: "Call"
        }
    }

    static func symbol(_ s: SectionID) -> String {
        switch s {
        case .activity: "bell"
        case .chat: "bubble.left.and.bubble.right"
        case .teams: "person.3"
        case .calendar: "calendar"
        case .calls: "phone"
        case .files: "folder"
        case .apps: "square.grid.2x2"
        case .native(let n): n.symbol
        case .web(let id): FrameAppDirectory.symbol(id)
        case .call: "phone.connection.fill"
        }
    }

    static func accessibilityLabel(_ title: String, badge: Int?) -> String {
        switch badge {
        case nil: title
        case .some(let n) where n <= 0: "\(title), unread"
        case .some(let n): "\(title), \(n) unread"
        }
    }
}

extension RailSize {
    init(_ s: SidebarRowSize) {
        switch s {
        case .small: self = .small
        case .large: self = .large
        default: self = .medium
        }
    }
}
