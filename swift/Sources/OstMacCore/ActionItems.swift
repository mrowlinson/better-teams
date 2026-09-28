// ActionItems.swift — f1-actions lane: on-device meeting action items.
//
// IDEA-only inspiration from Teamsly (AGPL): an action-items entry
// point on meetings/threads. No Teamsly code is used here.
//
// Contract:
//   - On-device ONLY: extraction runs through OnDeviceCatchUpTransport
//     (the d1-summaries gate + runner seam). Zero bytes off-machine:
//     no URLSession, no Process anywhere on this path, no cloud/CLI
//     fallback, ever.
//   - Two sources, one extractor: meeting transcripts (VTT cues,
//     primary) and chat threads (messages, via CatchUp.transcript
//     reuse, secondary).
//   - Results are reviewable bullets (title + owner + source cue
//     timestamp label), cached per source in memory only.
//   - macOS 14 still compiles: this file never imports
//     FoundationModels (the transport owns the canImport gate).
import Combine
import Foundation

// MARK: - Model

/// One extracted action item. `owner` is the named owner or
/// "Unassigned"; `sourceLabel` is the source cue's timestamp label
/// ("m:ss" / "h:mm:ss"), nil when the source has none.
public struct ActionItem: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let owner: String
    public let sourceLabel: String?

    public init(
        id: Int = 0, title: String,
        owner: String = ActionItems.unassignedOwner,
        sourceLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.sourceLabel = sourceLabel
    }
}

/// Tail-capped model input. `truncated` names the fragment scope (the
/// prompt says so; we never silently extract from a partial head-drop).
public struct CappedTranscript: Sendable, Equatable {
    public let text: String
    public let truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}

// MARK: - Pure builders

public enum ActionItems {
    public static let privacyNote =
        "On-device action items extract on this Mac with Apple Intelligence. Your thread never leaves this device."
    public static let unassignedOwner = "Unassigned"
    /// Empty input: no cues / empty thread (no model call).
    public static let emptySourceCopy = "Nothing to extract from."
    /// The model ran and found nothing worth a bullet.
    public static let noItemsCopy = "No action items found."

    /// "Speaker [m:ss]: one-line text" per cue, oldest first,
    /// tail-capped at CatchUp.maxTranscriptChars on a line boundary.
    public static func transcript(from cues: [TranscriptCue]) -> CappedTranscript {
        let lines = cues.map {
            "\($0.speaker ?? "Unknown") [\($0.startLabel)]: \(singleLine($0.text))"
        }
        return cap(lines.joined(separator: "\n"))
    }

    /// Chat-thread input: the exact CatchUp transcript text (shared
    /// seam), plus a truncation flag recomputed from the raw messages.
    public static func transcript(from messages: [ChatMessage]) -> CappedTranscript {
        let text = CatchUp.transcript(from: messages)
        let approxFull = messages
            .map { "\($0.sender): \($0.content)" }
            .joined(separator: "\n").count
        return CappedTranscript(
            text: text,
            truncated: !text.isEmpty && approxFull > CatchUp.maxTranscriptChars)
    }

    /// Bullets + owner + timestamp-refs instruction over the transcript.
    public static func prompt(transcript: CappedTranscript) -> String {
        let scope = transcript.truncated
            ? "Note: the earliest turns were omitted; extract only from the portion below.\n"
            : ""
        return """
        Extract the action items from this meeting. Reply with one bullet per action item, oldest first.
        Format each bullet exactly like this:
        - <task> — <owner> [<timestamp>]
        <owner> is the person who owns it: use the speaker's name when one is named, else "Unassigned". <timestamp> is the [m:ss] label of the source turn — copy it exactly, or omit the brackets when the source has no timestamp. If there are no action items, reply exactly: No action items found.
        \(scope)
        Transcript:
        \(transcript.text)
        """
    }

