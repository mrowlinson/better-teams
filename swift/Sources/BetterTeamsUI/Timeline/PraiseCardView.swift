// PraiseCardView.swift — native Praise post rendering (PRAISE lane).
//
// A mined Praise post renders as a native card (badge medallion +
// sender line + recipient + note), never the generic Adaptive Card
// view: the badge art is a glyph, not a remote image.
import OstMacCore
import SwiftUI

/// Native rendering of one mined Praise post.
struct PraiseCardView: View {
    let post: PraisePost
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: post.badge?.symbol ?? "medal")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.tint.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if !post.sender.isEmpty {
                    Text("\(post.sender) sent praise to")
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                }
                if !post.recipient.isEmpty {
                    Text(post.recipient)
                        .font(AppFont.body(scale).weight(.semibold))
                }
                if let badge = post.badge {
                    Text(badge.displayName)
                        .font(AppFont.caption(scale).weight(.semibold))
                        .foregroundStyle(.tint)
                }
                if !post.note.isEmpty {
                    Text(post.note)
                        .font(AppFont.body(scale))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.fill.quinary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(praiseLabel)
    }

    private var praiseLabel: String {
        var parts: [String] = []
        if !post.sender.isEmpty, !post.recipient.isEmpty {
            parts.append("\(post.sender) sent praise to \(post.recipient)")
        } else if !post.recipient.isEmpty {
            parts.append("Praise for \(post.recipient)")
        } else {
            parts.append("Praise")
        }
        if let badge = post.badge { parts.append(badge.displayName) }
        if !post.note.isEmpty { parts.append(post.note) }
        return parts.joined(separator: ". ")
    }
}
