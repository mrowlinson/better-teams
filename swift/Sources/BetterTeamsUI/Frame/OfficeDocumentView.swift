// OfficeDocumentView.swift — Office documents open in the window,
// read-only (APPNATIVE6, R9): a Word, Excel or PowerPoint file stored in
// SharePoint or OneDrive opens on its own web page in a pane, in view
// mode, instead of downloading into a desktop app. Pure; unit-tested.
import Foundation

public enum OfficeDocumentView {
    /// Extensions Office for the web views.
    static let officeExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "rtf", "odt",
        "xls", "xlsx", "xlsm", "xlsb", "ods",
        "ppt", "pptx", "pptm", "pps", "ppsx", "odp",
    ]

    /// A file name Office for the web can show.
    public static func isOfficeDocument(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return officeExtensions.contains(ext)
    }

    /// Rail / title symbol for a document's kind.
    public static func symbol(name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "xls", "xlsx", "xlsm", "xlsb", "ods": "tablecells"
        case "ppt", "pptx", "pptm", "pps", "ppsx", "odp": "rectangle.on.rectangle"
        default: "doc.text"
        }
    }

    /// SharePoint's document page (`/_layouts/15/Doc.aspx`, `Doc2.aspx`).
    static func isDocPage(_ url: URL) -> Bool {
        let last = url.lastPathComponent.lowercased()
        return (last == "doc.aspx" || last == "doc2.aspx") && url.path.lowercased().contains("/_layouts/")
    }

    /// The read-only address of a document's web page: the document page
    /// with `action=view`, or a stored file's address with `web=1` (which
    /// SharePoint answers with the document page, rewritten again here).
    /// Nil: not a SharePoint document address (left alone).
    public static func viewURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host,
              SharePointSession.isSharePointHost(host),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = c.queryItems ?? []
        if isDocPage(url) {
            let actions = items.filter { $0.name.caseInsensitiveCompare("action") == .orderedSame }
            if actions.count == 1, actions[0].value?.lowercased() == "view" { return url }
            items.removeAll { $0.name.caseInsensitiveCompare("action") == .orderedSame }
            items.append(URLQueryItem(name: "action", value: "view"))
        } else if isOfficeDocument(name: url.lastPathComponent) {
            guard !items.contains(where: { $0.name.caseInsensitiveCompare("web") == .orderedSame }) else { return url }
            items.append(URLQueryItem(name: "web", value: "1"))
        } else {
            return nil
        }
        c.queryItems = items
        return c.url
    }
}