    /// Model text → bullets. Lenient by design: timestamps/owners are
    /// optional, and malformed lines are kept as plain (Unassigned)
    /// bullets, never dropped. Only blank lines, markdown headers,
    /// header lines ("Action items:"), and the none-phrasing are
    /// skipped.
    public static func parse(_ text: String) -> [ActionItem] {
        var items: [ActionItem] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("#") else { continue }
            let lower = line.lowercased()
            guard !lower.hasPrefix("no action item"),
                  lower != "none", lower != "none."
            else { continue }
            if line.hasSuffix(":"),
               !line.hasPrefix("-"), !line.hasPrefix("*"), !line.hasPrefix("•"),
               !startsNumbered(line)
            {
                continue
            }
            let stripped = stripBullet(line)
            guard !stripped.isEmpty else { continue }
            let fields = splitFields(stripped, fallback: stripped)
            items.append(ActionItem(
                id: items.count, title: fields.title,
                owner: fields.owner, sourceLabel: fields.label))
        }
        return items
    }

    // MARK: - Private

    private static func cap(_ text: String) -> CappedTranscript {
        guard text.count > CatchUp.maxTranscriptChars else {
            return CappedTranscript(text: text, truncated: false)
        }
        var tail = String(text.suffix(CatchUp.maxTranscriptChars))
        if let nl = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: nl)...])
        }
        return CappedTranscript(text: tail, truncated: true)
    }

    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func startsNumbered(_ line: String) -> Bool {
        var i = line.startIndex
        while i < line.endIndex, line[i].isNumber { line.formIndex(after: &i) }
        guard i > line.startIndex, i < line.endIndex,
              line[i] == "." || line[i] == ")"
        else { return false }
        let j = line.index(after: i)
        return j == line.endIndex || line[j].isWhitespace
    }

    private static func stripBullet(_ line: String) -> String {
        var s = line
        if let first = s.first,
           first == "-" || first == "*" || first == "•"
           || first == "–" || first == "—" || first == "·"
        {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if startsNumbered(s) {
            var i = s.startIndex
            while i < s.endIndex, s[i].isNumber { s.formIndex(after: &i) }
            let j = s.index(after: i)
            s = (j < s.endIndex ? String(s[j...]) : "")
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// "m:ss" / "h:mm:ss" (1–3 digit head, 2-digit tail parts).
    private static func isTimestamp(_ s: String) -> Bool {
        let parts = s.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard let head = parts.first, (1 ... 3).contains(head.count),
              head.allSatisfy(\.isNumber)
        else { return false }
        return parts.dropFirst().allSatisfy {
            $0.count == 2 && $0.allSatisfy(\.isNumber)
        }
    }

    /// Owner-shaped tail: a name-like run (letters/spaces/dots/
    /// dashes/apostrophes, ≤ 4 words). Rejects sentence fragments
    /// ("Review Q3 - Q4 plan" keeps its tail as title).
    private static func isOwnerShaped(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 40 else { return false }
        guard s.first?.isLetter == true else { return false }
        let allowed = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".'-"))
        guard s.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return s.split(separator: " ").count <= 4
    }

    private static func splitFields(
        _ line: String, fallback: String
    ) -> (title: String, owner: String, label: String?) {
        var rest = line
        var owner: String?
        var label: String?
        // Trailing "[m:ss]".
        if rest.hasSuffix("]"), let open = rest.lastIndex(of: "[") {
            let inner = String(rest[rest.index(after: open) ..< rest.index(before: rest.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            if isTimestamp(inner) {
                label = inner
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Trailing "(owner)" / "(m:ss)".
        if label == nil, rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            let inner = String(rest[rest.index(after: open) ..< rest.index(before: rest.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            if isTimestamp(inner) {
                label = inner
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            } else if isOwnerShaped(inner) {
                owner = inner
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Trailing "— owner" / "– owner" / "- owner".
        if owner == nil {
            for sep in [" — ", " – ", " - "] {
                guard let r = rest.range(of: sep, options: .backwards) else { continue }
                let tail = String(rest[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if isOwnerShaped(tail) {
                    owner = tail
                    rest = String(rest[..<r.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        var title = rest.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-,:;")))
        if title.isEmpty { title = fallback }
        return (title, owner ?? unassignedOwner, label)
    }
}

// MARK: - Cache

/// Memory-only per-source extraction cache (mirrors
/// ThreadSummaryCache). Key = sourceID + count + content
/// fingerprint: new cues/messages invalidate, a source switch misses
/// (effective reset, no explicit clear needed).
public struct ActionItemsCache: Sendable {
    /// Max sources remembered; oldest evicted first (LRU).
    public static let capacity = 20

    public struct Key: Equatable, Sendable {
        public let sourceID: String?
        public let count: Int
        public let fingerprint: Int
    }

    /// MRU last.
    private var entries: [(key: Key, items: [ActionItem])] = []

    public init() {}

    public static func key(sourceID: String?, cues: [TranscriptCue]) -> Key {
        var hasher = Hasher()
        for c in cues {
            hasher.combine(c.id)
            hasher.combine(c.speaker)
            hasher.combine(c.text)
        }
        return Key(
            sourceID: sourceID, count: cues.count,
            fingerprint: hasher.finalize())
    }

    public static func key(sourceID: String?, messages: [ChatMessage]) -> Key {
        var hasher = Hasher()
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.content)
        }
        return Key(
            sourceID: sourceID, count: messages.count,
            fingerprint: hasher.finalize())
    }

    /// Cached bullets for an unchanged source, else nil. Empty arrays
    /// are cached too (a "found nothing" re-tap spends no session).
    /// Hits refresh LRU.
    public mutating func lookup(_ key: Key) -> [ActionItem]? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let hit = entries.remove(at: i)
        entries.append(hit)
        return hit.items
    }

    public mutating func store(_ key: Key, items: [ActionItem]) {
        entries.removeAll(where: { $0.key == key })
        entries.append((key: key, items: items))
        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    public mutating func reset() {
        entries.removeAll()
    }
}

// MARK: - Store

/// On-device action-items extraction over cues or messages. The
/// transport defaults to OnDeviceCatchUpTransport (gate + runner,
/// zero off-machine bytes); tests inject a mock runner. Empty input
/// short-circuits to `.empty` without a model call; a ran-but-empty
/// result lands in `.empty` too (distinct copy); failures land in
/// `.failed` with the CatchUpError guidance message.
@MainActor
public final class ActionItemsStore: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded([ActionItem])
        /// Settled with nothing to show: `emptySourceCopy` (no input,
        /// no model call) or `noItemsCopy` (model found none). No Retry.
        case empty(String)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    /// Structured form of the current `.failed` detail (nil unless the
    /// last extract ended in a known `CatchUpError`). Views use it to
    /// show the on-device guidance box.
    @Published public private(set) var lastError: CatchUpError?

    /// Internal (not private) so tests pin the on-device default.
    let transport: any CatchUpTransport
    private var cache = ActionItemsCache()

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(transport: (any CatchUpTransport)? = nil) {
        self.transport = transport ?? OnDeviceCatchUpTransport()
        _state = Published(initialValue: .idle)
        _lastError = Published(initialValue: nil)
    }

    /// Extract over transcript cues (primary). `transcriptID` scopes
    /// the cache to this transcript.
    public func extractFromCues(_ cues: [TranscriptCue], transcriptID: String?) async {
        await run(
            transcript: ActionItems.transcript(from: cues),
            key: ActionItemsCache.key(sourceID: transcriptID, cues: cues))
    }

    /// Extract over a chat thread (secondary). `chatID` scopes the
    /// cache to this thread.
    public func extractFromMessages(_ messages: [ChatMessage], chatID: String?) async {
        await run(
            transcript: ActionItems.transcript(from: messages),
            key: ActionItemsCache.key(sourceID: chatID, messages: messages))
    }

    /// Back to idle (card reopen, source switch, popover dismiss).
    public func reset() {
        state = .idle
        lastError = nil
    }

    private func run(transcript: CappedTranscript, key: ActionItemsCache.Key) async {
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = nil
            state = .empty(ActionItems.emptySourceCopy)
            return
        }
        if let hit = cache.lookup(key) {
            lastError = nil
            state = hit.isEmpty ? .empty(ActionItems.noItemsCopy) : .loaded(hit)
            return
        }
        state = .loading
        do {
            let text = try await transport.complete(
                baseURL: "", apiKey: "", model: "",
                prompt: ActionItems.prompt(transcript: transcript))
            let items = ActionItems.parse(text)
            cache.store(key, items: items)
            lastError = nil
            state = items.isEmpty ? .empty(ActionItems.noItemsCopy) : .loaded(items)
        } catch let e as CatchUpError {
            lastError = e
            state = .failed(e.message)
        } catch {
            let wrapped = CatchUpError.onDeviceFailed(String(describing: error))
            lastError = wrapped
            state = .failed(wrapped.message)
        }
    }
}

