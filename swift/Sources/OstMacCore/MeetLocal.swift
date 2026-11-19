// MeetLocal.swift — C2a local-only meeting controls (no signaling, no
// server writes): the meeting layout choice, own-video background blur
// (Vision person segmentation + Core Image, on-device), and the local
// live-captions log (on-device Speech fills it in live calls; demo and
// evidence seed it). All state is dumb value types so guard tests drive
// them without a call; `CallSession` owns the live instances.
import AVFoundation
import CoreImage
import Foundation
import Speech
import Vision

/// The meeting stage layout (§8 grid/spotlight). Automatic keeps the
/// current behavior: the pinned person or a share takes the spotlight,
/// otherwise the grid.
public enum MeetingLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case grid
    case spotlight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .grid: "Grid"
        case .spotlight: "Spotlight"
        }
    }

    /// True = spotlight (first tile large, the rest in a strip).
    public func resolve(pinnedID: String?, shareUp: Bool, demoPresenting: Bool) -> Bool {
        switch self {
        case .grid: false
        case .spotlight: true
        case .automatic: pinnedID != nil || shareUp || demoPresenting
        }
    }
}

/// One live-captions line.
public struct LiveCaptionLine: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool = true) {
        id = UUID()
        self.text = text
        self.isFinal = isFinal
    }
}

/// The local captions buffer: newest at the end, capped so a long
/// meeting cannot grow it without bound. Empty and whitespace-only
/// lines never enter.
public struct LiveCaptionsLog: Equatable, Sendable {
    /// Lines kept (about a meeting hour of speech).
    public static let maxLines = 50
    /// Lines the overlay shows (the newest few).
    public static let shownLines = 3

    public private(set) var lines: [LiveCaptionLine] = []

    public init() {}

    public init(lines: [LiveCaptionLine]) {
        self.lines = Array(lines.suffix(Self.maxLines))
    }

    public mutating func append(_ text: String, isFinal: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lines.append(LiveCaptionLine(text: t, isFinal: isFinal))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    public mutating func clear() { lines.removeAll() }

    /// What the overlay shows: the newest lines.
    public var recent: [LiveCaptionLine] { Array(lines.suffix(Self.shownLines)) }
}

/// Own-video background blur: Vision person segmentation finds the
/// speaker, Core Image blurs everything else. Fully on-device (no
/// network; `.balanced` accuracy for a live preview budget). Nil when
/// segmentation fails — the caller shows the frame unblurred.
public enum PersonBackgroundBlur {
    /// Shared render context: one per process, never one per frame (the
    /// live preview runs this path ~6/s; a fresh context per frame
    /// regresses allocation + shader-compile behavior).
    static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    /// Blurred-background composite of one self-view frame. Nil when
    /// segmentation fails or finds too little person to cut out (the
    /// caller then shows the frame unblurred — never a full-frame blur
    /// mistaken for background blur).
    public static func blurredBackground(_ image: CGImage, radius: Double = 18) -> CGImage? {
        guard let mask = personMask(image), coverage(of: mask) >= Self.minPersonCoverage else { return nil }
        return composite(image, mask: mask, radius: radius)
    }

    /// Replaced-background composite of one self-view frame: the sharp
    /// person over `background`, cut by the same coverage-gated mask.
    /// Nil under the same conditions as `blurredBackground`.
    public static func replacedBackground(_ image: CGImage, background: CGImage) -> CGImage? {
        guard let mask = personMask(image), coverage(of: mask) >= Self.minPersonCoverage else { return nil }
        return compositeReplace(image, mask: mask, background: background)
    }

    /// Minimum person fraction for a usable cutout.
    static let minPersonCoverage = 0.02

    /// Mean mask value (0…1) via CIAreaAverage. Internal for tests.
    static func coverage(of mask: CIImage) -> Double {
        guard let avg = CIFilter(name: "CIAreaAverage") else { return 0 }
        avg.setValue(mask, forKey: kCIInputImageKey)
        avg.setValue(CIVector(cgRect: mask.extent), forKey: "inputExtent")
        guard let out = avg.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        sharedContext.render(out, toBitmap: &pixel, rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Double(pixel[0]) / 255
    }

    /// The person's soft mask (nil: no person found). Internal for tests.
    static func personMask(_ image: CGImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let extent = CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height))
        let sx = extent.width / max(1, mask.extent.width)
        let sy = extent.height / max(1, mask.extent.height)
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Sharp frame over a blurred background, cut by `mask` (white =
    /// the person). Internal for tests with synthetic masks.
    static func composite(_ image: CGImage, mask: CIImage, radius: Double) -> CGImage? {
        let frame = CIImage(cgImage: image)
        let extent = frame.extent
        let blurred = frame.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0, radius))
            .cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(frame, forKey: kCIInputImageKey)
        filter.setValue(blurred, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let out = filter.outputImage else { return nil }
        return sharedContext.createCGImage(out, from: extent)
    }

