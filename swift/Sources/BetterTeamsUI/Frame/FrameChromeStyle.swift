// FrameChromeStyle.swift — chrome hiding for Teams-hosted web apps
// (UI-SPEC §7.3): (1) a document-start stylesheet hides the Teams app bar
// and header, selectors versioned here (the same set the
// `TeamsFrameMeasure` probe looks for); (3) the geometric fallback: a
// per-app crop that outsets the web view inside its clipping container.
// Settings ▸ Apps turns hiding on or off and edits the crops.
import AppKit
import OstMacCore
import WebKit

enum FrameChromeStyle {
    /// Bump when the selector set changes.
    static let version = 1

    /// Settings ▸ Apps ▸ Hide the Teams header and app bar (on by default).
    static let hideKey = "bt.frame.hideChrome"
    /// Per-app crops, JSON `[FrameKey.raw: TeamsFrameCrop]`.
    static let cropsKey = "bt.frame.crops"

    /// Teams-web chrome: the left app bar and the top header.
    static let selectors = [
        "[data-tid=\"app-bar\"]", "#app-bar", "[aria-label=\"App bar\"]", "[data-tid=\"app-header\"]",
    ]

    static let styleID = "bt-chrome-style-v\(version)"

    static var css: String { selectors.joined(separator: ", ") + " { display: none !important; }" }

    /// Adds the stylesheet once (document start: `head` may not exist yet).
    static var injectJS: String {
        let literal = (try? JSONSerialization.data(withJSONObject: css, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function(){var id='\(styleID)';if(document.getElementById(id))return;\
        var s=document.createElement('style');s.id=id;s.textContent=\(literal);\
        (document.head||document.documentElement).appendChild(s);})();
        """
    }

    /// Removes the stylesheet (hiding turned off while the app is loaded).
    static var removeJS: String {
        "(function(){var s=document.getElementById('\(styleID)');if(s)s.remove();})();"
    }

    static func userScript() -> WKUserScript {
        WKUserScript(source: injectJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Chrome hiding applies to Teams-hosted pages only (§7.3), never to
    /// standalone hosts, which load without Teams chrome.
    static func applies(to url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return FramePolicy.hostMatches(h, ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"])
    }

    /// The web view's frame inside its clipping container: outset left
    /// and up by the crop, so those edges fall outside the container.
    static func frame(in bounds: NSRect, crop: TeamsFrameCrop, flipped: Bool) -> NSRect {
        NSRect(x: bounds.minX - crop.left,
               y: flipped ? bounds.minY - crop.top : bounds.minY,
               width: bounds.width + crop.left,
               height: bounds.height + crop.top)
    }

    static func hideChrome(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: hideKey) == nil ? true : defaults.bool(forKey: hideKey)
    }

    static func loadCrops(defaults: UserDefaults) -> [String: TeamsFrameCrop] {
        guard let data = defaults.data(forKey: cropsKey),
              let crops = try? JSONDecoder().decode([String: TeamsFrameCrop].self, from: data)
        else { return [:] }
        return crops
    }

    static func saveCrops(_ crops: [String: TeamsFrameCrop], defaults: UserDefaults) {
        if crops.isEmpty {
            defaults.removeObject(forKey: cropsKey)
        } else if let data = try? JSONEncoder().encode(crops) {
            defaults.set(data, forKey: cropsKey)
        }
    }
}
