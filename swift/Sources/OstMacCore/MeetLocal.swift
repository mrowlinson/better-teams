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
    /// Blurred-background composite of one self-view frame. Nil when
    /// segmentation fails or finds too little person to cut out (the
    /// caller then shows the frame unblurred — never a full-frame blur
    /// mistaken for background blur).
    public static func blurredBackground(_ image: CGImage, radius: Double = 18) -> CGImage? {
        guard let mask = personMask(image), coverage(of: mask) >= Self.minPersonCoverage else { return nil }
        return composite(image, mask: mask, radius: radius)
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
        CIContext().render(out, toBitmap: &pixel, rowBytes: 4,
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
        return CIContext().createCGImage(out, from: extent)
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
