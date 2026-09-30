// CallDeviceTestSheet.swift — REGFIX-C R3: Test Speaker and Microphone
// (Settings ▸ Calls). A native grouped form in a sheet: pick the speaker
// and play a test tone; pick the microphone, watch its level, record 3 s
// and hear it played back. Results and the microphone-permission hint show
// under each test. The tests are disabled while a call is running (it owns
// the audio devices).
import OstMacCore
import SwiftUI

struct CallDeviceTestSheet: View {
    let devices: CallDevices
    let callActive: Bool
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Speaker", selection: Binding(get: { devices.speaker ?? "" },
                                                         set: { devices.selectSpeaker($0.isEmpty ? nil : $0) })) {
                        Text("System Default").tag("")
                        ForEach(devices.speakers, id: \.description) { Text($0).tag($0) }
                    }
                    LabeledContent("Test") {
                        Button("Play Test Sound") { devices.testSpeaker() }
                            .disabled(!devices.loaded || callActive || devices.speakerPhase == .running)
                    }
                    result(devices.speakerPhase, devices.speakerResult)
                } header: { Text("Speaker") }
                Section {
                    Picker("Microphone", selection: Binding(get: { devices.mic ?? "" },
                                                            set: { devices.selectMic($0.isEmpty ? nil : $0) })) {
                        if devices.mics.isEmpty { Text("No Microphone").tag("") }
                        ForEach(devices.mics, id: \.description) { Text($0).tag($0) }
                    }
                    LabeledContent("Input Level") {
                        Gauge(value: devices.levelLive ? devices.level : 0) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .frame(maxWidth: 160)
                            .accessibilityLabel(devices.levelLive ? "Input level" : "No input")
                    }
                    LabeledContent("Test") {
                        Button("Record and Play Back") { devices.testMicrophone() }
                            .disabled(!devices.loaded || callActive || devices.micPhase == .running)
                    }
                    result(devices.micPhase, devices.micResult)
                } header: { Text("Microphone") }
                if callActive {
                    Text("Tests are unavailable during a call.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420)
        .onAppear { devices.setLevelWanted(true, by: .settings) }
        .onDisappear { devices.setLevelWanted(false, by: .settings) }
    }

    @ViewBuilder
    private func result(_ phase: TestPhase, _ text: String) -> some View {
        HStack(spacing: 6) {
            if phase == .running { ProgressView().controlSize(.small) }
            Text(text)
                .font(.caption)
                .foregroundStyle(phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
