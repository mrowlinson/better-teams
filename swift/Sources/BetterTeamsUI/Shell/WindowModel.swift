// WindowModel.swift — UI-only state for one account window (UI-SPEC
// §11.3). Domain state stays in the core's ObservableObject stores,
// reached through `graph`; nothing here mirrors a store field (R3).
import Foundation
import Observation
import OstMacCore

/// Connection state shown by the trailing toolbar item (§5.7).
public enum ConnectionState: Sendable, Equatable {
    case online, offline, expired
}

@Observable
@MainActor
public final class WindowModel {
    @ObservationIgnored public let graph: any AccountGraph
    /// Persistence namespace ("demo" in demo mode, so demo state never
    /// reaches a live account's keys).
    @ObservationIgnored public let accountKey: String
    @ObservationIgnored public let options: LaunchOptions
    @ObservationIgnored public let frameHost: FrameHost
    public let nav = NavigationModel()
    public let rail: RailModel
    public let search = SearchModel()
    /// The running call (P4a), nil when none.
    public var call: CallSession?
    /// The one sheet (R17); `SheetPresenter` presents it.
    public internal(set) var sheet: SheetRequest?
    /// Text size (§10): 1.0 … 2.0.
    public internal(set) var textScale: Double = 1.0
    /// Evidence-forced pane states (demo only, §11.3 `state=`).
    public internal(set) var forcedState: [SectionID: ForcedPaneState] = [:]
    /// Inspector segment requested by a route (`inspector=<segment>`).
    public internal(set) var inspectorSegment: String?
    public internal(set) var connection: ConnectionState = .online

    @ObservationIgnored private var providers: [SectionID: SectionProvider] = [:]
    @ObservationIgnored weak var presenter: SheetPresenter?
    @ObservationIgnored public weak var navigator: Navigator?

    public init(graph: any AccountGraph, accountKey: String, options: LaunchOptions) {
        self.graph = graph
        self.accountKey = accountKey
        self.options = options
        self.rail = RailModel(accountKey: accountKey, persist: !options.evidence)
        self.frameHost = FrameHost(accountKey: accountKey)
        search.window = self
        frameHost.window = self
    }

    /// The composition root when this window shows the active account.
    public var app: AppState? { graph as? AppState }

    public func provider(_ s: SectionID) -> SectionProvider {
        if let p = providers[s] { return p }
        let p = SectionRegistry.make(s)
        providers[s] = p
        return p
    }

    func forced(_ s: SectionID) -> ForcedPaneState? {
        options.demo ? forcedState[s] : nil
    }

    func setForced(_ state: ForcedPaneState?, for s: SectionID) {
        guard options.demo else { return }
        forcedState[s] = state
    }

    func setTextScale(_ v: Double) {
        textScale = min(2.0, max(1.0, v))
    }

    func setInspectorSegment(_ s: String?) { inspectorSegment = s }

    func setConnection(_ c: ConnectionState) {
        guard connection != c else { return }
        connection = c
    }

    func setSheet(_ r: SheetRequest?) { sheet = r }

    /// Presents a section-declared sheet (refused while one is up, R17).
    public func presentSheet(_ r: SheetRequest) { presenter?.present(r) }

    public func dismissSheet() { presenter?.dismiss() }

    /// Destructive confirmation alert (§9.5), through the one presenter.
    func confirm(title: String, message: String, action: String, perform: @escaping () -> Void,
                 finished: (() -> Void)? = nil) {
        presenter?.confirm(title: title, message: message, action: action, perform: perform, finished: finished)
    }
}
