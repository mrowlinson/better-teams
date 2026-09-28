// ComposeAttachments.swift — om-attach lane: composer attachments.
//
// Attach button (native NSOpenPanel) + send-with-upload through the existing
// files-upload path (RustCore.sharedUpload → ostmac_files_upload). Chat ids
// skip the team scan in core (files.rs upload_file_data routes on
// is_channel_id: channels resolve the team folder, chats go straight to the
// sender's OneDrive chat-files folder). Files over 4 MB stage as .tooLarge
// and ride core's resumable session path (om-i4-bigup); % polls the core
// gauge per in-flight file while its spinner runs.
//
//   let a = ComposeAttachmentsStore()
//   a.stage(urls: panel.urls)          // probe sizes, flag large files
//   await a.uploadPending(chatID: id)  // staged + large, in order
//
// Tests inject mock upload/size seams (same pattern as SharedFilesStore).
import AppKit
import Foundation
import Combine

/// Per-file composer state (pure, Equatable for tests).
public enum ComposeAttachmentState: Equatable, Sendable {
    /// Under the cap, ready to upload on Send.
    case staged
    /// Over the cap: rides core's resumable session path on Send.
    case tooLarge(actual: UInt64)
    /// Upload in flight (row shows a spinner; Send is disabled).
    case uploading
    /// Uploaded via the files-upload path (reference message posted).
    case uploaded
    /// Upload failed (core/network error); Retry re-arms to .staged.
    case failed(String)
}

/// One picked file in the composer.
public struct ComposeAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let size: UInt64
    public var state: ComposeAttachmentState

    public init(
        id: String = UUID().uuidString,
        path: String, name: String, size: UInt64,
        state: ComposeAttachmentState = .staged
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.size = size
        self.state = state
    }
}

/// Pure composer-attachment helpers (size flag + picker model).
public enum ComposeAttachments {
    /// Simple/session routing threshold, mirrors Rust MAX_SIMPLE_UPLOAD
    /// (files.rs). Core simple-PUTs at-or-under and resumable-uploads over.
    public static let maxUploadBytes: UInt64 = 4 * 1024 * 1024

    /// True when `size` exceeds the threshold (exactly 4 MB still takes
    /// the simple path: core sessions only `len > MAX_SIMPLE_UPLOAD`).
    public static func isTooLarge(size: UInt64) -> Bool {
        size > maxUploadBytes
    }

    /// Large-file note surfaced in the composer before upload.
    /// `"File is 5.2 MB; large files use resumable upload"`.
    public static func capMessage(actual: UInt64) -> String {
        "File is \(SharedFile.sizeLabel(actual)); large files use resumable upload"
    }

