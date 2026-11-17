// TimelineTableView.swift — the timeline's table, plus keyboard message
// selection (C8c). Plain Up/Down move the keyboard selection through
// the messages, Esc clears it; anything else (modifiers, PgUp/Dn,
// typing) behaves as before.
import AppKit

final class TimelineTableView: NSTableView {
    /// -1 up, +1 down. True = handled (no scroll, no beep).
    var onArrow: ((Int) -> Bool)?
    /// True = handled.
    var onEscape: (() -> Bool)?
    /// The window's services point at the focused timeline's actions.
    var onFocus: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain {
            switch event.keyCode {
            case 126:
                if onArrow?(-1) == true { return }
            case 125:
                if onArrow?(1) == true { return }
            case 53:
                if onEscape?() == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}
