// SheetPresenter.swift — the one sheet presenter (UI-SPEC §9.5, R17).
//
// Requests are `SheetRequest` values declared in each section's folder.
// A request while a sheet is up is refused and logged, never stacked.
import AppKit
import SwiftUI

public struct SheetRequest: Hashable, Sendable {
    public var name: String
    public var section: SectionID
    public var arg: String?

    public init(_ name: String, in section: SectionID, arg: String? = nil) {
        self.name = name
        self.section = section
        self.arg = arg
    }
}

@MainActor
final class SheetPresenter {
    /// The window's current content controller (shell or sign-in).
    private let host: () -> NSViewController?
    private let model: WindowModel
    private var presented: NSViewController?
    private weak var presenter: NSViewController?

    init(model: WindowModel, host: @escaping () -> NSViewController?) {
        self.host = host
        self.model = model
    }

    var isPresenting: Bool { presented != nil }

    /// Presents a section-declared sheet. Returns false when refused.
    @discardableResult
    func present(_ r: SheetRequest) -> Bool {
        guard presented == nil else {
            NSLog("[sheet] refused %@ (a sheet is already up)", r.name)
            return false
        }
        guard let body = model.provider(r.section).sheet(r, model) else { return false }
        let vc = Hosting.controller(body, role: .sheet, model: model)
        return present(vc, request: r)
    }

    /// Presents an AppKit sheet controller (web sign-in).
    @discardableResult
    func present(_ vc: NSViewController, request: SheetRequest) -> Bool {
        guard presented == nil, let host = host() else {
            NSLog("[sheet] refused %@ (a sheet is already up)", request.name)
            return false
        }
        presented = vc
        presenter = host
        model.setSheet(request)
        host.presentAsSheet(vc)
        return true
    }

    /// Destructive confirmation (§9.5 alert): a stock `NSAlert` sheet
    /// with the app icon, the destructive action (default button, marked
    /// destructive) and Cancel. Refused while a sheet is up. `finished`
    /// runs once the alert is gone, whatever the answer (or refusal).
    func confirm(title: String, message: String, action: String, perform: @escaping () -> Void,
                 finished: (() -> Void)? = nil) {
        guard presented == nil, let window = host()?.view.window, window.attachedSheet == nil else {
            NSLog("[sheet] refused alert %@ (a sheet is already up)", title)
            finished?()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: action)
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { perform() }
            finished?()
        }
    }

    func dismiss() {
        guard let vc = presented else { return }
        presented = nil
        model.setSheet(nil)
        presenter?.dismiss(vc)
    }
}
