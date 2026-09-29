// MentionHover.swift — contact hover cards on @mentions inside message
// text. A SwiftUI Text can't report which run is under the pointer, so
// a transparent AppKit layer over the text (never hit-tested: clicks,
// links and selection still reach the Text) watches the pointer with a
// tracking area and hit-tests the character under it on the same
// attributed string laid out at the same width. A mention run carries a
// `betterteams-contact:` link; entering one drives the shared
// ContactHover coordinator (same 1 s dwell, warm switch and grace as
// names and avatars), and the card pops out beside that run.
import AppKit
import OstMacCore
import SwiftUI

/// The mention under the pointer: person name, character range and the
/// run's bounds (top-left origin, text coordinates).
struct MentionHit: Equatable {
    let name: String
    let range: NSRange
    let rect: CGRect
}

/// TextKit layout of one text segment, cached per width.
@MainActor
final class MentionLayout {
    let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    let width: CGFloat

    init(text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        self.width = width
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    /// The mention link run under `point`, or nil (plain text, blank
    /// space past a line's end, below the last line).
    func hit(at point: CGPoint) -> MentionHit? {
        guard storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        let link = storage.attribute(.link, at: index, effectiveRange: &range)
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
              let name = ContactLinks.name(from: url)
        else { return nil }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = CGRect.null
        // The line the pointer is on (a mention can wrap across lines).
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { r, stop in
            if r.contains(point) { rect = r; stop.pointee = true }
        }
        if rect.isNull { rect = manager.boundingRect(forGlyphRange: glyphs, in: container) }
        return MentionHit(name: name, range: range, rect: rect)
    }

    /// The AppKit string for a styled body segment: the segment's own
    /// AppKit attributes (mention/code fonts, links) over the body font.
    static func attributed(_ text: AttributedString, scale: Double) -> NSAttributedString {
        let ns = (try? NSMutableAttributedString(text, including: \.appKit))
            ?? NSMutableAttributedString(string: String(text.characters))
        let full = NSRange(location: 0, length: ns.length)
        let body = AppFont.nsBody(scale)
        ns.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { ns.addAttribute(.font, value: body, range: range) }
        }
        return ns
    }

    /// True when the segment has at least one mention link.
    static func hasMention(_ text: AttributedString) -> Bool {
        text.runs.contains { run in run.link.map { $0.scheme == ContactLinks.scheme } ?? false }
    }
}

/// Transparent pointer watcher over a text segment.
final class MentionTrackingView: NSView {
    var text = NSAttributedString() {
        didSet { if !text.isEqual(to: oldValue) { layoutCache = nil } }
    }
    /// (left, entered): each transition once.
    var onChange: ((MentionHit?, MentionHit?) -> Void)?
    private var layoutCache: MentionLayout?
    private(set) var current: MentionHit?

    override var isFlipped: Bool { true }

    /// Never the hit view: clicks, link taps and selection go to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }

    /// Pointer at `point` (view coordinates) or gone (nil).
    func pointer(at point: CGPoint?) {
        let hit = point.flatMap { layout()?.hit(at: $0) }
        guard hit?.range != current?.range || hit?.name != current?.name else { return }
        let left = current
        current = hit
        onChange?(left, hit)
    }

    private func layout() -> MentionLayout? {
        let width = bounds.width
        guard width > 0 else { return nil }
        if let c = layoutCache, c.width == width { return c }
        let fresh = MentionLayout(text: text, width: width)
        layoutCache = fresh
        return fresh
    }
}

private struct MentionTracker: NSViewRepresentable {
    let text: NSAttributedString
    let onChange: (MentionHit?, MentionHit?) -> Void

    func makeNSView(context: Context) -> MentionTrackingView {
        let v = MentionTrackingView()
        v.text = text
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: MentionTrackingView, context: Context) {
        v.text = text
        v.onChange = onChange
    }

    static func dismantleNSView(_ v: MentionTrackingView, coordinator: ()) {
        v.pointer(at: nil) // leaving the screen leaves the mention
    }
}

// MARK: - Modifier

extension View {
    /// Contact hover cards on the @mentions in this text segment.
    func mentionHover(_ text: AttributedString, scale: Double) -> some View {
        modifier(MentionHoverModifier(text: text, scale: scale))
    }
}

struct MentionHoverModifier: ViewModifier {
    let text: AttributedString
    let scale: Double
    var hover: ContactHover = .shared

    @Environment(\.windowModel) private var model
    @State private var base = UUID().uuidString
    /// The mention whose card is (or is about to be) up.
    @State private var shown: MentionHit?

    static func anchor(base: String, _ hit: MentionHit) -> String { base + ":" + String(hit.range.location) }

    func body(content: Content) -> some View {
        if model?.app != nil, MentionLayout.hasMention(text) {
            content
                .overlay {
                    MentionTracker(text: MentionLayout.attributed(text, scale: scale)) { left, entered in
                        if let left { hover.pointer(false, anchor: Self.anchor(base: base, left)) }
                        if let entered {
                            shown = entered
                            hover.pointer(true, anchor: Self.anchor(base: base, entered))
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let shown { anchorView(shown) }
                }
        } else {
            content
        }
    }

    /// Zero-content anchor at the mention's run; the card pops out below it.
    private func anchorView(_ hit: MentionHit) -> some View {
        let key = Self.anchor(base: base, hit)
        return Color.clear
            .frame(width: max(1, hit.rect.width), height: max(1, hit.rect.height))
            .allowsHitTesting(false)
            .popover(isPresented: Binding(
                get: { hover.isShown(key) },
                set: { if !$0, hover.isShown(key) { hover.dismiss() } }
            ), arrowEdge: .bottom) {
                ContactHoverCard(ref: ContactRef(name: hit.name), hover: hover)
                    .background { PopoverWindowClamp() }
                    .environment(\.windowModel, model)
                    .onHover { hover.card($0) }
            }
            .padding(.leading, max(0, hit.rect.minX))
            .padding(.top, max(0, hit.rect.minY))
            .accessibilityHidden(true)
    }
}
