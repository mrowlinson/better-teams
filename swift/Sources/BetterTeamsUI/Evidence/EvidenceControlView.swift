// EvidenceControlView.swift — the positive control card (UI-SPEC §11.4)
// plus a rail-button state gallery (every visual state the rail can
// show, forced, so each is inspectable in light and dark).
import SwiftUI

struct EvidenceControlView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("EVIDENCE CONTROL")
                .font(.largeTitle.weight(.bold))
            HStack(spacing: 12) {
                swatch(Color(nsColor: .systemRed), "red")
                swatch(Color(nsColor: .systemGreen), "green")
                swatch(Color(nsColor: .systemBlue), "blue")
                swatch(Color(nsColor: .labelColor), "label")
                swatch(Color(nsColor: .windowBackgroundColor), "window")
            }
            Text("Rail button states").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                ForEach(RailButtonForced.allCases, id: \.rawValue) { f in
                    VStack(spacing: 6) {
                        Button {} label: {
                            RailButtonLabel(title: "Chat", symbol: "bubble.left.and.bubble.right", badge: nil)
                        }
                        .buttonStyle(RailButtonStyle(selected: false, height: 54, forced: f))
                        Text(f.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Badges").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                ForEach(BadgeSample.all) { sample in
                    let n = sample.count
                    VStack(spacing: 6) {
                        Button {} label: {
                            RailButtonLabel(title: "Activity", symbol: "bell", badge: n)
                        }
                        .buttonStyle(RailButtonStyle(selected: false, height: 54, forced: .normal))
                        Text(n == 0 ? "dot" : "\(n)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(RailSize.allSizes, id: \.rawValue) { s in
                    VStack(spacing: 6) {
                        Button {} label: {
                            RailButtonLabel(title: "Calendar", symbol: "calendar", badge: nil)
                        }
                        .buttonStyle(RailButtonStyle(selected: true, height: RailModel.itemHeight(s), forced: .selected))
                        Text(s.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        // Render the gallery's key-window look even when the capture runs
        // with the app inactive (locked screen, another app frontmost).
        .environment(\.controlActiveState, .key)
    }

    private func swatch(_ c: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6).fill(c).frame(width: 80, height: 50)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text(name).font(.caption)
        }
    }
}

private struct BadgeSample: Identifiable {
    let count: Int
    var id: Int { count }
    static let all = [3, 42, 120, 0].map(BadgeSample.init)
}

extension RailSize {
    static let allSizes: [RailSize] = [.small, .medium, .large]
}
