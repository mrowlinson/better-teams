// DemoGate.swift — keeps demo fixtures out of live mode.
//
// Two halves:
// - `DemoGate` is a capability only a `--demo` launch can mint (its
//   init is fileprivate). Demo seeding entry points that write into a
//   store the live app also uses take one, so live code cannot call
//   them without first claiming a demo launch.
// - `DemoFixture.scrubLive` removes demo fixture ids that earlier demo
//   runs persisted into the real defaults domain (before demo moved to
//   in-memory defaults). A live launch runs it once before any store
//   loads, so no section can restore a stale demo row, selection or pin.
//
// Threading: pure values; `scrubLive` touches only the defaults passed.
import Foundation

/// Proof that this process launched in demo mode.
public struct DemoGate: Sendable, Equatable {
    fileprivate init() {}

    /// The gate for a launch: non-nil only when `args` carry `--demo`.
    public static func launch(args: [String]) -> DemoGate? {
        args.contains("--demo") ? DemoGate() : nil
    }
}

public enum DemoFixture {
    /// Demo chat/channel name for display fallbacks; always nil in live
    /// mode (a live id never resolves through fixtures).
    public static func name(for id: String, demo: Bool) -> String? {
        demo ? DemoData.name(for: id) : nil
    }

    /// Demo chat group flag for display fallbacks; nil in live mode.
    public static func isGroup(_ id: String, demo: Bool) -> Bool? {
        demo ? DemoData.chats.first { $0.id == id }?.is_group : nil
    }

    /// True for a demo fixture id: a whole id (no whitespace) with a
    /// `:`/`/`-separated component that starts with `demo-`
    /// (`demo-2`, `mention:demo-showcase:sc-1`, `missedCall:-:demo-missed`).
    /// Real Teams ids (`19:…`, `48:…`, `8:orgid:…`, GUIDs) never match.
    public static func isFixtureID(_ s: String) -> Bool {
        guard s.count <= 256, s.contains("demo-"),
              !s.contains(where: { $0.isWhitespace })
        else { return false }
        return s.split(whereSeparator: { $0 == ":" || $0 == "/" }).contains { part in
            part.hasPrefix("demo-") && part.count > 5
        }
    }

    /// True when any string (or dictionary key) inside `value` is a
    /// fixture id.
    public static func containsFixture(_ value: Any) -> Bool {
        switch value {
        case let s as String:
            return isFixtureID(s)
        case let a as [Any]:
            return a.contains { containsFixture($0) }
        case let d as [String: Any]:
            return d.contains { isFixtureID($0.key) || containsFixture($0.value) }
        default:
            return false
        }
    }

    /// Scrub demo fixtures from live defaults. Keys named for demo or
    /// evidence runs are left alone (live never reads them). Returns the
    /// keys it rewrote or removed.
    @discardableResult
    public static func scrubLive(_ defaults: UserDefaults) -> [String] {
        var touched: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            let lower = key.lowercased()
            if lower.contains("demo") || lower.hasPrefix("evidence.") || key.hasPrefix("NS")
                || key.hasPrefix("Apple") || key.hasPrefix("com.apple.")
            { continue }
            switch scrubbed(stored: value) {
            case .unchanged:
                continue
            case .remove:
                defaults.removeObject(forKey: key)
            case .replace(let v):
                defaults.set(v, forKey: key)
            }
            touched.append(key)
        }
        return touched.sorted()
    }

    enum Outcome {
        case unchanged
        case remove
        case replace(Any)
    }

    /// One stored defaults value: JSON `Data`/`String` payloads are
    /// decoded, scrubbed and re-encoded; plist arrays/dictionaries are
    /// scrubbed in place; a bare fixture-id string is removed.
    static func scrubbed(stored value: Any) -> Outcome {
        switch value {
        case let data as Data:
            // Cheap byte probe first: launch-time cost stays a scan.
            guard data.range(of: Data("demo-".utf8)) != nil,
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  containsFixture(json)
            else { return .unchanged }
            let clean = scrub(json)
            guard let clean, let out = try? JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed])
            else { return .remove }
            return .replace(out)
        case let s as String:
            if isFixtureID(s) { return .remove }
            guard s.contains("demo-"), s.first == "{" || s.first == "[", let data = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data), containsFixture(json)
            else { return .unchanged }
            guard let clean = scrub(json), let out = try? JSONSerialization.data(withJSONObject: clean),
                  let text = String(data: out, encoding: .utf8)
            else { return .remove }
            return .replace(text)
        case is [Any], is [String: Any]:
            guard containsFixture(value) else { return .unchanged }
            guard let clean = scrub(value) else { return .remove }
            return .replace(clean)
        default:
            return .unchanged
        }
    }

    /// Scrub one decoded value; nil = the value itself is a fixture.
    /// Arrays drop every element that carries a fixture (a demo row or
    /// id); dictionaries drop fixture keys and fixture-id values and
    /// recurse into nested containers.
    static func scrub(_ value: Any) -> Any? {
        switch value {
        case let s as String:
            return isFixtureID(s) ? nil : s
        case let a as [Any]:
            return a.filter { !containsFixture($0) }
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d where !isFixtureID(k) {
                if let clean = scrub(v) { out[k] = clean }
            }
            return out
        default:
            return value
        }
    }
}
