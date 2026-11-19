// WhiteboardSharedView.swift — WHITEBOARD-BUILD: the whiteboard
// pane's shared-board section (record + share + snapshot).
//
// The board itself renders above through the tab's embed route; this
// section is the mapped REST surface: board title + sharing state, a
// working Share control (mint + copy + open), the read-only snapshot
// count, and New Board. When the service is unreachable the section
// is disabled with the server's reason and the local sketch below
// stays the offline fallback. No control here is decorative: every
// button performs its mapped call. Live op streaming is not
// connected in this lane, and the status line says so.
import AppKit
import OstMacCore
import SwiftUI

/// Collapsible shared-board section for a whiteboard pane.
struct WhiteboardSharedSection: View {
    let boardID: String
    let demo: Bool
    @ObservedObject var shared: WhiteboardSharedStore
    @State private var expanded = true
    @State private var showingCreate = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Group {
                switch shared.load {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading shared board…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                case .unavailable(let reason):
                    WhiteboardUnavailable(reason: reason) {
                        Task { await shared.refresh(boardID: boardID, demo: demo) }
                    } onCreate: {
                        showingCreate = true
                    }
                case .loaded(let board):
                    WhiteboardLoadedBoard(
                        boardID: boardID, demo: demo, shared: shared, board: board)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Shared board", systemImage: "person.2")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task { await shared.load(boardID: boardID, demo: demo) }
        .sheet(isPresented: $showingCreate) {
            WhiteboardCreateSheet { title in
                Task { await shared.create(title: title, demo: demo) }
            }
        }
        .help("The shared board behind this tab")
    }
}

/// Live-gated state: why the board is unreachable, what still works.
struct WhiteboardUnavailable: View {
    /// The promise beside every gate: the reason is the server's.
    static let fallbackCaption = "Local sketch below still works offline."
    let reason: String
    let onRetry: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(reason).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .accessibilityLabel("Shared board unavailable: \(reason)")
            Text(Self.fallbackCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                Button("New Board…", action: onCreate)
            }
            .controlSize(.small)
        }
    }
}

/// Loaded board: record + share + snapshot. Every control works.
struct WhiteboardLoadedBoard: View {
    /// The honesty line under every snapshot: streaming is not on.
    static let syncStatus = "Live updates unavailable — op streaming awaits live verification."
    let boardID: String
    let demo: Bool
    @ObservedObject var shared: WhiteboardSharedStore
    let board: WhiteboardSharedBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(board.board.title.isEmpty ? "Untitled board" : board.board.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(board.board.isShared ? "Shared" : "Not shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(board.board.isShared ? "Shared" : "Not shared")
                if let perms = board.perms {
                    Text(perms.canEdit ? "Can edit" : "View only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            snapshotLine
            shareRow
            HStack(spacing: 12) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await shared.refresh(boardID: boardID, demo: demo) }
                }
                if board.hasMoreOps {
                    Button("Read more") {
                        Task { await shared.loadMore(boardID: boardID, demo: demo) }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var snapshotLine: some View {
        if let error = board.snapshotError, board.ops == nil {
            Text("Snapshot unreadable: \(error)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Snapshot \(board.ops ?? 0) ops · \(Self.syncStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Snapshot \(board.ops ?? 0) operations. \(Self.syncStatus)")
        }
    }

    @ViewBuilder
    private var shareRow: some View {
        if let link = board.share?.shareURI, !link.isEmpty {
            HStack(spacing: 12) {
                Link("Open share link", destination: URL(string: link) ?? URL(string: "about:blank")!)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 12) {
                Button(shared.sharing ? "Sharing…" : "Share…", systemImage: "square.and.arrow.up") {
                    Task { await shared.share(boardID: boardID, demo: demo) }
                }
                .disabled(shared.sharing)
                if let error = board.shareError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .controlSize(.small)
        }
    }
}

/// New-board sheet: title field + Create/Cancel. Native form.
private struct WhiteboardCreateSheet: View {
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Board").font(.headline)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(name.isEmpty ? nil : name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 300)
    }
}
