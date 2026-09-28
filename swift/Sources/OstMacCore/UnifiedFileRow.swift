// UnifiedFileRow.swift — P3 split: verbatim move from UnifiedFiles.swift.
import Foundation

/// One merged row: a Shared-tab file tagged with its leg + origin name
/// ("Design Sync", "Platform > #general", "OneDrive").
public struct UnifiedFileRow: Identifiable, Equatable, Sendable {
    public let file: SharedFile
    public let source: UnifiedFileSource
    public let sourceName: String

    /// Dedupe key (drive-scoped; bare ids are chat-path rows without one).
    public var id: String { Self.key(for: file) }

    /// Conversation id for chat/channel rows (jump target); nil for the
    /// drive leg and rows built without one.
    public var sourceID: String? { file.source_id }

    /// Chat/channel rows stamp the conversation onto `file`
    /// (`source_name`/`source_id`, core-b) unless the file already names
    /// one, so every consumer of the bare `SharedFile` (search, detail)
    /// can show "in <conversation>". Drive rows are left untouched.
    public init(
        file: SharedFile, source: UnifiedFileSource, sourceName: String,
        sourceID: String? = nil
    ) {
        if source != .drive, file.source_name == nil || (file.source_id == nil && sourceID != nil) {
            self.file = file.withSource(
                name: file.source_name ?? (sourceName.isEmpty ? nil : sourceName),
                id: file.source_id ?? sourceID)
        } else {
            self.file = file
        }
        self.source = source
        self.sourceName = sourceName
    }

    public static func key(for file: SharedFile) -> String {
        if let drive = file.drive_id { return "\(drive)\n\(file.id)" }
        return file.id
    }
}
