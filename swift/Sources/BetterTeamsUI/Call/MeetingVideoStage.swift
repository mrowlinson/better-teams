// MeetingVideoStage.swift — group chat and meeting video (MEETVIDEO,
// UI-SPEC §8): one tile per remote person (stable ids, roster order),
// then the self view and the share tile, in `TileGridLayout`; a pinned
// person takes the spotlight (`SpotlightLayout`, same tiles, same ids).
// Camera-on tiles show the person's decoded video (the last frame stays
// through stalls); camera-off tiles show the avatar; every change is a
// crossfade. The active speaker gets the accent ring. Pin / Unpin from a
// tile's context menu or its accessibility action. Someone else's screen
// share (CALLFIX) takes the stage: the shared screen large and fitted, the
// people in the strip (`SpotlightLayout`), back to the grid when it ends.
import OstMacCore
import SwiftUI

struct MeetingVideoStage: View {
    let session: CallSession
    @ObservedObject var video: MeetingVideoModel
    let status: String
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    /// One cell: a remote person, someone else's shared screen, or a
    /// local tile (self view, own share).
    private enum Item: Identifiable {
        case remote(MeetingVideoPlan.Tile)
        case remoteShare(LiveVideoModel)
        case local(CallTile)

        var id: String {
            switch self {
            case .remote(let t): "remote:" + t.id
            case .remoteShare: "remote-share"
            case .local(let t): "local:" + t.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if !session.connected {
                Text(status)
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            layout {
                ForEach(items) { item in
                    switch item {
                    case .remote(let t):
                        MeetingTileView(tile: t, decoder: video.videos[t.id], demo: video.demo,
                                        animated: !session.isEvidence, seed: Self.seed(t.id),
                                        pinned: video.pinnedID == t.id,
                                        onPin: { video.pin(video.pinnedID == t.id ? nil : t.id) })
                    case .remoteShare(let m):
                        RemoteShareView(model: m, presenter: video.presenter?.name)
                    case .local(let t):
                        CallTileView(tile: t, camera: session.camera)
                    }
                }
            }
            .animation(VideoFade.animation, value: video.pinnedID)
            .animation(VideoFade.animation, value: video.shareVideo != nil)
        }
        .padding(16)
    }

    private var layout: AnyLayout {
        video.pinnedID == nil && video.shareVideo == nil
            ? AnyLayout(TileGridLayout(spacing: 8)) : AnyLayout(SpotlightLayout(spacing: 8))
    }

    private var items: [Item] {
        let own = model?.ownDisplayName ?? "You"
        let me = video.roster.first { $0.isSelf }
        let c = session.controls
        var out = video.tiles.map { Item.remote($0) }
        if let share = video.shareVideo { out.insert(.remoteShare(share), at: 0) }
        out.append(.local(CallTile(id: "self", name: own, kind: .selfView,
                                   speaking: me != nil && me?.id == video.dominantID && !c.muted,
                                   muted: c.muted, cameraOn: c.cameraOn)))
        if session.sharing {
            out.append(.local(CallTile(id: "share", name: "Your Screen", kind: .share, speaking: false,
                                       muted: false, cameraOn: false)))
        }
        return out
    }

    /// Stable per-person demo scene (deterministic across launches).
    static func seed(_ id: String) -> Int {
        id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

/// One remote person: video (live decoder or demo scene) while their
/// camera is on, else the avatar; name chip with muted / pinned glyphs.
struct MeetingTileView: View {
    let tile: MeetingVideoPlan.Tile
    let decoder: LiveVideoModel?
    let demo: Bool
    let animated: Bool
    let seed: Int
    let pinned: Bool
    let onPin: () -> Void
    @Environment(\.contentTextScale) private var scale

    private var showsVideo: Bool { tile.videoOn && (demo || decoder != nil) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.fill.tertiary)
            if showsVideo {
                videoLayer.transition(.opacity)
            } else {
                Avatar(name: tile.name, diameter: 72)
                    .padding(4)
                    .transition(.opacity)
            }
        }
        .animation(VideoFade.animation, value: showsVideo)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(tile.speaking ? 1 : 0)
                .animation(VideoFade.animation, value: tile.speaking)
        }
        .overlay(alignment: .bottomLeading) { chip.padding(8) }
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin", action: onPin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAction(named: pinned ? "Unpin" : "Pin", onPin)
    }

