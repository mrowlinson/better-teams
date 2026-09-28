// Mri.swift — om-steal-ids lane: Teams MRI helpers.
//
// Port of the MRI half of weirdapps teams-access
// `src/commands/resolve-mri.ts` (MIT): `8:orgid:<aad-oid>` is the only
// form that resolves via Graph /users/{oid}. Everything else (skypeids,
// visitor, federated, thread ids) is recognized but not resolvable.
import Foundation

/// Pure Teams MRI helpers (no core, no network).
public enum Mri {
    /// AAD object id from an orgid MRI, or nil for any other form.
    /// Mirrors upstream `MRI_RE` (`/^8:orgid:([A-Za-z0-9-]+)$/`).
    public static func oid(from mri: String) -> String? {
        let prefix = "8:orgid:"
        guard mri.hasPrefix(prefix) else { return nil }
        let oid = String(mri.dropFirst(prefix.count))
        guard !oid.isEmpty,
              oid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return oid
    }

    /// True for any `8:`-prefixed sender id (orgid, skypeids, visitor…).
    /// The realtime feed's `sender_id` gate: display names never qualify.
    public static func isMri(_ s: String) -> Bool {
        s.hasPrefix("8:")
    }

    /// True only for the Graph-resolvable orgid form.
    public static func isResolvable(_ mri: String) -> Bool {
        oid(from: mri) != nil
    }
}
