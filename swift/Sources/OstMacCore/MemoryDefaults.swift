// MemoryDefaults.swift — core-b demo-leak sweep: a process-local,
// in-memory `UserDefaults` for `--demo`.
//
// Demo mode must never read or write the person's real preferences.
// Most stores already take `defaults: UserDefaults`; AppState hands every
// one of them the same `MemoryDefaults` instance in demo, so demo state
// behaves like real defaults for the run (stores sharing a key see each
// other's writes) and vanishes on quit. Nothing is ever written to disk:
// the backing suite is a unique throwaway name that no override lets a
// write reach, and every read/write accessor is overridden.
import Foundation

/// In-memory `UserDefaults`: reads and writes a dictionary, never the
/// preferences daemon. Thread-safe (stores read it from detached tasks).
public final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    /// Suite name marker (tests assert demo stores carry it).
    public static let suitePrefix = "bt.demo.memory."

    public init() {
        // A unique suite so any accessor Foundation adds later reads an
        // empty domain, never `.standard`. Writes never reach it.
        super.init(suiteName: Self.suitePrefix + UUID().uuidString)!
    }

    /// True for the in-memory demo defaults (test + audit helper).
    public static func isMemory(_ defaults: UserDefaults?) -> Bool {
        defaults == nil || defaults is MemoryDefaults
    }

    // MARK: - Core accessors

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName] ?? registered[defaultName]
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
        lock.unlock()
    }

    public override func removeObject(forKey defaultName: String) {
        lock.lock()
        values.removeValue(forKey: defaultName)
        lock.unlock()
    }

    public override func register(defaults registrationDictionary: [String: Any]) {
        lock.lock()
        registered.merge(registrationDictionary) { _, new in new }
        lock.unlock()
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return registered.merging(values) { _, new in new }
    }

    // MARK: - Typed setters (route through set(_:forKey:))

    public override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString as Any?, forKey: defaultName) }

    // MARK: - Typed getters (route through object(forKey:))

    public override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    public override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    public override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    public override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    public override func integer(forKey defaultName: String) -> Int {
        number(defaultName)?.intValue ?? 0
    }

    public override func float(forKey defaultName: String) -> Float {
        number(defaultName)?.floatValue ?? 0
    }

    public override func double(forKey defaultName: String) -> Double {
        number(defaultName)?.doubleValue ?? 0
    }

    public override func bool(forKey defaultName: String) -> Bool {
        if let s = object(forKey: defaultName) as? String {
            return ["yes", "true", "1"].contains(s.lowercased())
        }
        return number(defaultName)?.boolValue ?? false
    }

    public override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let u as URL: return u
        case let s as String: return URL(string: s)
        default: return nil
        }
    }

    private func number(_ key: String) -> NSNumber? {
        switch object(forKey: key) {
        case let n as NSNumber: return n
        case let s as String: return Double(s).map { NSNumber(value: $0) }
        default: return nil
        }
    }
}
