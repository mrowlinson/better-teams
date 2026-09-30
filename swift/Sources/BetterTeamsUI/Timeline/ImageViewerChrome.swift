// ImageViewerChrome.swift — the image viewer's media chrome, kept in one
// file so the ui-lint exceptions it needs cover nothing else (UI-SPEC R1,
// R7, R15): the dark window the image runs under the titlebar of, the HUD
// bar that floats over the image, and the GIF frame stepper.
import AppKit
import OstMacCore

@MainActor
enum ImageViewerChrome {
    /// Themed viewer window (follows the system appearance live); the
    /// transparent titlebar sits over the themed background, the image
    /// below it (R1 exception: a media window, not the main window).
    /// `make` builds the window (tests pass one that never goes on screen).
    static func makeWindow(_ make: (NSRect, NSWindow.StyleMask) -> NSWindow = {
        NSWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: true)
    }) -> NSWindow {
        let w = make(NSRect(x: 0, y: 0, width: 900, height: 640),
                     [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView])
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Palette.viewerBackgroundNS
        return w
    }

    /// Titlebar height the window adds around the image (sizing chrome).
    static var titlebarHeight: CGFloat {
        let r = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: r, styleMask: [.titled]).height - r.height
    }

    /// Control bar over the image (R15 exception: a media overlay). The
    /// popover material adapts to light/dark, unlike the always-dark HUD.
    static func makeBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .popover
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

/// Zoom slider <-> magnification (P16, f4576fc). Logarithmic between the
/// scroll view's min and max magnification, so each step is the same
/// zoom factor whatever the image size.
enum ImageViewerZoomSlider {
    /// 0...1 position of `magnification`.
    static func value(magnification: CGFloat, min lo: CGFloat, max hi: CGFloat) -> Double {
        guard lo > 0, hi > lo else { return 0 }
        let m = Swift.min(Swift.max(magnification, lo), hi)
        return Double(log(m / lo) / log(hi / lo))
    }

    /// Magnification at slider `value` (clamped to 0...1).
    static func magnification(value: Double, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard lo > 0, hi > lo else { return lo }
        let v = Swift.min(Swift.max(value, 0), 1)
        return lo * CGFloat(exp(v * Double(log(hi / lo))))
    }
}
