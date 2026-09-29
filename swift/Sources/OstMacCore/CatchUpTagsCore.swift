// CatchUpTagsCore.swift — §GRAPH2: the Teams tag read (CSA service) for
// Catch Up @tag mentions. Blocking FFI + network: call off the main thread.
import COstMac
import Foundation

extension RustCore {
    private struct CatchUpTagsPayload: Decodable { let tags: [String] }

    /// The signed-in user's Teams tag names, lowercased
    /// (`ostmac_catchup_tags`). Throws on any failure (no sign-in, HTTP
    /// error, unreadable answer); `[]` only when Teams answered "none".
    public static func catchUpTags() throws -> [String] {
        try call(ostmac_catchup_tags(), as: CatchUpTagsPayload.self).tags
    }
}
