// ApprovalStoreTests.swift — approvals lane: item/response decode,
// flow status, demo seed, approve/reject/cancel, consent failure.
import XCTest

@testable import OstMacCore

@MainActor
final class ApprovalStoreTests: XCTestCase {
    // MARK: - fixtures (Graph beta shapes)

    nonisolated static func itemJSON() -> String {
        """
        {"id":"a1","displayName":"Travel request",
        "description":"Two nights in Chicago.",
        "approvalType":"basic","state":"pending","allowCancel":true,
        "createdDateTime":"2026-11-10T14:00:00Z",
        "owner":{"user":{"id":"u-you","displayName":"You"}},
        "approvers":[{"user":{"id":"u-oliver","displayName":"Oliver Grant"}},
        {"user":{"id":"u-ava","displayName":"Ava Lindqvist"}}],
        "responsePrompts":["Approve","Reject"]}
        """
    }

    nonisolated static func responsesJSON() -> String {
        """
        {"value":[
        {"id":"r1","response":"Approve","comments":"Looks good.",
        "createdDateTime":"2026-11-10T15:20:00Z",
        "responder":{"user":{"id":"u-oliver","displayName":"Oliver Grant"}}}]}
        """
    }

    static func model(
        list: String? = nil, responses: String? = nil, localEdits: Bool = false
    ) -> ApprovalStore {
        ApprovalStore(
            listFetcher: { Data((list ?? "{\"value\":[" + itemJSON() + "]}").utf8) },
            responsesFetcher: { _ in Data((responses ?? "{\"value\":[]}").utf8) },
            respondSender: { _, _, _ in Data() },
            cancelSender: { _ in Data() },
            localEdits: localEdits)
    }

    // MARK: - decode

    func testDecodeItem() throws {
        let item = try ApprovalGraph.decoder().decode(
            ApprovalItem.self, from: Data(Self.itemJSON().utf8))
        XCTAssertEqual(item.id, "a1")
        XCTAssertEqual(item.displayName, "Travel request")
        XCTAssertEqual(item.workflowType, .basic)
        XCTAssertEqual(item.state, .pending)
        XCTAssertTrue(item.allowCancel)
        XCTAssertTrue(item.canCancel)
        XCTAssertFalse(item.isDecided)
        XCTAssertEqual(item.owner?.displayName, "You")
        XCTAssertEqual(item.approvers.map(\.displayName), ["Oliver Grant", "Ava Lindqvist"])
        XCTAssertEqual(item.responsePrompts, ["Approve", "Reject"])
        XCTAssertNotNil(item.createdDateTime)
    }

    func testDecodeUnknownStateIsForwardCompatible() throws {
        let raw = Self.itemJSON().replacingOccurrences(of: "\"pending\"", with: "\"someday\"")
        let item = try ApprovalGraph.decoder().decode(
            ApprovalItem.self, from: Data(raw.utf8))
        XCTAssertEqual(item.state, .unknown)
        XCTAssertFalse(item.isDecided)
    }

    func testDecodeResponses() throws {
        let box = try ApprovalGraph.decoder().decode(
            ApprovalStore.ResponsesBox.self, from: Data(Self.responsesJSON().utf8))
        XCTAssertEqual(box.value.count, 1)
        XCTAssertEqual(box.value[0].response, "Approve")
        XCTAssertEqual(box.value[0].responder?.displayName, "Oliver Grant")
        XCTAssertTrue(box.value[0].isApproval())
    }

    func testRejectIsNotApproval() {
        let r = ApprovalItemResponse(response: "Reject")
        XCTAssertFalse(r.isApproval())
        XCTAssertTrue(ApprovalItemResponse(response: "approve").isApproval())
    }

    // MARK: - flow status

    func testFlowStatusWaitingOnOneOfTwo() throws {
        let item = try ApprovalGraph.decoder().decode(
            ApprovalItem.self, from: Data(Self.itemJSON().utf8))
        let responses = try ApprovalGraph.decoder().decode(
            ApprovalStore.ResponsesBox.self, from: Data(Self.responsesJSON().utf8)).value
        let status = ApprovalFlowStatus.compute(item: item, responses: responses)
        XCTAssertEqual(status.headline, "Waiting on 1 of 2")
        XCTAssertEqual(status.rows.count, 2)
        XCTAssertEqual(status.rows[0].response, "Approve")
        XCTAssertTrue(status.rows[0].isPositive)
        XCTAssertNil(status.rows[1].response)
        XCTAssertEqual(status.waitingOn.map(\.displayName), ["Ava Lindqvist"])
    }

