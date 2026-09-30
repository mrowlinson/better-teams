// EvidenceGeometry.swift — evidence-only geometry line (UI-SPEC §11.4).
//
// With `--geometry-out <path>` (demo + evidence only), appends one line
// per capture: route, window and minimum size, split pane widths and
// collapse states, and the toolbar's items in order with their frames
// (window coordinates) — so toolbar order, search-field width and
// inspector yield are checked from numbers, not pixels.
import AppKit
import WebKit

@MainActor
enum EvidenceGeometry {
    static func append(_ wc: ShellWindowController, route: String?, appearance: String?) {
        let args = ProcessInfo.processInfo.arguments
        guard wc.model.options.demo, let i = args.firstIndex(of: "--geometry-out"), i + 1 < args.count,
              let window = wc.window else { return }
        let line = describe(window, split: wc.split, route: route ?? "-", appearance: appearance ?? "system")
            + CallEvidence.geometry(wc.model) + FilesSection.geometry(wc.model)
        let url = URL(fileURLWithPath: args[i + 1])
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func describe(_ w: NSWindow, split: ShellSplitViewController, route: String, appearance: String) -> String {
        func sz(_ s: NSSize) -> String { "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))" }
        func pane(_ name: String, _ item: NSSplitViewItem) -> String {
            item.isCollapsed ? "\(name)=collapsed" : "\(name)=\(Int(item.viewController.view.frame.width.rounded()))"
        }
        var out = "route=\(route) look=\(appearance) window=\(sz(w.frame.size)) min=\(sz(w.minSize))"
        out += " panes[" + [pane("rail", split.railItem), pane("list", split.listItem),
                            pane("detail", split.detailItem), pane("inspector", split.inspectorItem)]
            .joined(separator: " ") + "]"
        out += " needForInspector=\(Int(split.widthNeededForInspector.rounded()))"
        // Chrome (TOOLBARLINE): rail and inspector frames and the traffic
        // lights, y measured from the window top, so overlap is a number.
        out += " chrome[" + ChromeGeometry.describe(w, split: split) + "]"
        // In-window web views (app frames, channel web tabs): window rect.
        if let root = w.contentView {
            let webs = collect(root) { $0 is WKWebView }.map { $0.convert($0.bounds, to: nil) }
                .map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
            out += " webviews[" + webs.joined(separator: " ") + "]"
        }
        let bar: NSToolbar? = w.toolbar
        if let tb = bar {
            let items = tb.items.map { item -> String in
                var s = item.itemIdentifier.rawValue.replacingOccurrences(of: "NSToolbar", with: "")
                if item.isHidden { s += "(hidden)" }
                // Validation state (menu/action items, and view items'
                // controls): "(off)" = disabled.
                if !item.isEnabled || (item.view as? NSControl)?.isEnabled == false { s += "(off)" }
                if let search = item as? NSSearchToolbarItem {
                    s += "@\(frame(search.searchField, in: w))"
                } else if let v = item.view {
                    s += "@\(frame(v, in: w))"
                }
                return s
            }
            out += " toolbar[" + items.joined(separator: ", ") + "]"
            // Item viewers left→right (every visible item, view or not).
            if let root = w.contentView?.superview {
                let viewers = collect(root) { String(describing: type(of: $0)).contains("ItemViewer") }
                    .map { $0.convert($0.bounds, to: nil) }
                    .filter { $0.width > 0 }
                    .sorted { $0.minX < $1.minX }
                    .map { "\(Int($0.minX))+\(Int($0.width))" }
                out += " viewers[" + viewers.joined(separator: " ") + "]"
                // Named item positions (navigational placement vs the title).
                let named = collect(root) { String(describing: type(of: $0)).contains("ItemViewer") }
                    .compactMap { v -> (String, CGRect)? in
                        guard v.responds(to: NSSelectorFromString("item")),
                              let item = v.value(forKey: "item") as? NSToolbarItem else { return nil }
                        let r = v.convert(v.bounds, to: nil)
                        guard r.width > 0, !item.isHidden else { return nil }
                        return (item.itemIdentifier.rawValue, r)
                    }
                    .sorted { $0.1.minX < $1.1.minX }
                    .map { "\($0.0)@\(Int($0.1.minX))+\(Int($0.1.width))" }
                out += " items[" + named.joined(separator: " ") + "]"
                if let t = collect(root, { ($0 as? NSTextField)?.stringValue == w.title && $0.bounds.width > 0 }).first {
                    let r = t.convert(t.bounds, to: nil)
                    out += " title=\(Int(r.minX))+\(Int(r.width))"
                }
            }
        }
        // Segmented controls inside the list pane (search scope bar):
        // window x+width against the pane's own x+width. SwiftUI hosts
        // them in a platform-view host (not an NSSegmentedControl); a
        // SwiftUI menu picker has no AppKit view, so "seg=none".
        let listView = split.listItem.viewController.view
        if !split.listItem.isCollapsed, listView.window === w {
            let segs = collect(listView) {
                let n = String(describing: type(of: $0))
                return n.contains("PlatformViewHost") && n.contains("Segmented")
            }
            .filter { $0.bounds.width > 0 }
            .map { "seg@\(frame($0, in: w))" }
            out += " listControls[pane@\(frame(listView, in: w)) "
                + (segs.isEmpty ? "seg=none" : segs.joined(separator: " ")) + "]"
        }
        // Timelines (chat, Posts, thread): rows whose laid-out height
        // differs from a fresh measure at the current width.
        if let root = w.contentView {
            let audits = collect(root) { ($0 as? NSTableView)?.delegate is TimelineViewController }
                .compactMap { (($0 as? NSTableView)?.delegate as? TimelineViewController)?.geometryAudit() }
            if !audits.isEmpty { out += " timelines[" + audits.joined(separator: "; ") + "]" }
        }
        return out
    }

    private static func frame(_ v: NSView, in w: NSWindow) -> String {
        guard v.window === w else { return "offscreen" }
        let r = v.convert(v.bounds, to: nil)
        return "\(Int(r.minX))+\(Int(r.width))"
    }

    private static func collect(_ v: NSView, _ match: (NSView) -> Bool) -> [NSView] {
        var out: [NSView] = match(v) ? [v] : []
        for s in v.subviews { out += collect(s, match) }
        return out
    }
}

/// Window-top-based rects of the rail, the inspector and the three traffic
/// lights (TOOLBARLINE): the rail's icon stack must never sit under them.
@MainActor
enum ChromeGeometry {
    static func topRect(_ v: NSView, in w: NSWindow) -> NSRect {
        let r = v.convert(v.bounds, to: nil)
        return NSRect(x: r.minX, y: w.frame.height - r.maxY, width: r.width, height: r.height)
    }

    static func trafficLights(_ w: NSWindow) -> [NSRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { w.standardWindowButton($0) }.map { topRect($0, in: w) }
    }

    static func describe(_ w: NSWindow, split: ShellSplitViewController) -> String {
        func r(_ x: NSRect) -> String { "\(Int(x.minX)),\(Int(x.minY)),\(Int(x.width)),\(Int(x.height))" }
        let rail = split.railItem.viewController.view
        var parts = ["rail=\(r(topRect(rail, in: w))) railSafeTop=\(Int(rail.safeAreaInsets.top))"]
        if !split.inspectorItem.isCollapsed {
            parts.append("inspector=\(r(topRect(split.inspectorItem.viewController.view, in: w)))")
        }
        parts.append("lights=" + trafficLights(w).map(r).joined(separator: ";"))
        return parts.joined(separator: " ")
    }
}
