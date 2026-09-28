// CalSyncMocks.swift — mock transport + sinks for the CalSync lane.
// ONLY conformances of CalGraphTransport / EKSink / GraphSink in this
// lane. Zero network, zero EventKit. Scriptable pages + call recording
// so tests pin guard behavior (esp. "dry-run calls nothing").
import Foundation

/// Scripted delta pages keyed by incoming `since` token (nil = first page).
/// Records every fetch (token + window) for assertions.
public final class MockGraphTransport: CalGraphTransport, @unchecked Sendable {
    public var pages: [String?: CalDeltaPage]
    public private(set) var fetches: [(since: String?, radiusDays: Int)] = []
    public var error: Error?

    public init(
        pages: [String?: CalDeltaPage] = [:], error: Error? = nil
    ) {
        self.pages = pages
        self.error = error
    }

    public convenience init(firstPage: CalDeltaPage) {
        self.init(pages: [nil: firstPage])
    }

    public func fetchDelta(
        since deltaLink: String?, window: CalSyncWindow
    ) throws -> CalDeltaPage {
        fetches.append((since: deltaLink, radiusDays: window.radiusDays))
        if let error { throw error }
        return pages[deltaLink] ?? CalDeltaPage(events: [], deltaLink: "end")
    }
}

/// Recording EventKit-side sink. Counts calls; stores ops.
public final class MockEKSink: EKSink, @unchecked Sendable {
    public private(set) var calls: [[EKWriteOp]] = []
    public var error: Error?

    public init(error: Error? = nil) { self.error = error }

    @discardableResult
    public func apply(_ ops: [EKWriteOp]) throws -> Int {
        if let error { throw error }
        calls.append(ops)
        return ops.count
    }

    public var totalOps: Int { calls.flatMap(\.self).count }
}

/// Recording Graph-side sink. Counts calls; stores ops.
public final class MockGraphSink: GraphSink, @unchecked Sendable {
    public private(set) var calls: [[GraphWriteOp]] = []
    public var error: Error?

    public init(error: Error? = nil) { self.error = error }

    @discardableResult
    public func apply(_ ops: [GraphWriteOp]) throws -> Int {
        if let error { throw error }
        calls.append(ops)
        return ops.count
    }

    public var totalOps: Int { calls.flatMap(\.self).count }
}