    func testFlowStatusCompletedAndCanceled() throws {
        var item = try ApprovalGraph.decoder().decode(
            ApprovalItem.self, from: Data(Self.itemJSON().utf8))
        item.state = .completed
        item.result = "Approved"
        XCTAssertEqual(ApprovalFlowStatus.compute(item: item, responses: []).headline, "Approved")
        item.state = .canceled
        XCTAssertEqual(ApprovalFlowStatus.compute(item: item, responses: []).headline, "Canceled")
    }

    func testFlowStatusEmptyApprovers() throws {
        var item = try ApprovalGraph.decoder().decode(
            ApprovalItem.self, from: Data(Self.itemJSON().utf8))
        item.approvers = []
        let status = ApprovalFlowStatus.compute(item: item, responses: [])
        XCTAssertEqual(status.headline, "No approvers assigned")
        XCTAssertTrue(status.waitingOn.isEmpty)
    }

    // MARK: - store

    func testLoadSeedsSelection() async {
        let store = Self.model()
        await store.load()
        if case .loaded = store.state {} else { return XCTFail("state \(store.state)") }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.selectedID, "a1")
        XCTAssertEqual(store.selected?.displayName, "Travel request")
    }

    func testLoadEmpty() async {
        let store = Self.model(list: "{\"value\":[]}")
        await store.load()
        if case .empty = store.state {} else { return XCTFail("state \(store.state)") }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLoadErrorSurfacesConsentMessage() async {
        let store = ApprovalStore(
            listFetcher: { throw CoreCallError.failed("approvals: the sign-in lacks ApprovalSolution.ReadWrite") })
        await store.load()
        if case .error(let m) = store.state {
            XCTAssertTrue(m.contains("ApprovalSolution.ReadWrite"), m)
        } else {
            XCTFail("state \(store.state)")
        }
    }

    func testDemoSeedHasFourRequests() async throws {
        let store = ApprovalStore.demo()
        await store.load()
        XCTAssertEqual(store.items.count, 4)
        XCTAssertEqual(store.selected?.id, "demo-appr-1")
        // Responses load behind the list; wait for the fixture to land.
        for _ in 0 ..< 50 {
            if store.responsesByItem["demo-appr-1"] != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = store.flowStatus(for: "demo-appr-1")
        XCTAssertEqual(status?.headline, "Waiting on 1 of 2")
        let done = store.flowStatus(for: "demo-appr-3")
        XCTAssertEqual(done?.headline, "Approved")
    }

    func testApproveCompletesBasic() async throws {
        let store = Self.model(localEdits: true)
        await store.load()
        store.respond(id: "a1", response: "Approve", comments: "OK")
        // The send runs on a Task; poll briefly for the applied decision.
        for _ in 0 ..< 50 {
            if store.selected?.isDecided == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selected?.state, .completed)
        XCTAssertEqual(store.selected?.result, "Approved")
        XCTAssertEqual(store.flowStatus(for: "a1")?.headline, "Approved")
    }

    func testCancelMarksCanceled() async throws {
        let store = Self.model(localEdits: true)
        await store.load()
        XCTAssertTrue(store.selected?.canCancel == true)
        store.cancel(id: "a1")
        for _ in 0 ..< 50 {
            if store.selected?.state == .canceled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selected?.state, .canceled)
        XCTAssertFalse(store.selected?.canCancel == true)
    }

    func testDecidedItemLocksActions() async {
        let store = Self.model(localEdits: true)
        await store.load()
        store.cancel(id: "a1")
        for _ in 0 ..< 50 {
            if store.items.first?.isDecided == true { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Approve-after-cancel is a no-op (guarded in the store).
        store.respond(id: "a1", response: "Approve")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.items.first?.state, .canceled)
        XCTAssertNil(store.items.first?.result)
    }
}
