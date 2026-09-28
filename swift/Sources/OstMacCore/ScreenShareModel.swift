// ScreenShareModel.swift — P4 split: verbatim move from ScreenShare.swift.
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// ScreenCaptureKit owner: system picker -> SCStream -> preview + live send.
/// Main-actor published state; picker/stream callbacks hop from wherever
/// SCK invokes them. Never starts capture unless the user taps Share.
@MainActor
public final class ScreenShareModel: NSObject, ObservableObject {
    @Published public private(set) var session = ScreenShareSession()
    @Published public private(set) var permission: ScreenSharePermission = .unknown
    @Published public private(set) var preview: CGImage?
    /// Counters for Diagnostics only (never rendered in the tile).
    @Published public private(set) var framesCaptured = 0
    @Published public private(set) var framesSent = 0
    /// Live-send path (mirrors CameraCapture): VT-encode each frame and
    /// push NALs to the Rust send queue while a live call is up.
    @Published public private(set) var liveSend = false

    public var phase: ScreenSharePhase { session.phase }
    public var sourceLabel: String? {
        session.source.map(ScreenShareSummary.label)
    }

    private var stream: SCStream?
    private var sink: ShareFrameSink?
    private let queue = DispatchQueue(label: "dev.ostmac.screenshare")
    /// Queue-confined live-send state (mirrors CameraCapture's boxes).
    private nonisolated let liveBox = ShareEncoderBox()
    private nonisolated let liveFlag = ShareLiveFlag()

    override public init() {
        super.init()
        // top10-menubar: the app holds this lazily — a note here while
        // the launch log still shows zero proves the deferral held.
        ColdStart.noteMediaInit("screenshare.model")
        // --share-denied shot hook: seed + hold the denial state.
        if CommandLine.arguments.contains("--share-denied") {
            permission = .denied
        }
    }

    /// Refresh the cached permission (prompt-free; call on appear and
    /// after Settings trips). Preflight true recovers to authorized;
    /// false never sets denied by itself (see ScreenSharePermission).
    public func refreshPermission() {
        // --share-denied shot hook: the seeded denial holds — never
        // re-probed away, so the denied path renders on any box.
        if CommandLine.arguments.contains("--share-denied") {
            permission = .denied
            return
        }
        if ScreenShareAccess.granted() {
            permission = .authorized
        } else if permission == .authorized {
            permission = .unknown // revoked externally; next failure re-marks
        }
    }

    /// Enable/disable live-send encoding into the call's send queue.
    public func setLiveSend(_ on: Bool) {
        liveSend = on
        liveFlag.set(on)
        if !on { liveBox.reset() }
    }

    /// Share: refresh permission, then present the system source picker.
    /// Denial stays in-state with the Settings hint (never a bare error);
    /// the picker owns the first-run authorization prompt.
    public func start() {
        refreshPermission()
        guard permission != .denied else { return }
        guard session.beginPick() else { return }
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = config
        picker.isActive = true
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.present()
    }

    /// Stop sharing (live, or mid-bring-up — honored when the start lands).
    public func stop() {
        guard session.beginStop() else { return }
        guard let stream else {
            // Bring-up never built a stream (or already torn down).
            setLiveSend(false)
            sink = nil
            _ = session.didStop()
            return
        }
        Task {
            try? await stream.stopCapture()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.setLiveSend(false)
                self.stream = nil
                self.sink = nil
                _ = self.session.didStop()
            }
        }
    }

    // MARK: Picker results (main-actor; observer methods hop here)

    private func adoptPicked(filter: SCContentFilter) {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        guard session.didPick(Self.describe(filter: filter)) else { return }
        let sink = ShareFrameSink(owner: self, box: liveBox, flag: liveFlag)
        self.sink = sink
        Task { await bringUp(filter: filter, sink: sink) }
    }

    private func notePickCancelled() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        session.didCancelPick()
    }

    private func notePickerFailed(_ error: Error) {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        if !ScreenShareAccess.granted() {
            permission = .denied
            session.didFail("permission denied")
        } else {
            session.didFail(error.localizedDescription)
        }
    }

    // MARK: Stream bring-up / teardown (main-actor)

    private func bringUp(filter: SCContentFilter, sink: ShareFrameSink) async {
        let config = SCStreamConfiguration()
        config.width = 960
        config.height = 600
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            noteStartFailed(error)
            return
        }
        if session.phase == .starting {
            self.stream = stream
            _ = session.didStart()
        } else {
            // Stopped mid-bring-up: tear the just-started stream down.
            try? await stream.stopCapture()
            setLiveSend(false)
            self.sink = nil
            _ = session.didStop()
        }
    }

    private func noteStartFailed(_ error: Error) {
        setLiveSend(false)
        sink = nil
        if !ScreenShareAccess.granted() {
            permission = .denied
            session.didFail("permission denied")
        } else {
            session.didFail(error.localizedDescription)
        }
    }

    /// Stream died on its own (source closed, system interrupted): fail
    /// unless we are already stopping (expected) or idle (late callback).
    private func noteStreamDied(_ error: Error) {
        guard session.phase == .live else { return }
        setLiveSend(false)
        stream = nil
        sink = nil
        session.didFail("stream ended")
    }

    /// One publish tick: the latest preview + exact coalesced counters.
    fileprivate func noteFrame(image: CGImage, captured: Int, sent: Int) {
        preview = image
        framesCaptured += captured
        framesSent += sent
    }

    /// Filter -> pure source descriptor (style + content-rect size; SCK
    /// exposes no display/window names on the macOS 14 floor).
    static func describe(filter: SCContentFilter) -> ScreenShareSource {
        let kind: ScreenShareSource.Kind
        if filter.style == .window {
            kind = .window
        } else if filter.style == .application {
            kind = .app
        } else {
            kind = .display
        }
        let rect = filter.contentRect
        let dims = "\(Int(rect.width))×\(Int(rect.height))"
        return ScreenShareSource(id: "\(kind.rawValue)-\(dims)", kind: kind, name: dims)
    }
}

