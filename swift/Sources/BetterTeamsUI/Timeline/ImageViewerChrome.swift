// ImageViewerChrome.swift — the image viewer's media chrome, kept in one
// file so the ui-lint exceptions it needs cover nothing else (UI-SPEC R1,
// R7, R15): the dark window the image runs under the titlebar of, the HUD
// bar that floats over the image, and the GIF frame stepper.
import AppKit
import OstMacCore

@MainActor
enum ImageViewerChrome {
    /// Dark viewer window; the image runs up under a transparent titlebar
    /// like Quick Look (R1 exception: a media window, not the main window).
    static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true
        return w
    }

    /// HUD control bar over the image (R15 exception: a media overlay,
    /// the material AVKit's own playback controls use).
    static func makeBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }
}

/// Steps an animated GIF one frame at a time at the clip's own frame
/// delays (floored at `GifProbe.minFrameDuration`), looping. One one-shot
/// timer per frame (R7 exception: media playback, not a layout/focus wait).
@MainActor
final class GifFrameTicker {
    private var timer: Timer?
    private var frame = 0

    var isRunning: Bool { timer != nil }

    /// Starts at frame 0; `show` gets each following frame index.
    func start(_ clip: GifClip, show: @escaping @MainActor (Int) -> Void) {
        frame = 0
        schedule(clip, show: show)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(_ clip: GifClip, show: @escaping @MainActor (Int) -> Void) {
        let d = max(clip.durations[frame % clip.durations.count], GifProbe.minFrameDuration)
        timer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.frame = (self.frame + 1) % clip.frames.count
                show(self.frame)
                self.schedule(clip, show: show)
            }
        }
    }
}
