// SearchField.swift — NSSearchField wrapper for filter fields (UI-SPEC
// R23: the SwiftUI searchable modifier is banned; §10: no drawn focus ring).
import AppKit
import SwiftUI

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Filter"
    /// Return in the field (e.g. run a search that hits the network).
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.focusRingType = .none
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if f.stringValue != text { f.stringValue = text }
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?

        init(text: Binding<String>) { self.text = text }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
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
