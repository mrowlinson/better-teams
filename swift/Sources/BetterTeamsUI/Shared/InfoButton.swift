// InfoButton.swift — the one (i) control every pane and sheet uses
// for explanatory text. Explanations open in a popover next to their
// control and are never laid out inline (no footers, no captions).
import SwiftUI

/// The (i) button beside a setting: its explanation opens in a popover,
/// never inline. A plain button, so VoiceOver reads its label and Full
/// Keyboard Access focuses it; Space or Return opens the popover.
struct InfoButton: View {
    let subject: String
    let text: String
    @State private var shown = false

    /// The spoken / tooltip name: "About <subject>".
    static func label(for subject: String) -> String { "About \(subject)" }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .focusable()
        .accessibilityLabel(Self.label(for: subject))
        .accessibilityHint("Shows an explanation")
        .help(Self.label(for: subject))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(text)
        }
    }
}

/// A row label with its (i) button: "Title (i)".
struct InfoLabel: View {
    let title: String
    let subject: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(subject: subject, text: text)
        }
    }
}

/// A grouped-form section header with its (i) button.
struct InfoHeader: View {
    let title: String
    let subject: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(subject: subject, text: text)
        }
    }
}
