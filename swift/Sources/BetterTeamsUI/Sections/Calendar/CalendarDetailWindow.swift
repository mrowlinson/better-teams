// CalendarDetailWindow.swift — CALDETAIL: the details popup popped out
// into its own window (one per event; reopening brings it forward),
// Print (the event as a text page through the system print panel) and
// Download (.ics through a save panel, default ~/Downloads).
import AppKit
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class EventDetailsWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: EventDetailsWindowController] = [:]
    private var titleWatch: AnyCancellable?
    let eventID: String

    static func show(eventID: String, _ m: WindowModel, activate: Bool = true) {
        guard let app = m.app else { return }
        app.calWeek.loadDetail(id: eventID)
        if let c = open[eventID] {
            c.showWindow(nil)
            if activate { c.window?.makeKeyAndOrderFront(nil) } else { c.window?.orderFront(nil) }
            return
        }
        let c = EventDetailsWindowController(eventID: eventID, week: app.calWeek, model: m)
        open[eventID] = c
        c.window?.center()
        if activate {
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
        } else {
            c.window?.orderFront(nil)
        }
    }

    private init(eventID: String, week: CalendarWeekStore, model m: WindowModel) {
        self.eventID = eventID
        var closeWindow: () -> Void = {}
        let root = EventDetailsView(week: week, eventID: eventID, host: .window, closeWindow: { closeWindow() })
        // The details' commands are SwiftUI `.toolbar` items: the window's NSToolbar.
        let host = Hosting.controller(root, role: .pane, model: m, bridging: [.toolbars])
        let window = NSWindow(contentViewController: host)
        window.toolbarStyle = .unified
        window.title = week.row(id: eventID)?.subject ?? "Event"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 940, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        // The title is the event's subject (Mail's message windows), set once the row is known.
        titleWatch = week.objectWillChange.receive(on: RunLoop.main).sink { [weak window, weak week] in
            guard let window, let subject = week?.row(id: eventID)?.subject, window.title != subject else { return }
            window.title = subject
        }
        closeWindow = { [weak window] in window?.performClose(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        if Self.open[eventID] === self { Self.open[eventID] = nil }
    }
}

/// Print: the event as a text page (title, when, where, people by
/// response, Teams dial-in, description) through the print panel.
@MainActor
enum CalendarPrinting {
    static func print(_ m: MeetingItem, detail: CalendarEventDetail?) {
        let text = CalendarExport.printText(m, detail: detail, when: CalendarFormat.when(m))
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let size = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                          height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let view = NSTextView(frame: NSRect(origin: .zero, size: size))
        view.textStorage?.setAttributedString(attributed(text))
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = m.subject
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    /// Title bold 16 pt, the rest 11 pt.
    static func attributed(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
        ])
        let first = (text as NSString).range(of: "\n")
        let titleRange = NSRange(location: 0, length: first.location == NSNotFound ? out.length : first.location)
        out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: titleRange)
        return out
    }
}

/// Download (.ics): save panel (default ~/Downloads, "<title>.ics").
@MainActor
enum CalendarICSSave {
    static func save(_ m: MeetingItem, detail: CalendarEventDetail?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CalendarExport.icsFileName(m)
        panel.allowedContentTypes = [.init(filenameExtension: "ics") ?? .data]
        panel.directoryURL = UserFolders.downloads()
        panel.canCreateDirectories = true
        let text = CalendarExport.ics(m, detail: detail)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? write(text, to: url)
        }
    }

    /// Write the calendar file (tests: a temp dir).
    nonisolated static func write(_ ics: String, to url: URL) throws {
        try Data(ics.utf8).write(to: url, options: .atomic)
    }
}
