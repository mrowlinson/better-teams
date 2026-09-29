// ImageViewerEvidence.swift — IMGWIN: `<route>?viewer=landscape|portrait`
// opens the image viewer on a demo fixture and captures it instead of the
// main window (window sizing + theme evidence). Demo/evidence only.
import AppKit
import OstMacCore

@MainActor
enum ImageViewerEvidence {
    private static var opened = false

    /// True when no viewer was asked for, or once it shows the full image.
    static func ready(_ wc: ShellWindowController, route: String?) -> Bool {
        guard wc.model.options.evidence,
              let kind = route.flatMap(Route.init(string:))?.query["viewer"] else { return true }
        let viewer = ImageViewerController.shared
        guard opened else {
            opened = true
            let portrait = kind == "portrait"
            let item = ImageViewerItem(url: portrait ? DemoMedia.photo3 : DemoMedia.photo1,
                                       messageID: "evidence", alt: portrait ? "Portrait" : "Landscape")
            viewer.show(nav: ImageViewerNav(items: [item], current: item), thumbs: Self.demoThumb, demo: true,
                        saver: { _, _, _, _, _ in })
            CallEvidence.focus(viewer.window, over: wc)
            return false
        }
        return viewer.evidenceLoaded
    }

    /// The bubble's thumbnail decode, as a timeline click supplies it.
    private static func demoThumb(_ item: ImageViewerItem) -> NSImage? {
        (try? DemoMedia.data(for: item.url)).flatMap(NSImage.init(data:))
    }
}
