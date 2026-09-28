// ShareSheet.swift — P3 split: verbatim move from UnifiedFiles.swift.
import AppKit
import Foundation

/// Save-first share sheet: NSSharingServicePicker over local files.
/// The anchor is the key window's content view (nil = headless no-op).
public enum ShareSheet {
    @MainActor
    public static func show(items: [Any]) {
        guard !items.isEmpty,
              let anchor = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView
        else { return }
        NSSharingServicePicker(items: items)
            .show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }
}
