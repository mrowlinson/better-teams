// LiveDemoGuardTests.swift — DEMOLEAK universal guard: a live launch's
// whole store graph must hold no demo fixture (type or data), even when
// an old demo run left fixtures in the real defaults. The inverse of
// DemoLeakTests (demo must never reach real storage).
import XCTest

@testable import OstMacCore

@MainActor
final class LiveDemoGuardTests: XCTestCase {
    func testDemoGateMintsOnlyForDemoLaunch() {
        XCTAssertNil(DemoGate.launch(args: []))
        XCTAssertNil(DemoGate.launch(args: ["--evidence", "--chat", "19:abc@thread.v2"]))
        XCTAssertNotNil(DemoGate.launch(args: ["--demo"]))
    }

    /// Builds the full live AppState (reflection walk, so stores added
    /// later are covered) and fails on any Demo* type or fixture id.
    /// Controls: the scanner must flag a demo-built store, and a demo
    /// feed planted in the live defaults must be gone after launch.
    func testLiveGraphReachesNoDemoFixtures() throws {
        let gate = try XCTUnwrap(DemoGate.launch(args: ["--demo"]))
        let control = LiveDemoScanner()
        control.scan(ActivityStore.demo(gate), label: "control")
        XCTAssertFalse(control.hits.isEmpty, "scanner blind: demo feed not flagged")

        let std = UserDefaults.standard
        let key = ActivityStore.defaultsKey
        let saved = std.object(forKey: key)
        defer { if let saved { std.set(saved, forKey: key) } else { std.removeObject(forKey: key) } }
        std.set(try JSONEncoder().encode(ActivityStore.demo(gate).items), forKey: key)

        let previous = MessageNotifications.systemBackend
        MessageNotifications.systemBackend = { FakeNotificationCenter() }
        defer { MessageNotifications.systemBackend = previous }
        let app = AppState(args: [])
        XCTAssertFalse(app.isDemo)
        XCTAssertNotNil(app.activity.feedReader, "live Activity reads the Teams feed")
        let scanner = LiveDemoScanner()
        scanner.scan(app, label: "AppState")
        XCTAssertGreaterThan(scanner.objectsSeen, 30, "scanner reached too few stores")
        XCTAssertEqual(scanner.hits, [], "demo fixtures reachable in live mode")
    }
}

/// Reflection walker: flags Demo* types and fixture-id strings. Values
/// other than fixture ids are never printed (the live graph may hold
/// real on-disk caches).
@MainActor
private final class LiveDemoScanner {
    private(set) var hits: [String] = []
    private(set) var objectsSeen = 0
    private var visited = Set<ObjectIdentifier>()
    private var budget = 400_000

    func scan(_ value: Any, label: String, depth: Int = 0) {
        guard depth <= 10, budget > 0, hits.count < 40 else { return }
        budget -= 1
        if let s = value as? String {
            if DemoFixture.isFixtureID(s) { hits.append("\(label) = \(s)") }
            return
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let wrapped = mirror.children.first { scan(wrapped.value, label: label, depth: depth) }
            return
        }
        let typeName = String(reflecting: type(of: value))
        if typeName.contains("Demo") {
            hits.append("\(label): \(typeName)")
            return
        }
        switch mirror.displayStyle {
        case .class:
            let id = ObjectIdentifier(value as AnyObject)
            guard visited.insert(id).inserted else { return }
            objectsSeen += 1
        case .collection, .set, .dictionary:
            for (i, child) in mirror.children.prefix(400).enumerated() {
                scan(child.value, label: "\(label)[\(i)]", depth: depth + 1)
            }
            return
        default:
            break
        }
        var m: Mirror? = mirror
        while let cur = m {
            for child in cur.children {
                scan(child.value, label: "\(label).\(child.label ?? "?")", depth: depth + 1)
            }
            m = cur.superclassMirror
        }
    }
}
