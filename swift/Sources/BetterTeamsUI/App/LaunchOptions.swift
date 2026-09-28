// LaunchOptions.swift — launch flags (UI-SPEC §11.4, §4).
//
//   --demo                 offline canned data (required for evidence)
//   --route <route>        apply a Route after launch (§11.3)
//   --appearance light|dark
//   --window-size 1280x820
//   --evidence             pinned clock, static highlights, READY line
//   --evidence-out <png>   in-process window snapshot after READY
//   --rail-size small|medium|large   (demo only) sidebar icon size
//   --dump-menus           print the validated menu bar after READY
//   --coldstart-quit       launch timeline, then exit (AppState)
// Core flags (--chat, --name, --say) are read by AppState.
import AppKit

public struct LaunchOptions: Sendable {
    public var demo = false
    public var evidence = false
    public var route: String?
    public var appearance: String?
    public var windowSize: NSSize?
    public var railSize: RailSize?
    public var snapshotPath: String?
    public var dumpMenus = false
    public var coldstartQuit = false

    public init(args: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        demo = args.contains("--demo")
        evidence = args.contains("--evidence")
        route = value("--route")
        appearance = value("--appearance")
        if let s = value("--window-size") {
            let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { windowSize = NSSize(width: p[0], height: p[1]) }
        }
        if demo { railSize = value("--rail-size").flatMap(RailSize.init(rawValue:)) }
        snapshotPath = value("--evidence-out")
        dumpMenus = args.contains("--dump-menus")
        coldstartQuit = args.contains("--coldstart-quit")
    }
}
