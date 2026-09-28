// GroupChat.swift — core-a G5: group chat create. Pure ref/topic rules
// shared by the live create path (`AppState.openNewChat`) and demo.
// No FFI, no network.
import Foundation

public enum GroupChat {
    /// Graph user refs for the picked people (`PersonChat.userRef`:
    /// AAD id, else work email), blanks dropped, case-insensitive
    /// duplicates removed, pick order kept.
    public static func userRefs(for people: [TeamMember]) -> [String] {
        var seen = Set<String>()
        return people.compactMap { PersonChat.userRef(for: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Trimmed topic, nil when blank. Graph caps topics; very long
    /// input is cut to `maxTopic` characters.
    public static let maxTopic = 250
    public static func cleanTopic(_ topic: String?) -> String? {
        guard let t = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(maxTopic))
    }

    /// Untitled group name: first names joined ("Ava, Tom and Megan"),
    /// as Teams labels topic-less groups.
    public static func defaultName(for people: [TeamMember]) -> String {
        let names = people.map { p -> String in
            let full = p.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return full.split(separator: " ").first.map(String.init) ?? full
        }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return "Group chat"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// Demo group thread id (in-memory; deterministic per member set
    /// + topic so re-creating re-opens the same demo thread).
    public static func demoChatID(refs: [String], topic: String?) -> String {
        let key = refs.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "demo-group-\(key)\(topic.map { "|\($0)" } ?? "")"
    }
}
