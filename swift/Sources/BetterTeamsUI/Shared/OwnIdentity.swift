// OwnIdentity.swift — the signed-in user as rows show them: initials
// from the owner's name (never the wire's "Me"), "You" by id.
import OstMacCore

extension WindowModel {
    /// Owner display name for avatars: demo = `DemoData.ownerDisplayName`;
    /// live = the active account's name, else the conversation's own name.
    var ownDisplayName: String {
        if options.demo { return DemoData.ownerDisplayName }
        if let n = app?.accounts.activeAccount?.displayName, !n.isEmpty { return n }
        return graph.conv.ownDisplayName ?? "You"
    }

    /// True when `id` (Graph user id or orgid MRI) is the signed-in user.
    func isOwnID(_ id: String?) -> Bool {
        guard let a = OwnIdentity.key(id), let b = OwnIdentity.key(app?.ownUserID) else { return false }
        return a == b
    }
}

enum OwnIdentity {
    /// Lowercased id with any `8:orgid:` prefix dropped; blank → nil
    /// (same rule as core's `RosterOwnership`).
    static func key(_ id: String?) -> String? {
        guard let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return (Mri.oid(from: raw) ?? raw).lowercased()
    }
}
