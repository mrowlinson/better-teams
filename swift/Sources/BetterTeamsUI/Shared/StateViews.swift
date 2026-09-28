// StateViews.swift — designed pane states (UI-SPEC R18, R12, §6).
//
// Loading = ProgressView only when there is no data; error = inline
// message + Try Again; empty = ContentUnavailableView; no-selection =
// title only (NoSelectionPane), in the same type and place as every
// other pane title.
import SwiftUI

/// First load with nothing on hand: a centered spinner with its label
/// ("Loading Shifts…") underneath, shown only after `delayMilliseconds`
/// so a fast load shows nothing at all. Determinate (a bar) when the
/// step count is known. The spinner stays on the pane's center (the
/// label hangs below it), the point `PaneAnchorLayout` centers on.
struct LoadingPane: View {
    /// A load that lands sooner than this never shows the pane.
    static let delayMilliseconds: UInt64 = 300

    let label: String?
    /// 0…1 when the step count is known; nil = indeterminate spinner.
    let progress: Double?
    @Environment(\.windowModel) private var model
    @State private var visible = false
    @State private var delay = Debounce(milliseconds: LoadingPane.delayMilliseconds)

    init(_ label: String? = nil, progress: Double? = nil) {
        self.label = label
        self.progress = progress
    }

    var body: some View {
        indicator
            .overlay(alignment: .top) {
                if let label {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .alignmentGuide(.top) { $0[.top] - 28 }
                }
            }
            .opacity(visible || model?.options.evidence == true ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(label))
            .onAppear { delay.schedule { visible = true } }
            .onDisappear { delay.cancel() }
    }

    @ViewBuilder private var indicator: some View {
        if let progress {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 180)
        } else {
            ProgressView()
                .controlSize(.regular)
        }
    }

    /// "Loading Shifts…" reads "Loading Shifts" (no ellipsis spoken).
    static func accessibilityLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "Loading" }
        return label.hasSuffix("\u{2026}") ? String(label.dropLast()) : label
    }
}

/// A refresh running behind content already on screen (R12: the rows
/// never change for it). A small spinner in the pane's bottom-trailing
/// corner while `refreshing` (after the same delay as `LoadingPane`, so a
/// fast refresh shows nothing), or — when the last refresh failed — a
/// quiet warning glyph: tooltip = the error, click = Try Again.
struct RefreshStatus: ViewModifier {
    let refreshing: Bool
    let failure: String?
    let label: String
    let retry: (() -> Void)?
    @State private var visible = false
    @State private var delay = Debounce(milliseconds: LoadingPane.delayMilliseconds)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(visible ? 1 : 0)
                            .help(label)
                            .accessibilityLabel(label)
                            .accessibilityHidden(!visible)
                    } else if let failure {
                        Button {
                            retry?()
                        } label: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Couldn\u{2019}t refresh: \(failure)")
                        .accessibilityLabel("Couldn\u{2019}t Refresh")
                    }
                }
                .padding(10)
            }
            .onChange(of: refreshing, initial: true) { _, now in
                if now {
                    delay.schedule { visible = true }
                } else {
                    delay.cancel()
                    visible = false
                }
            }
    }
}

extension View {
    /// Background-refresh status over this content (see `RefreshStatus`).
    func refreshStatus(_ refreshing: Bool, failure: String? = nil, label: String,
                       retry: (() -> Void)? = nil) -> some View {
        modifier(RefreshStatus(refreshing: refreshing, failure: failure, label: label, retry: retry))
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
