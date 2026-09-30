// TeamsLinkNative.swift — the app's native side of `TeamsLinkRouter`
// (LINKGUARD): Teams / Microsoft 365 links open on the matching native
// screen; one with no screen gets an error alert (Copy Link), never the
// browser and never the Teams web app.
import AppKit
import CryptoKit
import Foundation
import OstMacCore

@MainActor
public enum TeamsLinkUI {
    private static var installed = false

    /// Installs the native handler and the error alert. Idempotent.
    public static func install() {
        guard !installed else { return }
        installed = true
        TeamsLinkRouter.nativeHandler = { url, window in
            guard let m = model(for: window) else { return false }
            return route(url, m)
        }
        TeamsLinkRouter.refusalHandler = { url, _ in present(refusal: url) }
    }

    static func model(for window: AnyObject?) -> WindowModel? {
        (window as? WindowModel) ?? ShellWindowController.current?.model
    }

    /// True when the link opened on a native screen of `m`.
    static func route(_ url: URL, _ m: WindowModel) -> Bool {
        switch TeamsLinkRouter.family(url) {
        case .teams: return DeepLinkRouter.route(url, m)
        case .files: return TeamsLinkFiles.open(url, m)
        case .outlook:
            guard let id = TeamsLinkRouter.outlookEventID(url), let week = m.app?.calWeek else { return false }
            if week.row(id: id) != nil || m.app?.meetings.meetings.contains(where: { $0.id == id }) == true {
                m.navigator?.apply(Route(path: ["calendar", id]))
                return true
            }
            guard week.canResolveEventsByID else { return false }
            // Not in a loaded range: read the event by id (GET only) and
            // open it on its calendar screen; no such event = the error alert.
            Task { @MainActor [weak m] in
                if await week.resolveEvent(id: id) {
                    m?.navigator?.apply(Route(path: ["calendar", id]))
                } else {
                    TeamsLinkRouter.refusalHandler?(url, m)
                }
            }
            return true
        case .other: return false
        }
    }

    // MARK: error alert

    /// The alert for a Microsoft link with no native screen.
    public static func refusalAlert(for url: URL) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Can\u{2019}t Open This Link in Better Teams"
        a.informativeText = "Better Teams has no screen for this \(kindName(url)) link. It won\u{2019}t open the Teams web app or your browser."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy Link")
        return a
    }

    static func kindName(_ url: URL) -> String {
        switch TeamsLinkRouter.family(url) {
        case .teams: "Teams"
        case .outlook: "calendar"
        case .files: "file"
        case .other: "Microsoft"
        }
    }

    /// Copy Link puts the address on the pasteboard.
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func present(refusal url: URL) {
        // Never a modal in a test process.
        guard !UserFolders.isTestProcess else { return }
        let alert = refusalAlert(for: url)
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertSecondButtonReturn { copy(url) }
        }
        if let w = ShellWindowController.current?.window {
            alert.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

/// SharePoint / OneDrive / Office links: the document opens in a pane of
/// the app (the standalone web-page frame), never the browser.
@MainActor
enum TeamsLinkFiles {
    static func appID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "link-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func open(_ url: URL, _ m: WindowModel) -> Bool {
        guard url.scheme?.lowercased() == "https", TeamsLinkRouter.family(url) == .files else { return false }
        let name = url.lastPathComponent.removingPercentEncoding.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
            ?? url.host ?? "Document"
        let app = FrameApp(id: appID(for: url), label: name, symbol: "doc.text", source: .webLink, launch: .direct(url))
        FrameAppDirectory.register([app])
        m.frameHost.registerApp(app)
        m.navigator?.select(section: .web(app.id))
        return true
    }
}
