// ImageViewer.swift — IMGVIEW: full-resolution image viewer (Teams-style).
//
// Opens instantly on the bubble thumbnail (scaled up as a placeholder),
// fetches the original through FullResImageModel (AMS `imgo`, Graph
// drive `/content`, cached by RichMediaCache) with a small progress
// pill, and swaps it into the same frame without a flash. Pinch,
// ⌘+ / ⌘− / ⌘0 (actual) / ⌘9 (fit), double-click, drag to pan;
// ←/→ step through the chat's images; Esc closes. Save / Copy / Share
// use the original bytes; the on-screen decode is capped to the screen
// so huge images stay memory-safe. Animated GIFs play.
import AppKit
import Combine
import OstMacCore
import UniformTypeIdentifiers

@MainActor
final class ImageViewerController: NSWindowController, NSWindowDelegate {
    static let shared = ImageViewerController(viewerWindow: ImageViewerChrome.makeWindow())

    /// Thumbnail (bubble decode) for an item, if already loaded.
    typealias ThumbProvider = @MainActor (ImageViewerItem) -> NSImage?
    /// Saves original bytes (Downloads when `choose` is false).
    typealias Saver = @MainActor (Data, UTType?, String, Bool, NSWindow) -> Void

    private var nav: ImageViewerNav?
    private var thumbs: ThumbProvider = { _ in nil }
    private var saver: Saver?
    private var fetcher: RichMediaCache.Fetcher?
    /// One model per item for this session (←/→ back is instant).
    private var models: [ImageViewerItem: FullResImageModel] = [:]
    private var watch: AnyCancellable?
    /// Size the current document frame was laid out for (image points).
    private var docSize: CGSize = .zero
    /// Which image the doc frame shows (thumb vs full) — swap detection.
    private var shownFull = false
    private var userZoomed = false
    private let gif = GifFrameTicker()
    /// Bumped per open: a stale pre-show size lookup never orders in.
    private var openID = 0
    /// Byte cache the models read (tests inject an isolated one).
    var cache: RichMediaCache = .shared

    private let scroll = NSScrollView()
    private let imageView = ViewerImageView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let position = NSTextField(labelWithString: "")
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var actionButtons: [NSButton] = []

