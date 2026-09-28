// AvHeal.swift — P4 split: verbatim move from AvPanelView.swift.

/// Stale-pick heal decision after a rescan (unit-tested).
public enum AvHeal {
    public enum Action: Equatable, Sendable {
        case valid // pick present in the fresh list (transient error)
        case wedge // fresh list empty (HAL wedge) — keep the pick
        case unplugged // fresh list non-empty, pick missing — heal to default
    }

    public static func action(pick: String?, devices: [String]) -> Action {
        guard let pick, !pick.isEmpty else { return .valid }
        if devices.contains(pick) { return .valid }
        return devices.isEmpty ? .wedge : .unplugged
    }
}
