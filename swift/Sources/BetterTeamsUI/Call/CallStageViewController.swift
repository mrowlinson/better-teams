// CallStageViewController.swift — the call stage (UI-SPEC §8 shared
// parts): one per call, created by `CallSession`, attached by exactly
// one host at a time through `CallStageHostController` (main window's
// call section, or the call window). Detach never destroys; the stage
// is released with its session at call end.
//
// Body: the pre-join step for meetings (`PreJoinView`), then the stage:
// remote tiles, self view and share tile in `TileGridLayout`; audio
// tiles show avatars with speaking rings. Video: 1:1 is the remote video
// with a self-view picture-in-picture; group chats and meetings use the
// video tile grid (`MeetingVideoStage`). Controls live in the host's
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
            } else if let video = session.meetingVideo {
                MeetingVideoStage(session: session, video: video, status: status)
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

/// Demo remote video: a softly lit room with a person in it, gently
/// moving (demo never touches the network or the core video queues).
/// `seed` gives each participant their own room. Evidence shows one
/// fixed frame. Drawn in a `Canvas`, so it always takes exactly the
/// proposed size (never widens the stage).
struct DemoRemoteVideo: View {
    let animated: Bool
    var seed = 0

    var body: some View {
        if animated {
            TimelineView(.periodic(from: .now, by: 1.0 / 12)) { ctx in
                DemoCameraScene(seed: seed, time: ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            DemoCameraScene(seed: seed, time: 0)
        }
    }
}

private struct DemoCameraScene: View {
    let seed: Int
    let time: Double

    private static let rooms: [(wall: Color, floor: Color, top: Color)] = [
        (.teal, .indigo, .blue), (.orange, .brown, .red), (.gray, .blue, .indigo),
        (.mint, .green, .teal), (.pink, .purple, .indigo), (.yellow, .orange, .brown),
    ]

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            guard w > 0, h > 0 else { return }
            let room = Self.rooms[abs(seed) % Self.rooms.count]
            let left = seed % 2 == 0
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [room.wall.opacity(0.62), room.floor.opacity(0.42)]),
                                           startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            // Out-of-focus background: window light and a shelf.
            var back = ctx
            back.addFilter(.blur(radius: max(3, w / 55)))
            let window = CGRect(x: left ? w * 0.05 : w * 0.67, y: h * 0.08, width: w * 0.28, height: h * 0.5)
            back.fill(Path(roundedRect: window, cornerRadius: w * 0.012), with: .color(.white.opacity(0.3)))
            let shelf = CGRect(x: left ? w * 0.7 : w * 0.06, y: h * 0.34, width: w * 0.22, height: h * 0.045)
            back.fill(Path(roundedRect: shelf, cornerRadius: 2), with: .color(.black.opacity(0.3)))
            back.fill(Path(ellipseIn: CGRect(x: left ? w * 0.72 : w * 0.08, y: h * 0.22, width: w * 0.06,
                                             height: h * 0.12)), with: .color(room.top.opacity(0.55)))
            // The person, backlit, with a slight sway.
            let sway = sin(time * 0.8 + Double(seed)) * w * 0.006
            let bob = sin(time * 1.3 + Double(seed) * 0.7) * h * 0.004
            let cx = w * 0.5 + sway
            let torso = CGRect(x: cx - h * 0.4, y: h * 0.66 + bob, width: h * 0.8, height: h * 0.6)
            ctx.fill(Path(ellipseIn: torso),
                     with: .linearGradient(Gradient(colors: [room.top.opacity(0.85), .black.opacity(0.85)]),
                                           startPoint: CGPoint(x: cx, y: torso.minY),
                                           endPoint: CGPoint(x: cx, y: h)))
            let neck = CGRect(x: cx - h * 0.055, y: h * 0.52 + bob, width: h * 0.11, height: h * 0.18)
            ctx.fill(Path(roundedRect: neck, cornerRadius: h * 0.03), with: .color(.black.opacity(0.6)))
            let head = CGRect(x: cx - h * 0.125, y: h * 0.25 + bob, width: h * 0.25, height: h * 0.31)
            ctx.fill(Path(ellipseIn: head),
                     with: .radialGradient(Gradient(colors: [.brown.opacity(0.75), .black.opacity(0.8)]),
                                           center: CGPoint(x: head.midX + (left ? -1 : 1) * h * 0.04,
                                                           y: head.midY - h * 0.03),
                                           startRadius: 0, endRadius: h * 0.2))
        }
    }
}

/// Demo self view: a synthetic camera scene (demo never opens the camera).
struct PlaceholderFeed: View {
    var body: some View {
        DemoRemoteVideo(animated: false, seed: 3)
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
