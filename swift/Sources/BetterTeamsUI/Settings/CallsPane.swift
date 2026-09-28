// CallsPane.swift — Settings ▸ Calls (UI-SPEC §9.4, DL1): Show calls
// (radio group, default In Main Window; "Applies to your next call"),
// microphone / speaker / camera pickers, input level meter, camera
// preview and Test Call. The device part reuses the call's
// `CallDevices` (same pickers and meter as pre-join and the Devices
// popover); the pane owns its own instance (no call slot, so a speaker
// choice never reroutes a running call). Demo: fixed devices, a
// placeholder camera feed, no hardware, no stored preferences.
import OstMacCore
import SwiftUI

struct CallsSettingsPane: View {
    @Bindable var settings: CallSettings
    let devices: CallDevices
    let model: WindowModel?
    @State private var previewOn = false

    /// The pane's device model: live devices for a live account, the
    /// demo fixtures otherwise.
    @MainActor
    static func devices(_ m: WindowModel?) -> CallDevices {
        let live = m?.app != nil && m?.options.demo == false
        let d = CallDevices(live: live, store: nil, camera: live ? CameraCapture() : nil)
        d.load()
        return d
    }

    var body: some View {
        Form {
            Section {
                Picker("Show calls:", selection: $settings.presentation) {
                    ForEach(CallPresentation.allCases, id: \.rawValue) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Applies to your next call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Devices") {
                CallDevicesForm(devices: devices)
            }
            Section("Camera") {
                Toggle("Preview camera", isOn: $previewOn)
                CallTileView(tile: CallTile(id: "self", name: model?.ownDisplayName ?? "You", kind: .selfView,
                                            speaking: false, muted: false, cameraOn: previewOn),
                             camera: devices.capture)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: 240)
                    .frame(maxWidth: .infinity)
            }
            Section {
                LabeledContent("Test call") {
                    Button("Start Test Call") { startTestCall() }
                        .disabled(model?.app == nil || model?.call?.ended == false)
                }
            } footer: {
                Text("Calls an echo service so you can hear yourself and check your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { devices.setLevelWanted(true, by: .settings) }
        .onDisappear {
            devices.setLevelWanted(false, by: .settings)
            previewOn = false
        }
        .onChange(of: previewOn) { _, on in devices.setSettingsPreview(on) }
    }

    private func startTestCall() {
        guard let m = model else { return }
        CallsSection.testCall(m)
    }
}
