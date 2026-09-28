// AppCardAdvanced.swift — the app card's Advanced disclosure (UI-SPEC
// §7.2): crop Left/Top steppers, Measure, Reset and Unload from Memory for
// a Teams-hosted web app. Crops are the same per-app `FrameHost` store
// Settings ▸ Apps edits (`FrameChromeStyle.cropsKey`); Measure runs the
// `TeamsFrameMeasure` probe on the app's resident page and takes what it
// sees. Demo never measures (its settings defaults are in memory).
import OstMacCore
import SwiftUI

struct AppCardAdvanced: View {
    let id: FrameAppID
    let host: FrameHost
    let demo: Bool
    @State private var crop: TeamsFrameCrop
    @State private var resident: Bool
    @State private var measuring = false
    @State private var note: String?

    init(id: FrameAppID, host: FrameHost, demo: Bool) {
        self.id = id
        self.host = host
        self.demo = demo
        _crop = State(initialValue: host.crop(.app(id)))
        _resident = State(initialValue: host.page(.app(id))?.isResident ?? false)
    }

    private var key: FrameKey { .app(id) }

    var body: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Crop left: \(Int(crop.left)) pt", value: $crop.left, in: 0...400, step: 4)
                Stepper("Crop top: \(Int(crop.top)) pt", value: $crop.top, in: 0...400, step: 4)
                HStack(spacing: 8) {
                    Button("Measure") { measure() }
                        .disabled(demo || !resident || measuring)
                    Button("Reset") { crop = .none }
                        .disabled(crop == .none)
                    Button("Unload from Memory") { unload() }
                        .disabled(!resident)
                }
                Text(note ?? "A crop trims edges of Teams that stay visible in this app. Measure needs the app open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .onChange(of: crop) { _, c in save(c) }
        .onChange(of: id) { _, new in
            // Same card, another app: re-read its crop (the save guard
            // sees an unchanged value and writes nothing).
            crop = host.crop(.app(new))
            resident = host.page(.app(new))?.isResident ?? false
            note = nil
        }
    }

    private func save(_ c: TeamsFrameCrop) {
        guard host.crop(key) != c else { return }
        host.setCrop(c, for: key)
        FrameChromeStyle.saveCrops(host.crops, defaults: AppSettings.shared.defaults)
    }

    private func measure() {
        measuring = true
        note = nil
        Task { @MainActor in
            let seen = await host.measureChrome(key)
            measuring = false
            if let seen {
                crop = seen
                note = "Measured \(Int(seen.left)) pt left, \(Int(seen.top)) pt top."
            } else {
                note = "No Teams header or app bar is showing."
            }
        }
    }

    private func unload() {
        host.unload(key)
        resident = false
    }
}
