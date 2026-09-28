// CallStageViewController.swift — the call stage (UI-SPEC §8 shared
// parts): one per call, created by `CallSession`, attached by exactly
// one host at a time through `CallStageHostController` (main window's
// call section, or the call window). Detach never destroys; the stage
// is released with its session at call end.
//
// Body: the pre-join step for meetings (`PreJoinView`), then the stage:
// remote tiles, self view and share tile in `TileGridLayout`; audio
// tiles show avatars with speaking rings. Controls live in the host's
// toolbar and the Call menu, never in the stage (no bottom bar).
import AppKit
import AVFoundation
import OstMacCore
import SwiftUI

@MainActor
public final class CallStageViewController: NSViewController {
    weak var session: CallSession?

    override public func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let body = Hosting.controller(CallStageRoot(stage: self), role: .pane, model: session?.model)
        addChild(body)
        body.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body.view)
        NSLayoutConstraint.activate([
            body.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.view.topAnchor.constraint(equalTo: view.topAnchor),
            body.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Removes the stage from whichever host holds it (never destroys).
    func detachFromHost() {
        guard parent != nil else { return }
        view.removeFromSuperview()
        removeFromParent()
    }
}

/// A host's slot for the stage: embeds the given stage as a child and
/// swaps it when the session changes (new call) or clears it (ended).
@MainActor
final class CallStageHostController: NSViewController {
    private(set) weak var stage: CallStageViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    func attach(_ s: CallStageViewController?) {
        guard s !== stage || s?.parent !== self else { return }
        if stage?.parent === self { stage?.detachFromHost() }
        stage = s
        guard let s else { return }
        s.detachFromHost()
        addChild(s)
        let v = s.view
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// SwiftUI bridge for the main window's call section detail pane. A
/// section switch dismantles the slot: the stage detaches (audio and
/// sharing keep running) and the next slot re-attaches the same stage.
struct CallStageSlot: NSViewControllerRepresentable {
    let stage: CallStageViewController?

    func makeNSViewController(context: Context) -> CallStageHostController {
        let c = CallStageHostController()
        c.attach(stage)
        return c
    }

    func updateNSViewController(_ c: CallStageHostController, context: Context) {
        c.attach(stage)
    }

    static func dismantleNSViewController(_ c: CallStageHostController, coordinator: ()) {
        c.attach(nil)
    }
}

// MARK: stage body

private struct CallStageRoot: View {
    let stage: CallStageViewController

    var body: some View {
        if let session = stage.session, let app = session.model?.app {
            CallStageView(session: session, call: app.call, meetings: app.meetings, roster: app.meeting)
        } else {
            EmptyPane("No Call", systemImage: "phone")
        }
    }
}

struct CallStageView: View {
    let session: CallSession
    @ObservedObject var call: CallStore
    @ObservedObject var meetings: MeetingsViewModel
    @ObservedObject var roster: MeetingRosterStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Group {
            if session.isMeeting, !session.joined {
                PreJoinView(session: session, status: status, canJoin: meetings.pendingJoin != nil)
            } else if session.video {
                videoStage
            } else {
                stageGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tiles: [CallTile] {
        let own = model?.ownDisplayName ?? "You"
        return CallTiles.make(
            roster: session.isMeeting ? roster.participants : [], peer: session.peerName, ownName: own,
            isOwn: { p in model?.isOwnID(p.id) == true || p.name == own || p.name == "Me" },
            muted: session.controls.muted, cameraOn: session.controls.cameraOn, sharing: session.sharing)
    }

    private var stageGrid: some View {
        VStack(spacing: 12) {
            if !session.connected {
                Text(status)
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            TileGridLayout(spacing: 8) {
                ForEach(tiles) { t in
                    CallTileView(tile: t, camera: session.camera)
                }
            }
        }
        .padding(16)
    }

    /// 1:1 video call (VIDEO1): the remote video fills the stage, the
    /// self view floats bottom-trailing as a picture-in-picture.
    private var videoStage: some View {
        let own = tiles.first { $0.kind == .selfView }
        return ZStack(alignment: .bottomTrailing) {
            // 1:1: the one remote participant (meeting video: a tile per
            // `remoteVideos` entry in the grid).
            RemoteVideoTile(model: session.remoteVideos.values.first, name: session.peerName ?? session.title,
                            demo: session.store?.isDemo == true && session.connected,
                            animated: !session.isEvidence, status: session.connected ? nil : status)
            if let own {
                CallTileView(tile: own, camera: session.camera)
                    .frame(width: 192, height: 108)
                    .shadow(radius: 4)
                    .padding(12)
                    .animation(VideoFade.animation, value: own.cameraOn)
            }
        }
        .padding(16)
    }

    /// Call state in words (§10: never color alone).
    private var status: String {
        if session.isMeeting {
            if !session.joined {
                if meetings.parsing { return "Getting the meeting ready…" }
                if meetings.pendingJoin != nil { return "Ready to join" }
                return meetings.joinHint ?? "Getting the meeting ready…"
            }
            switch meetings.lobby {
            case .idle, .joining: return "Joining…"
            case .lobby: return "Waiting in the lobby. Someone in the meeting will let you in."
            case .admitted: return "Connected"
            case .failed: return meetings.lobbyDetail.map { "Couldn\u{2019}t join: \($0)" } ?? "Couldn\u{2019}t join"
            }
        }
        switch call.phase {
        case .idle: return call.error.map { "Couldn\u{2019}t call: \($0)" } ?? "Calling…"
        case .inviting: return "Calling…"
        case .active: return "Connected"
        case .ended: return "Call ended"
        }
    }
}

/// One tile: camera (self view), screen share, or avatar with a
/// speaking ring (audio). Name + muted glyph on a label chip.
struct CallTileView: View {
    let tile: CallTile
    let camera: CameraCapture?
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.fill.tertiary)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) { nameChip.padding(8) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder
    private var content: some View {
        switch tile.kind {
        case .selfView where tile.cameraOn:
            if let camera {
                CameraPreview(camera: camera)
            } else {
                PlaceholderFeed()
            }
        case .share:
            VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("You\u{2019}re sharing your screen")
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
            }
        default:
            Avatar(name: tile.name, diameter: 72)
                .padding(4)
                .overlay {
                    if tile.speaking {
                        Circle().strokeBorder(.tint, lineWidth: 3)
                    }
                }
        }
    }

    private var nameChip: some View {
        HStack(spacing: 4) {
            if tile.muted {
                Image(systemName: "mic.slash.fill").foregroundStyle(.secondary)
            }
            Text(tile.kind == .selfView ? "You" : tile.name)
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
        var parts = [tile.kind == .selfView ? "You" : tile.name]
        if tile.kind == .share { parts = ["Your screen"] }
        if tile.speaking { parts.append("speaking") }
        if tile.muted { parts.append("muted") }
        if tile.kind == .selfView { parts.append(tile.cameraOn ? "camera on" : "camera off") }
        return parts.joined(separator: ", ")
    }
}

/// The remote side of a 1:1 video call: decoded frames (live) or the
/// demo sunset feed; the peer's avatar until the first frame arrives.
struct RemoteVideoTile: View {
    /// This participant's decoder (nil: demo, or live media not up yet).
    let model: LiveVideoModel?
    let name: String
    let demo: Bool
    let animated: Bool
    let status: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black)
            if let model {
                LiveRemoteVideo(model: model, name: name, status: status)
            } else if demo {
                DemoRemoteVideo(animated: animated)
            } else {
                RemoteVideoWaiting(name: name, status: status ?? "Waiting for video…")
            }
        }
        // Waiting → first frame crossfades (never a blank flash).
        .animation(VideoFade.animation, value: model == nil && demo)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), video")
    }
}

/// The one crossfade video views use for state changes (a fade, so it
/// stays under Reduce Motion; never a blank frame between states).
enum VideoFade {
    static let animation = Animation.easeInOut(duration: 0.25)
}

/// Live remote frames (`LiveVideoModel`: core AU queue → VT decode).
private struct LiveRemoteVideo: View {
    @ObservedObject var model: LiveVideoModel
    let name: String
    let status: String?

    var body: some View {
        // The last decoded frame stays up through stalls and camera-off
        // (the peer's black frames are content); the model never clears it.
        ZStack {
            if let img = model.remoteImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RemoteVideoWaiting(name: name, status: status ?? "Waiting for video…")
            }
        }
        .animation(VideoFade.animation, value: model.remoteImage == nil)
    }
}