    /// Sharp frame over `background` (scaled to fill, centered), cut by
    /// `mask` (white = the person). Internal for tests with synthetic
    /// masks; the live preview uses this after its own Vision pass.
    static func compositeReplace(_ image: CGImage, mask: CIImage, background: CGImage) -> CGImage? {
        let frame = CIImage(cgImage: image)
        let extent = frame.extent
        let bg = CIImage(cgImage: background)
        let bw = max(1, bg.extent.width), bh = max(1, bg.extent.height)
        let s = max(extent.width / bw, extent.height / bh)
        let dx = (extent.width - bw * s) / 2, dy = (extent.height - bh * s) / 2
        let filled = bg.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: dx, y: dy)))
            .cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(frame, forKey: kCIInputImageKey)
        filter.setValue(filled, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let out = filter.outputImage else { return nil }
        return sharedContext.createCGImage(out, from: extent)
    }

    /// Procedural gallery image for `bg` (deterministic, no assets — the
    /// same palette the demo scene draws). Internal for tests, demo, and
    /// the live preview's replace path.
    static func backgroundImage(for bg: BuiltInBackground, size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let p = bg.palette
        // Vertical gradient wall→floor.
        for y in 0 ..< h {
            let t = Double(y) / Double(max(1, h - 1))
            let r = p.wall.0 + (p.floor.0 - p.wall.0) * t
            let g = p.wall.1 + (p.floor.1 - p.wall.1) * t
            let b = p.wall.2 + (p.floor.2 - p.wall.2) * t
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
        }
        // Soft window light + shelf, centered like the demo room.
        let fw = Double(w), fh = Double(h)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
        ctx.fillEllipse(in: CGRect(x: fw * 0.12, y: fh * 0.12, width: fw * 0.24, height: fh * 0.34))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.fill(CGRect(x: fw * 0.64, y: fh * 0.36, width: fw * 0.24, height: fh * 0.05))
        ctx.setFillColor(CGColor(red: p.accent.0, green: p.accent.1, blue: p.accent.2, alpha: 0.55))
        ctx.fillEllipse(in: CGRect(x: fw * 0.66, y: fh * 0.22, width: fw * 0.07, height: fh * 0.13))
        return ctx.makeImage()
    }

    /// Solid flat image (evidence/demo "custom" stand-in).
    public static func solidImage(red: Double, green: Double, blue: Double, size: Int = 64) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }
}

/// Built-in replacement backgrounds: procedural rooms drawn on-device
/// (no assets, no network). The demo scene and the live preview share
/// these palettes so captures match what the camera path composites.
public enum BuiltInBackground: String, CaseIterable, Identifiable, Sendable {
    case office
    case cove
    case dune
    case atrium

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .office: "Office"
        case .cove: "Cove"
        case .dune: "Dune"
        case .atrium: "Atrium"
        }
    }

    /// (wall, floor, accent) in 0…1 RGB, shared by the gallery renderer
    /// and the demo scene.
    public var palette: (wall: (Double, Double, Double), floor: (Double, Double, Double), accent: (Double, Double, Double)) {
        switch self {
        case .office: ((0.32, 0.52, 0.62), (0.22, 0.30, 0.48), (0.30, 0.45, 0.90))
        case .cove: ((0.16, 0.42, 0.44), (0.14, 0.32, 0.30), (0.35, 0.80, 0.72))
        case .dune: ((0.72, 0.55, 0.34), (0.48, 0.32, 0.18), (0.85, 0.45, 0.20))
        case .atrium: ((0.52, 0.36, 0.60), (0.30, 0.22, 0.42), (0.75, 0.55, 0.95))
        }
    }
}

/// Local self-view background effect (no signaling, no server writes).
/// `.off` shows the raw camera frame; every other case hides the real
/// room behind blur, a gallery room, or a chosen image.
public enum BackgroundEffect: Equatable, Sendable {
    case off
    case blur
    case replace(BuiltInBackground)
    case custom

    /// True for blur, replace, and custom (the room is hidden).
    public var isOn: Bool { self != .off }

    /// True for replace and custom (the room is swapped, not softened).
    public var isReplace: Bool {
        switch self {
        case .replace, .custom: true
        case .off, .blur: false
        }
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .blur: "Blur"
        case .replace(let bg): bg.title
        case .custom: "Custom"
        }
    }

    /// Segmented-control slot (Off/Blur/Replace); the gallery/custom
    /// choice lives alongside, never inside the three-way control.
    public var choice: Int {
        switch self {
        case .off: 0
        case .blur: 1
        case .replace, .custom: 2
        }
    }

    /// Gallery room when this is `.replace`.
    public var gallery: BuiltInBackground? {
        if case .replace(let bg) = self { return bg }
        return nil
    }
}

// MARK: - live engine (mic only, never in tests/demo)

/// On-device live captions: mic audio through `SFSpeechRecognizer`
/// with `requiresOnDeviceRecognition` (nothing leaves the machine).
/// Partial results arrive as non-final lines; each final result
/// replaces its partials. Main actor; construct in live calls only.
@MainActor
public final class LiveCaptionsEngine: NSObject {
    /// (text, isFinal).
    public var onLine: ((String, Bool) -> Void)?
    public private(set) var running = false

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audio = AVAudioEngine()

    /// True when the recognizer can run fully on-device.
    public static func available() -> Bool {
        let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        return r?.supportsOnDeviceRecognition == true
    }

    /// Starts recognition (mic). No-op while already running or when
    /// on-device recognition is unavailable.
    public func start() {
        guard !running, Self.available() else { return }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            stop()
            return
        }
        running = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor [weak self] in
                self?.onLine?(result.bestTranscription.formattedString, result.isFinal)
            }
        }
    }

    /// Stops recognition and releases the mic tap.
    public func stop() {
        guard running || task != nil else { return }
        running = false
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
