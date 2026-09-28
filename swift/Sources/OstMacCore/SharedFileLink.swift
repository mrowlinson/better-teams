// SharedFileLink.swift — om-i1-links lane: copy-link helpers for Shared
// rows. Fetch + pasteboard write live in SharedFilesStore.shareLink
// (injected link/copy seams). ui-purge: the copy-link button view was
// deleted with the old UI.
import Foundation

/// Copy-link helpers. No view or FFI code.
public enum SharedFileLink {
    /// Stable fabricated link for demo rows (offline, no core).
    public static func demoLink(for fileID: String) -> String {
        "https://demo.sharepoint.local/:i:/r/\(fileID)?sharing=org"
    }
}