    @ViewBuilder
    private var videoLayer: some View {
        if demo {
            DemoRemoteVideo(animated: animated, seed: seed)
        } else if let decoder {
            TileVideo(model: decoder, name: tile.name)
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            if pinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
            }
            if tile.muted {
                Image(systemName: "mic.slash.fill").foregroundStyle(.secondary)
            }
            Text(tile.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(AppFont.subheadline(scale))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var accessibility: String {
        var parts = [tile.name]
        if pinned { parts.append("pinned") }
        if tile.speaking { parts.append("speaking") }
        if tile.muted { parts.append("muted") }
        parts.append(tile.videoOn ? "camera on" : "camera off")
        return parts.joined(separator: ", ")
    }
}

/// Someone else's shared screen on the stage: the whole screen, fitted
/// (never cropped), a waiting line until the first frame; the last frame
/// stays through stalls. Name chip: "<Name> is presenting".
private struct RemoteShareView: View {
    @ObservedObject var model: LiveVideoModel
    let presenter: String?
    @Environment(\.contentTextScale) private var scale

    private var title: String {
        presenter.map { "\($0) is presenting" } ?? "Screen share"
    }

    private var waiting: String {
        presenter.map { "Waiting for \($0)\u{2019}s screen\u{2026}" } ?? "Waiting for the shared screen\u{2026}"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.fill.tertiary)
            if let img = model.remoteImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Text(waiting)
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .animation(VideoFade.animation, value: model.remoteImage == nil)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) { chip.padding(8) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.remoteImage == nil ? waiting : title)
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(AppFont.subheadline(scale))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A tile's decoded frames, cropped to fill; the avatar until the first
/// frame. The model keeps its last frame, so a stall never blanks.
private struct TileVideo: View {
    @ObservedObject var model: LiveVideoModel
    let name: String

    var body: some View {
        ZStack {
            if let img = model.remoteImage {
                Color.clear
                    .overlay {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .transition(.opacity)
            } else {
                Avatar(name: name, diameter: 72)
                    .padding(4)
                    .transition(.opacity)
            }
        }
        .animation(VideoFade.animation, value: model.remoteImage == nil)
    }
}

/// Spotlight: the first tile large, the rest in one row along the
/// bottom. Pure function of the proposal (no geometry readers).
struct SpotlightLayout: Layout {
    var spacing: CGFloat = 8
    var aspect: CGFloat = 16.0 / 9.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 360))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let rest = subviews.count - 1
        var stripH: CGFloat = 0
        if rest > 0 {
            let byWidth = (bounds.width - CGFloat(rest - 1) * spacing) / CGFloat(rest) / aspect
            stripH = max(0, floor(min(bounds.height * 0.22, byWidth)))
        }
        let mainH = bounds.height - (stripH > 0 ? stripH + spacing : 0)
        var w = bounds.width
        var h = w / aspect
        if h > mainH {
            h = max(0, mainH)
            w = h * aspect
        }
        first.place(at: CGPoint(x: bounds.midX - w / 2, y: bounds.minY + (mainH - h) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: floor(w), height: floor(h)))
        guard rest > 0 else { return }
        let tw = floor(stripH * aspect)
        let rowW = CGFloat(rest) * tw + CGFloat(rest - 1) * spacing
        var x = bounds.midX - rowW / 2
        for v in subviews.dropFirst() {
            v.place(at: CGPoint(x: x, y: bounds.maxY - stripH), anchor: .topLeading,
                    proposal: ProposedViewSize(width: tw, height: stripH))
            x += tw + spacing
        }
    }
}
