// App.swift — Better Teams executable entry (UI-SPEC §11.1).
//
// A shim only: arms the launch timeline, then hands the app to
// BetterTeamsUI's AppDelegate. Everything else lives in BetterTeamsUI
// (UI) and OstMacCore (logic, incl. the AppState composition root).
import AppKit
import BetterTeamsUI
import OstMacCore

@main
enum OstMacAppMain {
    @MainActor
    static func main() {
        ColdStart.arm() // top10-menubar: launch-timeline t0 (first line)
        let app = NSApplication.shared
        let delegate = AppDelegate(args: CommandLine.arguments)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
