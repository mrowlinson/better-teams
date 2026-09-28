// TeamCreatePhase.swift — ui-purge: new-team create phase (split out of
// the deleted TeamCreateSheet view).

/// New-team sheet phase: form, in-flight poll, landed, or failed.
/// Pure value type so tests pin the transitions.
public enum TeamCreatePhase: Equatable, Sendable {
    case editing
    case creating
    case created(String)
    case failed(String)

    public var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    public var isCreating: Bool {
        if case .creating = self { return true }
        return false
    }

    /// Created team name, if any.
    public var createdName: String? {
        if case .created(let name) = self { return name }
        return nil
    }

    /// Failure message, if any.
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

