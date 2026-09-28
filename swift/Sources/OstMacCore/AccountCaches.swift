// AccountCaches.swift — d1-accounts: per-account cache removal.
//
// Every per-account store keys off AccountProfile (`.<accountId>`
// UserDefaults suffix / `<accountId>/` disk subdir); the default
// account keeps the legacy keys/dirs. Removal deletes exactly one
// account's namespace — sibling accounts are untouched.
import Foundation

public enum AccountCaches {
    /// All UserDefaults keys in one account's namespace.
    public static func keys(for accountID: String) -> [String] {
        [
            PinnedMessages.key(for: accountID),
            UserPinStore.key(for: accountID),
            ReactionRecents.key(for: accountID),
            BlockedStore.key(for: accountID),
            CallHistoryStore.key(for: accountID),
            FolderStore.foldersKey(for: accountID),
            FolderStore.rulesKey(for: accountID),
            FolderStore.assignmentsKey(for: accountID),
        ]
    }

    /// Delete one account's caches: its UserDefaults namespace + its
    /// RichMedia + meetings disk namespaces. The default account's
    /// disk cleanup removes top-level files only (sibling subdirs
    /// nested under the legacy dirs survive).
    public static func remove(
        accountID: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        for key in keys(for: accountID) {
            defaults.removeObject(forKey: key)
        }
        if accountID == AccountProfile.defaultID {
            if let base = RichMediaCache.defaultDiskDir() {
                removeTopLevelFiles(in: base, fileManager: fileManager)
            }
            if let base = MeetingChatStore.meetingsDirectory() {
                removeTopLevelFiles(in: base, fileManager: fileManager)
            }
        } else {
            if let dir = RichMediaCache.diskDir(for: accountID) {
                try? fileManager.removeItem(at: dir)
            }
            if let dir = MeetingChatStore.meetingsDirectory(for: accountID) {
                try? fileManager.removeItem(at: dir)
            }
        }
    }

    private static func removeTopLevelFiles(in dir: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles)
        else { return }
        for url in urls {
            let regular =
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                ?? false
            if regular {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
