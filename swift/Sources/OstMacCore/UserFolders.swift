// UserFolders.swift — the user's folders that the app writes into, in
// one place, so a test process never writes into the real ones. A test
// run once left an empty file in the owner's ~/Downloads (APPNATIVE4):
// under XCTest every download destination is a temporary folder.
import Foundation

public enum UserFolders {
    /// XCTest is loaded (unit tests): no writes to the user's folders.
    public static let isTestProcess = NSClassFromString("XCTestCase") != nil

    /// ~/Downloads; under XCTest a temporary ".../BetterTeamsTest/Downloads"
    /// (created on demand).
    public static func downloads(test: Bool = isTestProcess) -> URL {
        guard test else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterTeamsTest/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
