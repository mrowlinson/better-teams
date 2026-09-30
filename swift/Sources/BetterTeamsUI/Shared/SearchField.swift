// SearchField.swift — NSSearchField wrapper for filter fields (UI-SPEC
// R23: the SwiftUI searchable modifier is banned; §10: no drawn focus ring).
import AppKit
import SwiftUI

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Filter"
    /// Return in the field (e.g. run a search that hits the network).
    var onSubmit: (() -> Void)?
    /// Arrow keys (dx, dy); true = handled. Left/Right only reach it while
    /// the field is empty, so the caret keeps moving through typed text.
    var onMove: ((Int, Int) -> Bool)?
    /// Take keyboard focus when it appears (pickers in popovers).
    var focusOnAppear = false

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.focusRingType = .none
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        if focusOnAppear { DispatchQueue.main.async { f.window?.makeFirstResponder(f) } }
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onMove = onMove
        if f.stringValue != text { f.stringValue = text }
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        var onMove: ((Int, Int) -> Bool)?

        init(text: Binding<String>) { self.text = text }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if let onMove {
                switch sel {
                case #selector(NSResponder.moveUp(_:)): return onMove(0, -1)
                case #selector(NSResponder.moveDown(_:)): return onMove(0, 1)
                case #selector(NSResponder.moveLeft(_:)): return textView.string.isEmpty && onMove(-1, 0)
                case #selector(NSResponder.moveRight(_:)): return textView.string.isEmpty && onMove(1, 0)
                default: break
                }
            }
            guard sel == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
            onSubmit()
            return true
        }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSSearchField else { return }
            text.wrappedValue = f.stringValue
        }
    }
}
