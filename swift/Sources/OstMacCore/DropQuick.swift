// DropQuick.swift — om-iu-dropquick lane: file drops + QuickLook preview.
//
// Drops: Finder files land on the composer (staged via the existing
// ComposeAttachmentsStore.stage path, cap gate included) and on the Shared
// tab (uploaded via SharedFilesStore.upload(paths:), queued in drop order).
// Both targets resolve NSItemProviders through FileDrop.resolve and show a
// drop highlight while targeted (isTargeted → accent outline).
//
// Preview: QuickLookPreview shows the standard QLPreviewPanel for SAVED
// files (the Save-first flow: Shared tab Save → ~/Downloads → Preview
// button). Unsaved/remote rows never preview — no bytes, no panel.
//
//   FileDrop.resolve(providers: p) { store.upload(paths: $0) }
//   QuickLookPreview.shared.preview(paths: [saved])
import AppKit
import Quartz
import Combine
import UniformTypeIdentifiers

/// Pure file-drop helpers + NSItemProvider resolution.
public enum FileDrop {
    /// Accepted drop types: local file URLs only (Finder drags).
    public static var dropTypes: [UTType] { [.fileURL] }

    /// File URLs → local paths, dropping non-file URLs (pure, testable).
    public static func localPaths(from urls: [URL]) -> [String] {
        urls.filter(\.isFileURL).map(\.path)
    }

    /// Resolve onDrop providers to local file paths (order-preserving),
    /// then deliver on the main actor. Non-file items resolve to nothing.
    @MainActor
    public static func resolve(
        providers: [NSItemProvider],
        deliver: @escaping ([String]) -> Void
    ) {
        var paths: [String?] = Array(repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item, _ in
                defer { group.leave() }
                paths[index] = Self.path(from: item)
            }
        }
        group.notify(queue: .main) {
            deliver(paths.compactMap { $0 })
        }
    }

    /// One loaded item → local path. file-url items arrive as Data (URL
    /// bytes), NSURL, or String depending on the drag source.
    static func path(from item: NSSecureCoding?) -> String? {
        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil),
           url.isFileURL
        {
            return url.path
        }
        if let url = item as? URL, url.isFileURL {
            return url.path
        }
        if let raw = item as? String,
           let url = URL(string: raw), url.isFileURL
        {
            return url.path
        }
        return nil
    }
}

/// Save-first QuickLook preview: QLPreviewPanel over local files only.
/// Missing paths and directories are filtered — the panel never opens
/// empty (guarded no-op, same as the SharePoint open without a web_url).
@MainActor
public final class QuickLookPreview: NSObject, @MainActor QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookPreview()

    private var urls: [URL] = []

    private override init() { super.init() }

    /// True for an existing regular file (Save-first flow lands here).
    public static func canPreview(path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    /// Panel title seed: the basename (`/tmp/a b.pdf` → `a b.pdf`).
    public static func previewTitle(path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Show the panel for saved local paths (order kept, unpreviewable
    /// entries dropped). No-op when nothing survives the filter.
    public func preview(paths: [String]) {
        let urls = paths.filter(Self.canPreview).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.delegate = self
        panel.dataSource = self
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    public func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        urls.count
    }

    public func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

