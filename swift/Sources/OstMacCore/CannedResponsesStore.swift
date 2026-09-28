// CannedResponsesStore.swift — e2-canned: template persistence.
//
// UserDefaults (suite-injectable for tests), one key, persist-on-mutate
// — the SnoozeStore precedent. Client-side only (local-only v1, no
// roaming, no Rust/FFI).
import Combine
import Foundation

/// User-authored message templates. Owns the ordered template list;
/// the composer picker reads it, Settings edits it.
@MainActor
public final class CannedResponsesStore: ObservableObject {
    public nonisolated static let storageKey = "canned.templates"

    @Published public private(set) var templates: [CannedTemplate] = []

    private let defaults: UserDefaults

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [CannedTemplate] = []
        if let data = defaults.data(forKey: Self.storageKey) {
            // Tolerant: garbage decodes to an empty list, never traps.
            loaded = (try? JSONDecoder().decode([CannedTemplate].self, from: data)) ?? []
        }
        _templates = Published(initialValue: loaded)
    }

    /// Append a template. Returns the inline refusal reason on blank
    /// fields (nothing stored); nil on success.
    @discardableResult
    public func add(title: String, body: String) -> String? {
        if let reason = CannedResponses.validate(title: title, body: body) {
            return reason
        }
        templates.append(CannedTemplate(title: title, body: body))
        persist()
        return nil
    }

    /// Replace one template's title + body. Unknown ids and blank
    /// fields return the inline refusal reason (nothing stored).
    @discardableResult
    public func update(id: UUID, title: String, body: String) -> String? {
        guard let i = templates.firstIndex(where: { $0.id == id }) else {
            return "That template is gone."
        }
        if let reason = CannedResponses.validate(title: title, body: body) {
            return reason
        }
        templates[i].title = title
        templates[i].body = body
        persist()
        return nil
    }

    /// Delete one template. Unknown ids are a no-op.
    public func delete(id: UUID) {
        guard templates.contains(where: { $0.id == id }) else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Move one template (Settings reorder). Out-of-range indexes are
    /// a no-op.
    public func move(from source: Int, to destination: Int) {
        guard templates.indices.contains(source),
              templates.indices.contains(destination),
              source != destination
        else { return }
        let item = templates.remove(at: source)
        templates.insert(item, at: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
