// LoopComponentView.swift — native Loop component card (LOOPBUILD lane).
//
// A mined Loop embed renders as a static card (title, host, Open /
// Copy actions — always works, offline) plus a live snapshot section:
// the S1 page content when the gate is ready, else the honest
// disabled reason. No fake controls: nothing enabled does nothing.
import AppKit
import OstMacCore
import SwiftUI

/// S1 live snapshot for one component (gate-ready only; the view
/// never loads while the gate is closed).
@MainActor
final class LoopSnapshotLoader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(html: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func load(embed: LoopEmbed) {
        guard case .idle = phase else { return }
        guard let coords = LoopComponent.readCoords(componentURL: embed.componentURL) else {
            phase = .failed("This component link has no readable page address.")
            return
        }
        phase = .loading
        Task.blocking(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                let r = try RustCore.loopPageRead(host: coords.host, drive: coords.drive, item: coords.item)
                result = .success(r.html ?? "")
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success(let html) where !html.isEmpty:
                    self.phase = .loaded(html: html)
                case .success:
                    self.phase = .failed("The page came back empty.")
                case .failure(let e):
                    self.phase = .failed(e.localizedDescription)
                }
            }
        }
    }
}

/// Native card for one Loop embed: static link card + live snapshot.
struct LoopComponentView: View {
    let embed: LoopEmbed
    @StateObject private var loader = LoopSnapshotLoader()
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Loop component")
                    .font(AppFont.headline(scale))
                if embed.mode == .collaborate {
                    Text("Collaborate")
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                }
            }
            if !embed.host.isEmpty {
                Text(embed.host)
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Button("Open in Teams") { CardLinks.open(embed.componentURL) }
                    .buttonStyle(.link)
                    .font(AppFont.body(scale))
                Button("Copy Link") { CardLinks.copy(embed.componentURL) }
                    .buttonStyle(.link)
                    .font(AppFont.body(scale))
            }
            snapshotSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop component")
    }

    /// Live snapshot when the gate is ready (loads once, on appear);
    /// the disabled reason otherwise — never a spinner to nowhere.
    @ViewBuilder
    private var snapshotSection: some View {
        switch LoopGate.state {
        case .ready:
            switch loader.phase {
            case .idle:
                Text("Loading live content…")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
                    .onAppear { loader.load(embed: embed) }
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading live content")
            case .loaded(let html):
                Text(LoopNotesText.plain(fromHTML: html))
                    .font(AppFont.body(scale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
        case .disabled(let reason):
            Text(reason)
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
        }
    }
}