    /// `shared` in the app; tests pass a window that never goes on screen.
    init(viewerWindow w: NSWindow) {
        // Themed (no forced appearance): follows light/dark live.
        w.minSize = NSSize(width: 480, height: 240)
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        // IMGWIN2: appears at its final frame — no open zoom, no
        // restored/cascaded frame.
        w.animationBehavior = .none
        w.isRestorable = false
        super.init(window: w)
        shouldCascadeWindows = false
        w.delegate = self
        build(w)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Evidence: the current image's original has loaded.
    var evidenceLoaded: Bool {
        guard let nav, let m = models[nav.current], case .loaded = m.phase else { return false }
        return true
    }

    // MARK: - Open

    func show(nav: ImageViewerNav, thumbs: @escaping ThumbProvider, demo: Bool, saver: @escaping Saver) {
        self.nav = nav
        self.thumbs = thumbs
        self.saver = saver
        fetcher = demo ? { @Sendable url in try DemoMedia.data(for: url) } : nil
        models = [:]
        openID += 1
        guard let w = window else { return }
        // Already open: the frame stays; the new image letterboxes in it.
        if w.isVisible {
            present(resetZoom: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        // IMGWIN2: the final frame is set BEFORE ordering in and never
        // changes while on screen. Size source: the cached original's
        // header, else the tag's width/height, else the thumbnail aspect.
        let id = openID
        let item = nav.current
        let m = model(item)
        let screen = (NSApp.mainWindow ?? NSApp.keyWindow)?.screen ?? NSScreen.main
        Task { [weak self] in
            var cached = await m.cachedPixelSize()
            // FIXPACK F7: uncached and no tag size: read the header bytes
            // (range GET, 300 ms cap) so it opens at its exact fitted size.
            if ImageViewerOpenSize.needsHeader(cached: cached, metadata: item.pixelSize) {
                cached = await m.headPixelSize()
            }
            guard let self, self.openID == id, !w.isVisible else { return }
            let natural = ImageViewerOpenSize.natural(cached: cached, metadata: item.pixelSize, thumb: m.thumb?.size)
            self.place(w, natural: natural, on: screen)
            self.present(resetZoom: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView)
        }
    }

    /// Final frame for `natural` (40% budget, chrome included), centered
    /// on `screen`; set while hidden and laid out before ordering in.
    private func place(_ w: NSWindow, natural: CGSize, on screen: NSScreen?) {
        guard let vis = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = ImageViewerWindowFit.windowSize(
            image: natural, chrome: CGSize(width: 0, height: ImageViewerChrome.titlebarHeight),
            minimum: w.minSize, screen: vis.size)
        w.setFrame(ImageViewerWindowFit.centered(size, in: vis), display: false)
        w.contentView?.layoutSubtreeIfNeeded()
    }

    private func model(_ item: ImageViewerItem) -> FullResImageModel {
        if let m = models[item] { return m }
        let m = FullResImageModel(thumbURL: item.url, messageID: item.messageID, thumb: thumbs(item),
                                  cache: cache, fetcher: fetcher, maxPixels: Self.displayMaxPixels(window?.screen))
        models[item] = m
        return m
    }

    /// Screen-sized decode cap: the longest screen side in pixels,
    /// clamped to 2048…4096 (a 50 MP photo never decodes at full size).
    static func displayMaxPixels(_ screen: NSScreen?) -> CGFloat {
        guard let s = screen ?? NSScreen.main else { return ImageDecode.viewerMaxPixels }
        let px = max(s.frame.width, s.frame.height) * s.backingScaleFactor
        return min(max(px, ImageDecode.viewerMaxPixels), 4096)
    }

    private func present(resetZoom: Bool) {
        guard let nav else { return }
        let m = model(nav.current)
        watch = m.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(swap: true) }
        m.load()
        shownFull = false
        docSize = .zero
        if resetZoom { userZoomed = false }
        window?.title = nav.current.alt.isEmpty ? "Image" : nav.current.alt
        refresh(swap: false)
        // Warm the neighbours so ←/→ lands on the full image.
        for d in [-1, 1] {
            var n = nav
            if n.move(by: d) { model(n.current).load() }
        }
    }

    // MARK: - State → view

    private func refresh(swap: Bool) {
        guard let nav, let m = models[nav.current] else { return }
        let full = m.image != nil
        // The window frame never follows the image (IMGWIN2): a new
        // size/aspect letterboxes at fit inside the open frame.
        if let img = m.displayImage, docSize == .zero || full != shownFull {
            layoutImage(img, model: m, isFull: full)
        }
        startGif(full ? m.gif : nil, still: m.displayImage)
        switch m.phase {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            status.stringValue = "Loading full resolution\u{2026}"
            status.isHidden = false
            retry.isHidden = true
        case .loaded:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            status.isHidden = true
            retry.isHidden = true
        case .failed:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            status.stringValue = m.thumb == nil
                ? "The image couldn\u{2019}t be loaded."
                : "Couldn\u{2019}t load the full image \u{2014} showing a preview."
            status.isHidden = false
            retry.isHidden = false
        }
        position.stringValue = nav.position ?? ""
        prevButton.isEnabled = nav.canPrevious
        nextButton.isEnabled = nav.canNext
        let hasOriginal = m.originalData != nil
        for b in actionButtons { b.isEnabled = hasOriginal }
    }

    /// Puts `img` in the document frame. Placeholder → full keeps the
    /// on-screen size (re-fit when untouched, else scale-compensated) so
    /// the swap happens in place.
    private func layoutImage(_ img: NSImage, model m: FullResImageModel, isFull: Bool) {
        let old = docSize
        let oldMag = scroll.magnification
        let clip = scroll.contentView
        let oldCenter = old == .zero ? .zero
            : CGPoint(x: clip.bounds.midX / old.width, y: clip.bounds.midY / old.height)
        imageView.image = img
        docSize = img.size
        shownFull = isFull
        imageView.frame = NSRect(origin: .zero, size: img.size)
        let (fit, actual) = zoomBounds()
        scroll.minMagnification = ImageViewerZoom.minimum(fit: fit)
        scroll.maxMagnification = ImageViewerZoom.maximum(actual: actual)
        if old == .zero || !userZoomed {
            scroll.magnification = fit
            return
        }
        let mag = oldMag * old.width / max(img.size.width, 1)
        scroll.setMagnification(mag, centeredAt: CGPoint(x: oldCenter.x * img.size.width,
                                                          y: oldCenter.y * img.size.height))
    }

    /// Re-fits the magnification to the current viewport (untouched zoom).
    private func refit() {
        guard !userZoomed, docSize != .zero else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let (fit, _) = zoomBounds()
        scroll.minMagnification = min(scroll.minMagnification, fit)
        scroll.magnification = fit
    }

    /// (fit, actual) for the current document. A placeholder thumbnail
    /// under the bubble cap is the whole image (natural size cap); a
    /// capped thumbnail stands in for a larger original (fit only).
    private func zoomBounds() -> (CGFloat, CGFloat) {
        guard let nav, let m = models[nav.current] else { return (1, 1) }
        let viewport = scroll.contentSize
        let pixels: CGSize?
        if shownFull {
            pixels = m.pixelSize
        } else if max(docSize.width, docSize.height) < ImageDecode.bubbleMaxPixels - 1 {
            pixels = docSize
        } else {
            pixels = CGSize(width: docSize.width * 100, height: docSize.height * 100)
        }
        let actual = ImageViewerZoom.actual(imageSize: docSize, pixelSize: pixels)
        return (ImageViewerZoom.fit(imageSize: docSize, viewport: viewport, pixelSize: pixels), actual)
    }

    private func startGif(_ clip: GifClip?, still: NSImage?) {
        guard let clip, clip.frames.count > 1 else {
            gif.stop()
            return
        }
        guard !gif.isRunning else { return }
        gif.start(clip) { [weak self] i in self?.imageView.image = clip.frames[i] }
    }

    // MARK: - Actions

    @objc func previous(_ sender: Any?) { step(-1) }
    @objc func next(_ sender: Any?) { step(1) }

    private func step(_ d: Int) {
        guard var n = nav, n.move(by: d) else { return }
        nav = n
        gif.stop()
        present(resetZoom: true)
    }

    @objc func zoomIn(_ sender: Any?) { zoom { ImageViewerZoom.zoomIn($0, fit: $1, actual: $2) } }
    @objc func zoomOut(_ sender: Any?) { zoom { ImageViewerZoom.zoomOut($0, fit: $1, actual: $2) } }
    @objc func zoomToFit(_ sender: Any?) { zoom { _, fit, _ in fit } }
    @objc func actualSize(_ sender: Any?) { zoom { _, _, actual in actual } }

    func toggleZoom(at p: CGPoint) {
        let (fit, actual) = zoomBounds()
        let target = ImageViewerZoom.toggle(scroll.magnification, fit: fit, actual: actual)
        userZoomed = abs(target - fit) > 0.001
        scroll.animator().setMagnification(target, centeredAt: p)
    }

    private func zoom(_ f: (CGFloat, CGFloat, CGFloat) -> CGFloat) {
        let (fit, actual) = zoomBounds()
        let target = f(scroll.magnification, fit, actual)
        userZoomed = abs(target - fit) > 0.001
        let c = scroll.contentView.bounds
        scroll.animator().setMagnification(target, centeredAt: CGPoint(x: c.midX, y: c.midY))
    }

    @objc func retryLoad(_ sender: Any?) {
        guard let nav, let m = models[nav.current] else { return }
        Task { await m.reload() }
    }

    private var current: (FullResImageModel, Data, ImageViewerItem)? {
        guard let nav, let m = models[nav.current], let d = m.originalData else { return nil }
        return (m, d, nav.current)
    }

    @objc func download(_ sender: Any?) { save(choose: false) }
    @objc func saveAs(_ sender: Any?) { save(choose: true) }

    private func save(choose: Bool) {
        guard let cur = current, let w = window else { return }
        let (m, data, item) = cur
        saver?(data, m.originalType, item.alt, choose, w)
    }

    @objc func copyImage(_ sender: Any?) {
        guard let cur = current else { return }
        let (m, data, _) = cur
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = m.originalType {
            pb.setData(data, forType: NSPasteboard.PasteboardType(t.identifier))
        }
        if let tiff = m.image?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    @objc func share(_ sender: Any?) {
        guard let cur = current, let button = sender as? NSView else { return }
        let (m, data, item) = cur
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeams-Viewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ImageSave.filename(alt: item.alt, ext: m.originalType?.preferredFilenameExtension ?? "png")
        let dest = dir.appendingPathComponent(name)
        guard (try? data.write(to: dest)) != nil else { return }
        NSSharingServicePicker(items: [dest]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        gif.stop()
        watch = nil
        models = [:]
        nav = nil
        imageView.image = nil
        docSize = .zero
        openID += 1
    }

    func windowDidResize(_ notification: Notification) { refit() }

    @objc private func didEndPinch(_ n: Notification) {
        let (fit, _) = zoomBounds()
        userZoomed = abs(scroll.magnification - fit) > 0.001
    }

    // MARK: - Build

    private func build(_ w: NSWindow) {
        let root = ViewerRootView()
        root.controller = self
        w.contentView = root

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.unregisterDraggedTypes()
        imageView.controller = self
        imageView.setAccessibilityLabel("Image")
        NotificationCenter.default.addObserver(self, selector: #selector(didEndPinch(_:)),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        let bar = ImageViewerChrome.makeBar()

        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                             target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = label
            b.setAccessibilityLabel(label)
            return b
        }
        prevButton = button("chevron.left", "Previous Image", #selector(previous(_:)))
        nextButton = button("chevron.right", "Next Image", #selector(next(_:)))
        let zoomOutB = button("minus.magnifyingglass", "Zoom Out", #selector(zoomOut(_:)))
        let zoomInB = button("plus.magnifyingglass", "Zoom In", #selector(zoomIn(_:)))
        let fitB = button("arrow.down.right.and.arrow.up.left", "Zoom to Fit", #selector(zoomToFit(_:)))
        let actualB = button("1.magnifyingglass", "Actual Size", #selector(actualSize(_:)))
        let saveB = button("arrow.down.circle", "Save to Downloads", #selector(download(_:)))
        let copyB = button("doc.on.doc", "Copy Image", #selector(copyImage(_:)))
        let shareB = button("square.and.arrow.up", "Share", #selector(share(_:)))
        actionButtons = [saveB, copyB, shareB]

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        position.textColor = .secondaryLabelColor
        position.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        retry.target = self
        retry.action = #selector(retryLoad(_:))
        retry.bezelStyle = .push
        retry.controlSize = .small
        retry.isHidden = true

        func sep() -> NSView {
            let v = NSBox()
            v.boxType = .separator
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            return v
        }
        let stack = NSStackView(views: [prevButton, position, nextButton, sep(), zoomOutB, zoomInB, fitB, actualB,
                                        sep(), saveB, copyB, shareB, sep(), spinner, status, retry])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        root.addSubview(scroll)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Below the titlebar: the chrome is part of the window size.
            scroll.topAnchor.constraint(equalTo: (w.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            bar.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -28),
        ])
    }
}

/// Keys: Esc closes, ←/→ step, ⌘+/⌘=/⌘− zoom, ⌘0 actual, ⌘9 fit,
/// ⌘C copy, ⌘S Save As….
private final class ViewerRootView: NSView {
    weak var controller: ImageViewerController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return super.keyDown(with: e) }
        switch e.keyCode {
        case 53: window?.performClose(nil)
        case 123: c.previous(nil)
        case 124: c.next(nil)
        default: super.keyDown(with: e)
        }
    }

    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard let c = controller,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad]) == .command,
              let k = e.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: e) }
        switch k {
        case "+", "=": c.zoomIn(nil)
        case "-", "_": c.zoomOut(nil)
        case "0": c.actualSize(nil)
        case "9": c.zoomToFit(nil)
        case "c": c.copyImage(nil)
        case "s": c.saveAs(nil)
        case "w": window?.performClose(nil)
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }
}

/// Image document: double-click toggles fit/actual, drag pans.
private final class ViewerImageView: NSImageView {
    weak var controller: ImageViewerController?

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            controller?.toggleZoom(at: convert(e.locationInWindow, from: nil))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = enclosingScrollView else { return }
        let clip = s.contentView
        var o = clip.bounds.origin
        o.x -= e.deltaX / s.magnification
        o.y += e.deltaY / s.magnification
        let r = clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size))
        clip.scroll(to: r.origin)
        s.reflectScrolledClipView(clip)
    }
}

/// Keeps a smaller-than-viewport image centered.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}
