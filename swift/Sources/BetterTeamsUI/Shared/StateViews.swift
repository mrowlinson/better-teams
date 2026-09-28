// StateViews.swift — designed pane states (UI-SPEC R18, R12, §6).
//
// Loading = ProgressView only when there is no data; error = inline
// message + Try Again; empty = ContentUnavailableView; no-selection =
// title only (NoSelectionPane), in the same type and place as every
// other pane title.
import SwiftUI

struct LoadingPane: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading")
    }
}

struct ErrorPane: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        EmptyPane(title, systemImage: "exclamationmark.triangle", message: message) {
            Button("Try Again", action: retry)
        }
    }
}

/// Empty, error and not-yet-available panes (R18, §6): a stock
/// `ContentUnavailableView` (label + description + actions), centered
/// on the pane's vertical center by `PaneAnchorLayout`, the same center
/// `LoadingPane`'s spinner sits on, so a loading → empty/error swap
/// keeps one center. The icon sits in a fixed-height slot so symbols of
/// different heights never change the group's height.
struct EmptyPane<Actions: View>: View {
    let title: String
    /// Nil keeps the icon slot empty (title-only panes).
    let symbol: String?
    let message: String?
    let actions: Actions

    init(_ title: String, systemImage: String?, message: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        PaneAnchorLayout {
            ContentUnavailableView {
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    if let symbol {
                        Image(systemName: symbol)
                            .frame(height: PaneAnchorLayout.iconSlot)
                    }
                }
            } description: {
                if let message { Text(message) }
            } actions: {
                actions
            }
        }
    }
}

/// Detail pane with nothing selected (§6 "No ‹Item› Selected"): the
/// macOS idiom (Mail, Notes) is the title alone, no symbol, so it never
/// repeats the list pane's empty state beside it. It is an `EmptyPane`
/// without an icon: same title type and color as the list pane's empty
/// or error title beside it (one style, R14 `.primary`), centered.
struct NoSelectionPane: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        EmptyPane(title, systemImage: nil)
    }
}

/// Fills the pane and centers its one subview at its ideal height on
/// the pane's center (clamped inside the pane): the point where
/// `LoadingPane` puts its spinner. Both fill the same safe-area region
/// (below the toolbar), so the two centers coincide.
struct PaneAnchorLayout: Layout {
    /// Icon slot height inside `EmptyPane` (fits every SF Symbol at the
    /// `ContentUnavailableView` icon size).
    static let iconSlot: CGFloat = 48

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let size = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = Self.top(for: size.height, in: bounds)
        v.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }

    /// Top of a `height`-tall subview centered in `bounds`, kept inside.
    static func top(for height: CGFloat, in bounds: CGRect) -> CGFloat {
        max(bounds.minY, min(bounds.midY - height / 2, bounds.maxY - height))
    }
}

extension EmptyPane where Actions == EmptyView {
    init(_ title: String, systemImage: String?, message: String? = nil) {
        self.init(title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
