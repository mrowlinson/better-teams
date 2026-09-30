// GuardSupport — shared helpers for the REGFIX-B guard tests. Nothing here
// puts a window on screen. Helpers for demo models and AppKit view trees.
// (SwiftUI buttons are not inspectable there, see ChatSurfaceGuardTests).
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
enum GuardSupport {
    /// A demo AppState + its window model (no network, in-memory settings).
    /// The navigator is held weakly by the model: keep the tuple alive.
    static func demoModel() -> (app: AppState, model: WindowModel, nav: Navigator) {
        AppSettings.useDemoStorage()
        let app = AppState(args: ["--demo"])
        let model = WindowModel(graph: app, accountKey: "regfixb-guard", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        return (app, model, nav)
    }

    /// `root` and every view below it.
    static func subviews(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { subviews(of: $0) }
    }
}
