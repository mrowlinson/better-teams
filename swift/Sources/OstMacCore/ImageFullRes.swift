// ImageFullRes.swift — om-imgfull: viewer loads full-res, not thumbnail.
//
// The bubble keeps its thumbnail URL (list scrolling + preload untouched).
// On open, the viewer derives the full-resolution URL and fetches it
// through RichMediaCache (its own URL+message key, so thumb and full
// cache independently). While loading, the thumbnail stays on screen
// behind a progress pill; on failure the thumbnail stays up with an
// error row + Retry (the viewer is still useful offline).

/// Pure full-res URL derivation (testable without actors or views).
public enum ImageFullRes {
    /// Full view for AMS object URLs (`…/views/<thumb>` → `…/views/imgo`).
    public static let fullView = "imgo"
    /// Already-full views (never rewritten).
    public static let fullViews = ["imgo", "imgpsh_fullsize", "imgpsh_fullsize_anim"]

    /// Thumbnail URL → full-resolution URL.
    /// - AMS object views: the `/views/<name>` segment becomes `imgo`
    ///   (query/fragment preserved); already-full views untouched.
    /// - `demo://` fixtures: `demo://photo-N` → `demo://photo-N-full`
    ///   (2× render); already-full untouched.
    /// - Graph / SharePoint drive-item thumbnails
    ///   (`…/items/<id>/thumbnails/<set>/<size>/content`): the item's
    ///   full download `…/items/<id>/content`.
    /// - Graph hosted contents (`…/hostedContents/<id>/$value`) and
    ///   everything else (public URLs, emoticons): unchanged — the
    ///   single URL already is the full image.
    public static func fullResURL(for url: String) -> String {
        if url.hasPrefix("demo://") {
            return url.hasSuffix("-full") ? url : url + "-full"
        }
        if let full = driveItemContentURL(for: url) { return full }
        guard let views = url.range(of: "/views/", options: .caseInsensitive) else {
            return url
        }
        let nameStart = views.upperBound
        var nameEnd = url.endIndex
        for i in url[nameStart...].indices {
            let c = url[i]
            if c == "/" || c == "?" || c == "#" {
                nameEnd = i
                break
            }
        }
        let name = String(url[nameStart ..< nameEnd])
        if fullViews.contains(name.lowercased()) { return url }
        return String(url[..<nameStart]) + fullView + String(url[nameEnd...])
    }

    /// Drive-item thumbnail → the item's own `/content` download (query
    /// dropped: thumbnail size params mean nothing to `/content`).
    /// Nil when the URL is not a `/thumbnails/<set>/<size>/content` URL.
    static func driveItemContentURL(for url: String) -> String? {
        let path = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let r = path.range(of: "/thumbnails/", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = path[r.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard tail.count == 3, !tail[0].isEmpty, !tail[1].isEmpty,
              tail[2].lowercased() == "content"
        else { return nil }
        return String(path[..<r.lowerBound]) + "/content"
    }
}
