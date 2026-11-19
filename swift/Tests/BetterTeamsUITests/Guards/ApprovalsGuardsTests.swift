// ApprovalsGuardsTests.swift — approvals lane guards: the requests
// surface never renders blank/ambiguous states, and decisions lock
// the moment a request is decided.
//
// APPROVALS lane: new guard file (no existing guard weakened).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ApprovalsGuardsTests: XCTestCase {
    /// R12: requests on screen are never replaced by a spinner or
    /// error — any count above zero stays `.requests` under every
    /// store state and offline combination (no forced pane state: the
    /// forced `.loading`/`.empty`/`.error` states are the evidence
    /// routes and intentionally override the list).
    func testRequestsOnScreenNeverReplaced() {
        for state: ApprovalsState in [.loading, .loaded, .empty, .error("down")] {
            for offline in [false, true] {
                XCTAssertEqual(
                    ApprovalsListState.resolve(
                        state, requestCount: 2, forced: nil, offline: offline),
                    .requests, "state=\(state) offline=\(offline)")
            }
        }
    }

    /// Error titles state the condition (R18): the condition is never
    /// a bare status or an empty string.
    func testErrorTitlesStateTheCondition() {
        XCTAssertFalse(ApprovalsListState.errorTitle.isEmpty)
        XCTAssertFalse(ApprovalsDetailState.errorTitle.isEmpty)
        XCTAssertFalse(ApprovalsDetailState.noSelectionTitle.isEmpty)
        XCTAssertEqual(ApprovalsDetailState.noSelectionTitle, "No Request Selected")
    }

    /// Every workflow state has a distinct, non-empty badge label.
    func testStateLabelsCoverEveryState() {
        let states: [ApprovalState] = [.pending, .created, .completed, .canceled, .unknown]
        let labels = states.map { ApprovalsFormat.stateLabel($0).text }
        XCTAssertEqual(Set(labels).count, states.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    /// Detail shows only for the selected request; anything else is
    /// the no-selection pane, never a half-rendered request.
    func testDetailResolve() {
        XCTAssertEqual(
            ApprovalsDetailState.resolve(
                itemSelected: false, showing: false, loading: false, error: nil, offline: false),
            .noSelection)
        XCTAssertEqual(
            ApprovalsDetailState.resolve(
                itemSelected: true, showing: false, loading: true, error: nil, offline: false),
            .loading)
        XCTAssertEqual(
            ApprovalsDetailState.resolve(
                itemSelected: true, showing: true, loading: false, error: nil, offline: false),
            .detail)
    }

    /// `app/approvals/<id>` selects the request (round-trips the
    /// section's own selection helper).
    func testRouteSelectsRequest() {
        let section = ApprovalsSection()
        let route = Route(path: ["app", "approvals", "demo-appr-1"])
        XCTAssertEqual(section.selection(for: route), SectionSelection(id: "demo-appr-1"))
    }

    /// List rows name the owner beside the state (no bare-state rows).
    func testRowSubtitleNamesOwner() {
        let item = ApprovalItem(id: "x", displayName: "Travel request", state: .pending,
                                owner: ApprovalPerson(displayName: "You"))
        XCTAssertEqual(ApprovalsSection.subtitle(for: item), "Pending · You")
    }

    /// Approve/Reject validate enabled on a pending request, and lock
    /// the moment the request is decided (demo: cancel decides).
    func testDecisionCommandsLockWhenDecided() async {
        let support = GuardSupport.demoModel()
        let (app, model, _) = (support.app, support.model, support.nav)
        await app.approvals.load()
        XCTAssertEqual(app.approvals.items.count, 4)
        model.navigator?.select(section: .native(.approvals))
        ApprovalsSection.selectItem("demo-appr-1", model)
        let section = ApprovalsSection()
        XCTAssertTrue(section.validate(ApprovalsCommands.approve, arg: nil, model).enabled)
        XCTAssertTrue(section.validate(ApprovalsCommands.reject, arg: nil, model).enabled)
        app.approvals.cancel(id: "demo-appr-1")
        for _ in 0 ..< 50 {
            if app.approvals.items.first(where: { $0.id == "demo-appr-1" })?.isDecided == true { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(section.validate(ApprovalsCommands.approve, arg: nil, model).enabled)
        XCTAssertFalse(section.validate(ApprovalsCommands.reject, arg: nil, model).enabled)
    }
}
