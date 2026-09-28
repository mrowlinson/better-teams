// PaneContainerViewController.swift — one child per visited key,
// swapped without animation (UI-SPEC §5.1, R21, DL6).
//
// Hidden children stay alive off-window, so returning to a section
// keeps its scroll position, disclosure state, and draft text with no
// refetch (R24).
import AppKit

@MainActor
final class PaneContainerViewController: NSViewController {
    private var childrenByKey: [String: NSViewController] = [:]
    private(set) var visibleKey: String?
    private let initialSize: NSSize

    init(initialSize: NSSize) {
        self.initialSize = initialSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: initialSize))
    }

    /// The visible child (tests, evidence).
    var visibleChild: NSViewController? { visibleKey.flatMap { childrenByKey[$0] } }

    func hasChild(_ key: String) -> Bool { childrenByKey[key] != nil }

    /// Shows the child for `key`, creating it once. Synchronous: when
    /// this returns the new child is in the hierarchy and the old one is
    /// off-window.
    func show(_ key: String, make: () -> NSViewController) {
        guard key != visibleKey else { return }
        let child: NSViewController
        if let c = childrenByKey[key] {
            child = c
        } else {
            child = make()
            childrenByKey[key] = child
            addChild(child)
        }
        if let old = visibleKey.flatMap({ childrenByKey[$0] }) {
            old.view.removeFromSuperview()
        }
        let v = child.view
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        visibleKey = key
    }

    /// Releases a child (app unpinned or closed, call ended).
    func release(_ key: String) {
        guard let c = childrenByKey.removeValue(forKey: key) else { return }
        c.view.removeFromSuperview()
        c.removeFromParent()
        if visibleKey == key { visibleKey = nil }
    }
}
