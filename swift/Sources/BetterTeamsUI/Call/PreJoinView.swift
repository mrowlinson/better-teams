// PreJoinView.swift — the pre-join step (UI-SPEC §8): camera preview,
// mic level, device pickers, Mic and Camera toggles, Join Now (default
// button; Join with Video while the camera is on). The Mic/Camera toggles are the same state the toolbar's
// Mute and Camera items show before joining.
import AppKit
import ImageIO
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers

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
                CallTileView(tile: preview, camera: session.camera, blurred: session.selfBlur,
                                 effect: session.backgroundEffect,
                                 onToggleBlur: { session.toggleSelfBlur() },
                                 onBackgroundEffect: { session.setBackgroundEffect($0) })
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: 400)
                HStack(spacing: 20) {
                    Toggle("Microphone", isOn: Binding(get: { session.preMicOn },
                                                       set: { if $0 != session.preMicOn { session.toggleMute() } }))
                    Toggle("Camera", isOn: Binding(get: { session.preCameraOn },
                                                   set: { if $0 != session.preCameraOn { session.toggleCamera() } }))
                    Toggle("Blur Background", isOn: Binding(get: { session.selfBlur },
                                                            set: { if $0 != session.selfBlur { session.toggleSelfBlur() } }))
                }
                .toggleStyle(.switch)
                HStack(spacing: 12) {
                    Picker("Background", selection: Binding(get: { session.backgroundEffect.choice },
                                                            set: { setBackgroundChoice($0) })) {
                        Text("Off").tag(0)
                        Text("Blur").tag(1)
                        Text("Replace").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if session.backgroundEffect.choice == 2 {
                        if session.backgroundEffect == .custom {
                            Text("Custom")
                                .font(AppFont.subheadline(scale))
                                .foregroundStyle(.secondary)
                            Button("Clear") { session.setCustomBackground(nil) }
                        } else {
                            Picker("Room", selection: Binding(get: { session.backgroundEffect.gallery ?? .office },
                                                             set: { session.setBackgroundEffect(.replace($0)) })) {
                                ForEach(BuiltInBackground.allCases) { bg in Text(bg.title).tag(bg) }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            Button("Choose Custom…") { pickCustomImage() }
                        }
                    }
                }
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

    /// Segmented Off/Blur/Replace: Replace keeps the current gallery or
    /// custom choice, defaulting to the first gallery room.
    private func setBackgroundChoice(_ choice: Int) {
        switch choice {
        case 0: session.setBackgroundEffect(.off)
        case 1: session.setSelfBlur(true)
        default:
            if !session.backgroundEffect.isReplace {
                session.setBackgroundEffect(.replace(session.backgroundEffect.gallery ?? .office))
            }
        }
    }

    /// Custom background image (local file; never leaves the machine).
    /// A cancelled or unreadable pick leaves the effect untouched.
    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        session.setCustomBackground(img)
    }
}
