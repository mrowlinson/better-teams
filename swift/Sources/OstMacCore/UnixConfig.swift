// UnixConfig.swift — om-meetings-dirname: ~/.config dir + legacy migrator.
//
// Rules (rules.json) and scheduled send (scheduled.json) persist under
// ~/.config/<AppIdentity.name>/; pre-rename installs used ~/.config/ostmac/.
// defaultPath getters migrate lazily (move when the new dir is absent,
// else no-op, never deletes), mirroring the Application Support migrators.
import Foundation

/// Shared ~/.config dir for unix-style JSON stores (rules, scheduled send).
public enum UnixConfig {
    /// Pre-rename ~/.config leaf (never written, only moved).
    public static let legacyLeaf = "ostmac"

    /// `~/.config` (existing behavior; not XDG-aware).
    public static func configHome() -> URL {
        URL(
            fileURLWithPath: NSString(string: "~/.config").expandingTildeInPath,
            isDirectory: true)
    }

    /// `~/.config/<AppIdentity.name>` (current dir).
    public static func baseURL(under configHome: URL) -> URL {
        configHome.appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    /// `~/.config/ostmac` (pre-rename dir).
    public static func legacyBaseURL(under configHome: URL) -> URL {
        configHome.appendingPathComponent(legacyLeaf, isDirectory: true)
    }

    /// Move the legacy dir onto the new dir when the new one is absent
    /// (rules.json + scheduled.json ride along). No-op when legacy is
    /// missing or the new dir already exists — nothing is ever deleted.
    @discardableResult
    public static func migrateLegacyDirectory(
        under configHome: URL, fileManager: FileManager = .default
    ) -> Bool {
        let legacy = legacyBaseURL(under: configHome)
        let fresh = baseURL(under: configHome)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: fresh.path)
        else { return false }
        do {
            try fileManager.createDirectory(
                at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: fresh)
            return true
        } catch {
            return false
        }
    }

    /// Default JSON path for `fileName`, migrating first.
    public static func defaultPath(for fileName: String) -> String {
        let home = configHome()
        migrateLegacyDirectory(under: home)
        return baseURL(under: home).appendingPathComponent(fileName).path
    }
}