// MARK: - SCK callbacks (hop to main; never block the SCK queues)

extension ScreenShareModel: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in self?.notePickCancelled() }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in self?.adoptPicked(filter: filter) }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.notePickerFailed(error) }
    }
}

extension ScreenShareModel: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.noteStreamDied(error) }
    }
}

// MARK: - Frame sink (sample queue)

/// Queue-side SCK output: complete frames -> preview CGImage + optional
/// VT-encode + send-queue push. Publish hops to main via the weak owner.
private final class ShareFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private weak var owner: ScreenShareModel?
    private let box: ShareEncoderBox
    private let flag: ShareLiveFlag
    /// Publish coalescing (sample queue only — the queue is serial).
    private var lastPublishMs: UInt64?
    private var pendingCaptured = 0
    private var pendingSent = 0

    init(owner: ScreenShareModel, box: ShareEncoderBox, flag: ShareLiveFlag) {
        self.owner = owner
        self.box = box
        self.flag = flag
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[SCStreamFrameInfo.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete,
            let pixels = sampleBuffer.imageBuffer
        else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr,
              let image
        else { return }
        var sent = false
        if flag.get() {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else {
                note(image: image, sent: false)
                return
            }
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var packed = Data(count: width * height * 4)
            packed.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let dest = dst.baseAddress!
                for row in 0 ..< height {
                    memcpy(dest + row * width * 4, base + row * stride, width * 4)
                }
            }
            do {
                let nals = try box.encode(bgra: packed, width: width, height: height)
                _ = try RustCore.videoSendPush(nals: nals)
                sent = true
            } catch {
                // Transient: the frame still previews, the next one retries
                // (the engine falls back to black IDR when idle).
            }
        }
        note(image: image, sent: sent)
    }

    /// Count every frame; publish the latest preview at most 4Hz.
    private func note(image: CGImage, sent: Bool) {
        pendingCaptured += 1
        if sent { pendingSent += 1 }
        let now = SharePreviewGate.nowMs()
        guard SharePreviewGate.shouldPublish(nowMs: now, lastMs: lastPublishMs) else {
            return
        }
        lastPublishMs = now
        let captured = pendingCaptured
        let sentCount = pendingSent
        pendingCaptured = 0
        pendingSent = 0
        publish(image: image, captured: captured, sent: sentCount)
    }

    private func publish(image: CGImage, captured: Int, sent: Int) {
        Task { @MainActor [weak owner = self.owner] in
            owner?.noteFrame(image: image, captured: captured, sent: sent)
        }
    }
}

/// NSLock-guarded live-send flag (sample-queue use from a @MainActor class).
private final class ShareLiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }; value = on
    }
    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Queue-confined stream encoder: created lazily at first live frame,
/// recreated when capture dims change. Encode runs off the lock.
private final class ShareEncoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var encoder: H264StreamEncoder?
    private var dims = (0, 0)

    func encode(bgra: Data, width: Int, height: Int) throws -> [Data] {
        lock.lock()
        if encoder == nil || dims != (width, height) {
            encoder = H264StreamEncoder(width: width, height: height)
            dims = (width, height)
        }
        let enc = encoder
        lock.unlock()
        guard let enc else { throw H264EncodeError.session(-1) }
        return try enc.encode(bgra: bgra)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        encoder = nil
        dims = (0, 0)
    }
}
