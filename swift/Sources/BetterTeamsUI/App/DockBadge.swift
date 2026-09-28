// DockBadge.swift — the Dock badge (UI-SPEC §9.3): unread chats +
// unread channel mentions, never raw message counts. One source: the
// same numbers the rail shows on Chat (unread chats) and Teams
// (channels with unread mentions), read from the section providers.
// Settings ▸ General ▸ Dock badge turns it off. Evidence runs never
// touch the Dock tile.
import AppKit
import Combine
import OstMacCore

@MainActor
final class DockBadge {
    /// The rail badges the Dock badge sums (§9.3).
    static let sections: [SectionID] = [.chat, .teams]

    /// Unread chats + channels with unread mentions (the rail's numbers).
    static func count(_ m: WindowModel) -> Int {
        sections.reduce(0) { $0 + (m.provider($1).badge(m) ?? 0) }
    }

    static func label(_ m: WindowModel, enabled: Bool) -> String? {
        guard enabled else { return nil }
        let n = count(m)
        return n > 0 ? String(n) : nil
    }

    private weak var model: WindowModel?
    private let tile: NSDockTile?
    private var subs: Set<AnyCancellable> = []
    private var queued = false
    private(set) var shown: String?

    /// `tile` nil = compute only (tests, evidence).
    init(model: WindowModel, tile: NSDockTile?) {
        self.model = model
        self.tile = tile
        let sources = Self.sections.flatMap { model.provider($0).badgeChanges(model) }
            + [AppSettings.shared.changes]
        for s in sources {
            s.sink { [weak self] in self?.queueRefresh() }.store(in: &subs)
        }
        refresh()
    }

    /// Store publishers fire in willSet; refresh after the value lands.
    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let model else { return }
        let label = Self.label(model, enabled: AppSettings.shared.showDockBadge)
        guard label != shown else { return }
        shown = label
        tile?.badgeLabel = label
    }
}
