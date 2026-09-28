// TransfersPopover.swift — the Transfers popover (UI-SPEC §6.6, §9.5):
// uploads and downloads with determinate progress, like Safari's
// Downloads. Anchored to the Transfers toolbar item; Clear drops
// finished and failed rows (finished downloads stay in Files ▸
// Downloads).
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class TransfersPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    var isShown: Bool { popover?.isShown == true }

    /// Shows the popover (closes it when already shown).
    func toggle(transfers: TransferStore, model: WindowModel, item: NSToolbarItem?, window: NSWindow) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = Hosting.controller(TransfersView(transfers: transfers).frame(width: 360),
                                                     role: .popover, model: model)
        popover = p
        if let item {
            p.show(relativeTo: item)
        } else if let v = window.contentView {
            // Toolbar hidden or item in overflow: top trailing corner.
            p.show(relativeTo: NSRect(x: v.bounds.maxX - 40, y: v.bounds.maxY - 1, width: 1, height: 1),
                   of: v, preferredEdge: .minY)
        }
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

struct TransfersView: View {
    @ObservedObject var transfers: TransferStore
    @Environment(\.windowModel) private var model

    /// Row height used to size the list (the popover has no scroll
    /// view of its own; the list scrolls past `maxRows`).
    static let rowHeight: CGFloat = 54
    static let maxRows = 6

    var body: some View {
        let items = transfers.popoverItems
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("No Transfers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                List(items) { t in
                    TransferRow(transfer: t) { reveal(t) }
                        .frame(minHeight: Self.rowHeight - 8)
                }
                .listStyle(.inset)
                .frame(height: CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 8)
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear") { transfers.clearFinished() }
                    .disabled(!items.contains { !$0.isRunning })
            }
            .padding(10)
        }
    }

    private func reveal(_ t: FileTransfer) {
        guard let model else { return }
        _ = model.provider(.files).perform(FilesCommands.showInFinder, arg: t.id, model)
    }
}

/// One transfer: file icon, name, progress (determinate when known),
/// status line in words (never color alone), Show in Finder.
struct TransferRow: View {
    let transfer: FileTransfer
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileItem.local(transfer).icon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                if transfer.isRunning {
                    if let p = transfer.progress {
                        ProgressView(value: p).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if transfer.direction == .download, transfer.status == .done, transfer.path != nil {
                Button(action: reveal) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let t = transfer
        switch t.status {
        case .running:
            let pct = t.progress.map { " \u{2014} \(Int(($0 * 100).rounded()))%" } ?? ""
            Text(t.direction == .upload ? "Uploading to \(t.origin)\(pct)" : "Downloading\(pct) \u{2014} \(sizeLine)")
        case .done:
            Text(t.direction == .upload ? "Uploaded to \(t.origin)" : "\(FilesFormat.size(t.size)) \u{2014} \(t.origin)")
        case .failed(let msg):
            Label("Failed \u{2014} \(msg)", systemImage: "exclamationmark.triangle")
        }
    }

    private var sizeLine: String {
        let total = transfer.size
        guard total > 0 else { return transfer.origin }
        let done = UInt64(Double(total) * (transfer.progress ?? 0))
        return "\(FilesFormat.size(done)) of \(FilesFormat.size(total))"
    }
}