    /// Last path component (`/tmp/a b.pdf` → `a b.pdf`).
    public static func displayName(path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Pure picker model: one path + probed size → a staged (or
    /// large-flagged) attachment. The store's `stage` maps URLs through this.
    public static func staged(path: String, size: UInt64) -> ComposeAttachment {
        ComposeAttachment(
            path: path, name: displayName(path: path), size: size,
            state: isTooLarge(size: size) ? .tooLarge(actual: size) : .staged)
    }
}

@MainActor
public final class ComposeAttachmentsStore: ObservableObject {
    /// Same shape as the Shared tab uploader: (chatID, path) → uploaded file.
    public typealias UploadFetcher = SharedFilesStore.UploadFetcher
    /// File-size probe (bytes), nil when the file is unreadable (stages as 0 B).
    public typealias SizeProbe = @Sendable (String) -> UInt64?

    @Published public private(set) var attachments: [ComposeAttachment] = []
    /// True while `uploadPending` runs (composer shows progress, Send locks).
    @Published public private(set) var uploading = false
    /// Per-file 0...1 fraction while in flight (keyed by attachment id;
    /// entries clear on completion; spinner stays regardless).
    @Published public private(set) var uploadProgress: [String: Double] = [:]
    /// Last upload failure (composer banner). Size flags stay per-row.
    @Published public private(set) var error: String?

    private let uploadFetcher: UploadFetcher
    private let sizeProbe: SizeProbe
    private let progressFetcher: SharedFilesStore.ProgressFetcher

    /// Default size probe (FileManager; test seam overrides it).
    /// Public: Swift requires default-argument callees of a public init to be public.
    public nonisolated static let defaultSizeProbe: SizeProbe = { path in
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .uint64Value
    }

    public nonisolated init(
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe,
        progress: @escaping SharedFilesStore.ProgressFetcher = { try RustCore.sharedUploadProgress() }
    ) {
        self.uploadFetcher = upload
        self.sizeProbe = sizeProbe
        self.progressFetcher = progress
    }

    /// Stage native-picker URLs: probe sizes now, flag large files (.tooLarge
    /// rides the resumable session path on Send).
    public func stage(urls: [URL]) {
        stage(paths: urls.map(\.path))
    }

    /// Stage local paths (panel output or tests with an injected probe).
    public func stage(paths: [String]) {
        for path in paths {
            let size = sizeProbe(path) ?? 0
            attachments.append(ComposeAttachments.staged(path: path, size: size))
        }
    }

    /// Remove one row (any state except in-flight .uploading).
    public func remove(id: String) {
        attachments.removeAll { $0.id == id && $0.state != .uploading }
    }

    /// Drop every row and clear the banner.
    public func clear() {
        attachments.removeAll { $0.state != .uploading }
        if attachments.isEmpty { error = nil }
    }

    /// Drop uploaded rows after a send (failed/tooLarge stay for action).
    public func clearFinished() {
        attachments.removeAll { $0.state == .uploaded }
    }

    /// Dismiss the composer error banner.
    public func clearError() {
        error = nil
    }

    /// Re-arm a failed row to .staged for another Send. No-op otherwise.
    public func retry(id: String) {
        guard let i = attachments.firstIndex(where: { $0.id == id }),
              case .failed = attachments[i].state
        else { return }
        attachments[i].state = .staged
    }

    /// Rows ready to upload (standard-size, in pick order).
    public var staged: [ComposeAttachment] {
        attachments.filter { $0.state == .staged }
    }

    /// Rows Send will upload: staged + large-flagged, in pick order.
    public var pendingUploads: [ComposeAttachment] {
        attachments.filter { $0.state == .staged || Self.isLarge($0.state) }
    }

    /// True when Send has files to upload (enables Send with an empty draft).
    public var hasStaged: Bool {
        !pendingUploads.isEmpty
    }

    /// True for the large-file flag (resumable session path).
    static func isLarge(_ state: ComposeAttachmentState) -> Bool {
        if case .tooLarge = state { return true }
        return false
    }

    /// Upload every pending file via the existing files-upload path, in pick
    /// order (staged + large; core routes >4 MB through a resumable session),
    /// skipping .failed/.uploaded rows. Per-file `%` polls the core gauge
    /// while its spinner runs. Failures mark the row and set `error` but
    /// don't stop later files. Demo mode fabricates success without core.
    /// Returns the uploaded files (demo-fabricated or core-echoed).
    @discardableResult
    public func uploadPending(chatID: String, isDemo: Bool = false) async -> [SharedFile] {
        let pending = pendingUploads
        guard !pending.isEmpty, !uploading else { return [] }
        uploading = true
        defer { uploading = false }
        var done: [SharedFile] = []
        for item in pending {
            setState(id: item.id, .uploading)
            if isDemo {
                setState(id: item.id, .uploaded)
                done.append(SharedFile(
                    id: "demo-up-\(item.name)", name: item.name, size: item.size))
                continue
            }
            let poll = startProgressPoll(id: item.id)
            do {
                let fetcher = uploadFetcher
                let path = item.path
                let resp = try await Task.detached { try fetcher(chatID, path) }.value
                setState(id: item.id, .uploaded)
                done.append(resp.file)
            } catch {
                let msg = SharedFilesStore.message(for: error)
                setState(id: item.id, .failed(msg))
                self.error = msg
            }
            poll.cancel()
            uploadProgress.removeValue(forKey: item.id)
        }
        return done
    }

    /// Poll the core gauge every 200 ms until cancelled, recording the
    /// fraction under `id`. Throwers keep the last value.
    private func startProgressPoll(id: String) -> Task<Void, Never> {
        let fetcher = progressFetcher
        return Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }
                if let p = try? await Task.detached(operation: { try fetcher() }).value,
                   let frac = SharedFilesStore.progressFraction(uploaded: p.uploaded, total: p.total)
                {
                    self.uploadProgress[id] = frac
                }
            }
        }
    }

    private func setState(id: String, _ state: ComposeAttachmentState) {
        guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[i].state = state
    }
}
