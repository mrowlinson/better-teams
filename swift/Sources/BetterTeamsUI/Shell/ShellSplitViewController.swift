// ShellSplitViewController.swift — four split items, created once and
// never replaced (UI-SPEC §5.1, R2, R25).
//
//   rail (sidebar slot, fixed 80) | list (260–420) | detail (≥440) | inspector (260–360)
//
// Rail and list never collapse from a window resize; the list collapses
// only through Navigator for `.full`. The inspector collapses first when
// the window narrows; its collapse state is KVO-observed and reported to
// Navigator (equality-guarded, never echoed back). It also yields when
// it would not fit: expanding it in a window narrower than the four
// minimums (80 + 260 + 440 + 260 + dividers) would widen the window
// past the 900 pt minimum, so a route, restore or automatic open leaves
// it collapsed there (`inspectorFits`, decided at the inspector's
// minimum; where only a width below its last one fits, it opens at that
// width). Only an explicit Show Inspector (toolbar, menu, opening a
// thread) may grow the window, as in Xcode. `toggleSidebar:` is
// validated off and overridden as a no-op, so ⌃⌘S or a system-inserted
// menu item can never hide the rail.
import AppKit

@MainActor
final class ShellSplitViewController: NSSplitViewController {
    static let railWidth: CGFloat = 80

    let railItem: NSSplitViewItem
    let listItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    let listPane = PaneContainerViewController(initialSize: NSSize(width: 300, height: 600))
    let detailPane = PaneContainerViewController(initialSize: NSSize(width: 620, height: 600))
    let inspectorPane = PaneContainerViewController(initialSize: NSSize(width: 280, height: 600))

    /// Reports inspector collapse changes (user drag, toolbar, window
    /// resize) to Navigator.
    var onInspectorCollapsed: ((Bool) -> Void)?
    private var inspectorObservation: NSKeyValueObservation?
    private var appearanceObservation: NSKeyValueObservation?

    init(rail: NSViewController) {
        railItem = NSSplitViewItem(sidebarWithViewController: rail)
        listItem = NSSplitViewItem(contentListWithViewController: listPane)
        detailItem = NSSplitViewItem(viewController: detailPane)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorPane)
        super.init(nibName: nil, bundle: nil)

        railItem.minimumThickness = Self.railWidth
        railItem.maximumThickness = Self.railWidth
        railItem.canCollapse = false
        railItem.canCollapseFromWindowResize = false
        railItem.holdingPriority = .init(260)

        listItem.minimumThickness = 260
        listItem.maximumThickness = 420
        // Collapsible only while Navigator holds it collapsed (`.full`),
        // so a divider drag can never collapse it behind the model (R25).
        listItem.canCollapse = false
        listItem.canCollapseFromWindowResize = false
        listItem.holdingPriority = .init(255)

        detailItem.minimumThickness = 440
        detailItem.canCollapse = false
        detailItem.holdingPriority = .init(250)

        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 360
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.isCollapsed = true

        splitViewItems = [railItem, listItem, detailItem, inspectorItem]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated { self?.onInspectorCollapsed?(collapsed) }
        }
        // The inspector item hands its pane a vibrant appearance, but no
        // visual effect view sits behind the pane's content, so vibrant
        // control colors drew unblended: the Info | Catch Up | Pinned
        // segmented control and the Info form looked disabled next to the
        // detail's full-contrast header. The pane follows the window's
        // plain appearance instead (light, dark, high contrast).
        appearanceObservation = view.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] v, _ in
            MainActor.assumeIsolated {
                let plain: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                  .accessibilityHighContrastDarkAqua]
                let name = v.effectiveAppearance.bestMatch(from: plain) ?? .aqua
                if self?.inspectorPane.view.appearance?.name != name {
                    self?.inspectorPane.view.appearance = NSAppearance(named: name)
                }
            }
        }
    }

    func setAutosaveName(_ name: String?) {
        splitView.autosaveName = name
    }

    /// Non-animated collapse (programmatic layout changes never
    /// animate, R9).
    func setListCollapsed(_ collapsed: Bool) {
        guard listItem.isCollapsed != collapsed else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if collapsed { listItem.canCollapse = true }
            listItem.isCollapsed = collapsed
            if !collapsed { listItem.canCollapse = false }
        }
    }

    func setInspectorCollapsed(_ collapsed: Bool) {
        guard inspectorItem.isCollapsed != collapsed else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            inspectorItem.isCollapsed = collapsed
        }
    }

    /// Width the window needs for every visible pane at its minimum,
    /// the inspector included: it opens narrower than its last width
    /// when only that fits (`expandInspector(in:)`), so the fit is
    /// decided at its minimum.
    var widthNeededForInspector: CGFloat {
        panesWidth(inspector: inspectorItem.minimumThickness)
    }

    /// Rail + list (when shown) + detail at their minimums, dividers,
    /// and an inspector of `inspector` points.
    private func panesWidth(inspector: CGFloat) -> CGFloat {
        var w = railItem.minimumThickness + detailItem.minimumThickness + inspector
        var dividers: CGFloat = 2
        if !listItem.isCollapsed {
            w += listItem.minimumThickness
            dividers += 1
        }
        return w + dividers * splitView.dividerThickness
    }

    /// Whether the inspector can expand without widening `window`
    /// (passed in: during launch the split is not in its window yet).
    func inspectorFits(in window: NSWindow?) -> Bool {
        guard let width = window?.frame.width ?? view.window?.frame.width else { return true }
        return width >= widthNeededForInspector
    }

    /// Expands the inspector inside `window`: at its last width when that
    /// fits, else at the widest width that does (never below its
    /// minimum), the detail and then the list giving way down to their
    /// minimums. An inspector item's default collapse behavior widens
    /// the window by the whole inspector on every expand, and AppKit
    /// reopens a collapsed item at its last width, so the expanding pass
    /// runs with `.useConstraints` and a capped maximum (both restored
    /// after it). Only when even the minimum does not fit (an explicit
    /// request) does the window grow.
    func expandInspector(in window: NSWindow?) {
        guard inspectorItem.isCollapsed else { return }
        guard let width = window?.frame.width ?? view.window?.frame.width, width >= widthNeededForInspector else {
            return setInspectorCollapsed(false)
        }
        let minW = inspectorItem.minimumThickness, maxW = inspectorItem.maximumThickness
        let last = max(minW, min(maxW, inspectorPane.view.frame.width))
        let behavior = inspectorItem.collapseBehavior
        inspectorItem.collapseBehavior = .useConstraints
        inspectorItem.maximumThickness = max(minW, min(last, (width - panesWidth(inspector: 0)).rounded(.down)))
        setInspectorCollapsed(false)
        view.layoutSubtreeIfNeeded()
        inspectorItem.maximumThickness = maxW
        inspectorItem.collapseBehavior = behavior
    }

    // The rail can never be hidden.
    override func toggleSidebar(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) { return false }
        if item.action == #selector(toggleInspector(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }

    // The inspector toggles through Navigator (View ▸ Show Inspector and
    // the toolbar item both route there).
    override func toggleInspector(_ sender: Any?) {}

    // Divider 0 (rail | list) is not draggable: zero effective rect, so
    // no resize cursor.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        if dividerIndex == 0 { return .zero }
        return super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                               forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }
}
