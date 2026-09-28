// PreJoinView.swift — the pre-join step (UI-SPEC §8): camera preview,
// mic level, device pickers, Mic and Camera toggles, Join Now (default
// button; Join with Video while the camera is on). The Mic/Camera toggles are the same state the toolbar's
// Mute and Camera items show before joining.
import OstMacCore
import SwiftUI

struct PreJoinView: View {
    let session: CallSession
    let status: String
    let canJoin: Bool
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        PaneAnchorLayout {
            VStack(spacing: 14) {
                Text(session.title)
                    .font(.title2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(status)
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                CallTileView(tile: preview, camera: session.camera)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: 400)
                HStack(spacing: 20) {
                    Toggle("Microphone", isOn: Binding(get: { session.preMicOn },
                                                       set: { if $0 != session.preMicOn { session.toggleMute() } }))
                    Toggle("Camera", isOn: Binding(get: { session.preCameraOn },
                                                   set: { if $0 != session.preCameraOn { session.toggleCamera() } }))
                }
                .toggleStyle(.switch)
                CallDevicesForm(devices: session.devices)
                    .frame(width: 400)
                Button(session.preCameraOn ? "Join with Video" : "Join Now") { session.joinNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canJoin)
            }
            .padding(24)
        }
    }

    private var preview: CallTile {
        CallTile(id: "self", name: model?.ownDisplayName ?? "You", kind: .selfView, speaking: false,
                 muted: !session.preMicOn, cameraOn: session.preCameraOn)
    }
}