private struct RemoteVideoWaiting: View {
    let name: String
    let status: String?
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(spacing: 12) {
            Avatar(name: name, diameter: 96)
            if let status {
                Text(status)
                    .font(AppFont.body(scale))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
    }
}

/// Demo remote video: the DemoMedia sunset scene, looping (demo never
/// touches the network or the core video queues). Evidence shows one
/// fixed frame.
struct DemoRemoteVideo: View {
    let animated: Bool
    /// Every 4th clip frame, rendered once per process (12 small images).
    @MainActor static let frames: [CGImage] = stride(from: 0, to: DemoClip.frameCount, by: 4)
        .compactMap { DemoClip.frameImage($0) }

    var body: some View {
        if animated {
            TimelineView(.periodic(from: .now, by: 1.0 / 8)) { ctx in
                frame(Int(ctx.date.timeIntervalSinceReferenceDate * 8))
            }
        } else {
            frame(Self.frames.count / 2)
        }
    }

    @ViewBuilder
    private func frame(_ i: Int) -> some View {
        let all = Self.frames
        if !all.isEmpty {
            let n = all.count
            // Ping-pong so the sun arcs back instead of jumping.
            let k = i % (2 * n - 2 == 0 ? 1 : 2 * n - 2)
            Image(decorative: all[k < n ? k : 2 * n - 2 - k], scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

/// Demo self view: a placeholder feed (demo never opens the camera).
struct PlaceholderFeed: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.tint.opacity(0.18))
            VStack(spacing: 6) {
                Image(systemName: "person.crop.rectangle")
                    .font(.largeTitle)
                Text("Camera Preview")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Live self view: the capture session's preview layer. The layer is
/// created once per tile and moves with the stage (never recreated
/// during a call).
struct CameraPreview: NSViewRepresentable {
    let camera: CameraCapture

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: camera.session)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}
