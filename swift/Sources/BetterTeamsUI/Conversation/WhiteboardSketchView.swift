// WhiteboardSketchView.swift — WHITEBOARD: the whiteboard pane's
// basic-ink section (native Canvas, local only).
//
// The shared board renders above through the tab's embed URL; this
// section is the user's own sketch pad. Strokes live in a
// `WhiteboardInkStore` (per board, in memory) and are never synced,
// saved, or sent anywhere — the caption says so.
import AppKit
import OstMacCore
import SwiftUI

/// Collapsible local-sketch section for a whiteboard pane.
struct WhiteboardSketchSection: View {
    let boardID: String
    @ObservedObject var ink: WhiteboardInkStore
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            WhiteboardSketchView(boardID: boardID, ink: ink)
                .frame(minHeight: 220)
                .padding(.top, 4)
        } label: {
            Label("Local sketch", systemImage: "pencil.tip")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Draw here; the sketch stays on this Mac")
    }
}

/// Native basic ink: drag to draw, pen color/width, undo, clear.
struct WhiteboardSketchView: View {
    /// The promise beside every sketch: local only, never shared.
    static let localOnlyCaption = "Local sketch — stays on this Mac, not shared."

    let boardID: String
    @ObservedObject var ink: WhiteboardInkStore
    @State private var color: Color = .black
    @State private var width: CGFloat = 3
    @State private var current: [CGPoint] = []

    private var strokes: [WhiteboardStroke] { ink.strokes(for: boardID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            canvas
                .background(.quinary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Local sketch canvas")
            controls
            Text(Self.localOnlyCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canvas: some View {
        Canvas { context, _ in
            for s in strokes { context.stroke(path(s.points), with: .color(color(s)), lineWidth: max(1, s.width)) }
            if !current.isEmpty {
                context.stroke(path(current), with: .color(color), lineWidth: max(1, width))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { current.append($0.location) }
                .onEnded { _ in
                    ink.add(WhiteboardStroke(points: current, red: ns(color).redComponent,
                                             green: ns(color).greenComponent, blue: ns(color).blueComponent,
                                             width: width), to: boardID)
                    current = []
                }
        )
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ColorPicker("Ink color", selection: $color)
                .labelsHidden()
                .accessibilityLabel("Ink color")
            Slider(value: $width, in: 1...12, step: 1)
                .frame(maxWidth: 140)
                .accessibilityLabel("Pen width")
            Spacer(minLength: 0)
            Button("Undo", systemImage: "arrow.uturn.backward") { ink.undo(board: boardID) }
                .disabled(strokes.isEmpty && current.isEmpty)
            Button("Clear", systemImage: "trash") { ink.clear(board: boardID) }
                .disabled(strokes.isEmpty)
        }
        .controlSize(.small)
    }

    private func path(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        p.addLines(Array(points.dropFirst()))
        return p
    }

    private func color(_ s: WhiteboardStroke) -> Color {
        Color(red: s.red, green: s.green, blue: s.blue)
    }

    private func ns(_ c: Color) -> NSColor { NSColor(c) }
}
