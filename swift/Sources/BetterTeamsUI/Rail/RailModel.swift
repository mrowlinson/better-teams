// RailModel.swift — pinned rail entries and the rail's pure geometry
// (UI-SPEC §5.2, §7.1).
//
// Capacity and the window's minimum height are computed from
// constants, never measured, so the fixed items (built-ins, Apps, the
// call item, More) can never overflow.
import Combine
import Foundation
import Observation

/// A pinned rail entry (§7.1): a native app or a web app.
public enum RailEntry: Hashable, Codable, Sendable {
    case native(NativeAppID)
    case web(FrameAppID)

    public var section: SectionID {
        switch self {
        case .native(let n): .native(n)
        case .web(let id): .web(id)
        }
    }

    public var key: String { section.key }

    public var title: String {
        switch self {
        case .native(let n): n.title
        case .web(let id): RailModel.webTitle(id)
        }
    }

    public var symbol: String {
        switch self {
        case .native(let n): n.symbol
        case .web(let id): FrameAppDirectory.symbol(id)
        }
    }
}

/// System sidebar icon size (§5.2 Scale).
public enum RailSize: String, Sendable {
    case small, medium, large
}

/// Result of the capacity computation.
public struct RailLayout: Equatable, Sendable {
    public var visiblePinned: Int
    public var showsMore: Bool
}

@Observable
@MainActor
public final class RailModel {
    public private(set) var pinned: [RailEntry] = []
    /// At most one transient (unpinned, opened from the Library) app.
    public private(set) var transient: RailEntry?

    @ObservationIgnored private let accountKey: String
    @ObservationIgnored private let persist: Bool

    public init(accountKey: String, persist: Bool) {
        self.accountKey = accountKey
        self.persist = persist
        if persist, let data = UserDefaults.standard.data(forKey: Self.key(accountKey)),
           let list = try? JSONDecoder().decode([RailEntry].self, from: data)
        {
            // Pins saved from the retired Apps-list channel tabs: kept
            // when they open natively, else dropped (ChannelTabPins).
            pinned = ChannelTabPins.apply(list, account: accountKey, defaults: .standard)
            if pinned != list { save() }
        }
    }

    private static func key(_ account: String) -> String { "bt.rail.\(account)" }

    /// Evidence (`pins=<n>`, demo only): native apps first, then demo
    /// web apps.
    public func seedDemoPins(_ n: Int) {
        let natives = NativeAppID.allCases.map(RailEntry.native)
        let webs = (1...max(1, 20)).map { RailEntry.web("web-demo-\($0)") }
        pinned = Array((natives + webs).prefix(max(0, n)))
    }

    public func pin(_ e: RailEntry) {
        guard !pinned.contains(e) else { return }
        pinned.append(e)
        if transient == e { transient = nil }
        save()
    }

    public func unpin(_ e: RailEntry) {
        pinned.removeAll { $0 == e }
        save()
    }

    /// Customize Tab Bar sheet (`List.onMove`, §5.2).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Customize Tab Bar ▸ Done: the edited order (entries already
    /// unpinned are dropped).
    public func setOrder(_ order: [RailEntry]) {
        let kept = order.filter(pinned.contains)
        guard kept != pinned else { return }
        pinned = kept
        save()
    }

    public func move(_ e: RailEntry, by delta: Int) {
        guard let i = pinned.firstIndex(of: e) else { return }
        let j = i + delta
        guard pinned.indices.contains(j) else { return }
        pinned.swapAt(i, j)
        save()
    }

    public func setTransient(_ e: RailEntry?) {
        transient = e.flatMap { pinned.contains($0) ? nil : $0 }
    }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(pinned) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(accountKey))
    }

    // MARK: web titles (the Apps library fills the directory)

    nonisolated static func webTitle(_ id: FrameAppID) -> String {
        FrameAppDirectory.title(id)
    }

    // MARK: geometry (pure)

    public nonisolated static let itemWidth: CGFloat = 64
    public nonisolated static let spacing: CGFloat = 2
    public nonisolated static let verticalPadding: CGFloat = 8
    public nonisolated static let dividerHeight: CGFloat = 9
    /// Toolbar safe area above the rail (unified toolbar).
    public nonisolated static let toolbarSafeArea: CGFloat = 52

    public nonisolated static func itemHeight(_ size: RailSize) -> CGFloat {
        switch size {
        case .small: 48
        case .medium: 54
        case .large: 60
        }
    }

    /// `max(600, toolbarSafeArea + railPadding + 9 × itemHeight +
    /// divider)`, rounded up to a multiple of 20 (§5.2): 9 = six
    /// built-ins + call + More + Apps.
    public nonisolated static func minimumWindowHeight(itemHeight h: CGFloat) -> CGFloat {
        let items: CGFloat = 9
        // The divider is a stack child too: items + divider = items gaps.
        let raw = toolbarSafeArea + 2 * verticalPadding + items * h + items * spacing + dividerHeight
        return max(600, (raw / 20).rounded(.up) * 20)
    }

    /// Capacity = floor((railHeight − fixedChrome) / itemHeight). Pinned
    /// apps that don't fit go into More (which takes one slot).
    /// - Parameters:
    ///   - railHeight: rail content height inside the safe area.
    ///   - fixedItems: built-ins + Apps + transient + call item.
    public nonisolated static func layout(railHeight: CGFloat, itemHeight h: CGFloat,
                                          pinnedCount: Int, fixedItems: Int) -> RailLayout {
        guard pinnedCount > 0 else { return RailLayout(visiblePinned: 0, showsMore: false) }
        let usable = railHeight - 2 * verticalPadding - dividerHeight
        // n items plus the divider leave n stack gaps.
        let slots = Int((usable / (h + spacing)).rounded(.down))
        let free = max(0, slots - fixedItems)
        if pinnedCount <= free { return RailLayout(visiblePinned: pinnedCount, showsMore: false) }
        return RailLayout(visiblePinned: max(0, free - 1), showsMore: true)
    }
}

/// Re-publishes badge-source store changes so the rail re-renders
/// (the stores are ObservableObjects; sections declare their sources).
@MainActor
final class RailBadgeFeed: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    init(_ sources: [AnyPublisher<Void, Never>]) {
        for s in sources {
            s.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }
}
