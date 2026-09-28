// DemoLeakTests.swift — core-b demo-leak sweep: `--demo` must never
// resolve a store to the person's real defaults, files or media cache.
import XCTest

@testable import OstMacCore

@MainActor
final class DemoLeakTests: XCTestCase {
    /// Walks every store AppState holds (reflection, so stores added later
    /// are covered too) and fails on any `UserDefaults` that is not the
    /// in-memory demo defaults, or any path/dir that points at the real
    /// ~/.config or Application Support. Negative control first: the
    /// scanner must flag a store built with its real defaults.
    func testDemoStoresNeverResolveToRealStorage() {
        let control = DemoLeakScanner()
        control.scan(SnoozeStore(), label: "control")
        XCTAssertFalse(control.leaks.isEmpty, "scanner blind: real SnoozeStore not flagged")

        defer { RichMediaCache.memoryOnly = false } // process-global
        let app = AppState(args: ["--demo"])
        XCTAssertTrue(app.storageDefaults is MemoryDefaults)
        XCTAssertTrue(RichMediaCache.memoryOnly)
        let scanner = DemoLeakScanner()
        scanner.scan(app, label: "AppState")
        scanner.scan(app.pinnedChannelStore(accountKey: "demo"), label: "pinnedChannels")
        XCTAssertGreaterThan(scanner.defaultsSeen, 15, "scanner reached too few stores")
        XCTAssertEqual(scanner.leaks, [], "demo stores resolve to real storage")
    }

    /// Demo defaults behave like defaults and never reach `.standard`.
    func testMemoryDefaultsRoundTripIsolated() {
        let key = "coreb.memdefaults.\(UUID().uuidString)"
        let d = MemoryDefaults()
        d.set(["a", "b"], forKey: key)
        XCTAssertEqual(d.stringArray(forKey: key), ["a", "b"])
        d.set(true, forKey: key + ".b")
        d.set(3, forKey: key + ".i")
        d.set(Data([1]), forKey: key + ".d")
        XCTAssertTrue(d.bool(forKey: key + ".b"))
        XCTAssertEqual(d.integer(forKey: key + ".i"), 3)
        XCTAssertEqual(d.data(forKey: key + ".d"), Data([1]))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        d.removeObject(forKey: key)
        XCTAssertNil(d.object(forKey: key))
        XCTAssertNil(MemoryDefaults().object(forKey: key + ".b"), "instances share state")
    }
}

/// Reflection walker for the leak test.
@MainActor
private final class DemoLeakScanner {
    private(set) var leaks: [String] = []
    private(set) var defaultsSeen = 0
    private var visited = Set<ObjectIdentifier>()

    func scan(_ value: Any, label: String, depth: Int = 0) {
        guard depth <= 7 else { return }
        if let d = value as? UserDefaults {
            defaultsSeen += 1
            if !(d is MemoryDefaults) { leaks.append("\(label): real UserDefaults") }
            return
        }
        if let url = value as? URL {
            check(path: url.path, label: label)
            return
        }
        if let s = value as? String {
            let l = label.lowercased()
            if l.hasSuffix(".path") || l.hasSuffix("dir") || l.hasSuffix("path") { check(path: s, label: label) }
            return
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection, .dictionary, .set:
            return
        case .class:
            let id = ObjectIdentifier(value as AnyObject)
            guard visited.insert(id).inserted else { return }
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

    private func check(path: String, label: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let real = ["\(home)/.config/", "\(home)/Library/Application Support/", "\(home)/Downloads/"]
        if real.contains(where: { path.hasPrefix($0) }) {
            leaks.append("\(label): \(path)")
        }
    }
}
