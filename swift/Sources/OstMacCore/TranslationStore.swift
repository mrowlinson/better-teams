// TranslationStore.swift — e1-translation lane: per-message translation
// state (bubble-local updates only; cached entries re-render instantly,
// no timeline refresh). Live provider is the on-device Apple Translation
// framework (macOS 15+, session supplied by SwiftUI translationTask);
// tests inject StubMessageTranslator. No network (grep-pinned by test).
import Foundation
import Combine
import Translation

/// One bubble's translation: cached text + visibility toggle.
public struct TranslatedEntry: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case pending
        case translated
        case sameLanguage
        case failed
    }

    /// Translated text (original input when state is .sameLanguage).
    public var text: String
    /// Source language code (detected or provider-reported).
    public var sourceCode: String?
    public var targetCode: String
    /// Input the translation was made from (edit → retranslate).
    public var sourceText: String
    public var state: State
    public var isVisible: Bool

    public init(
        text: String, sourceCode: String? = nil, targetCode: String,
        sourceText: String, state: State, isVisible: Bool = true
    ) {
        self.text = text
        self.sourceCode = sourceCode
        self.targetCode = targetCode
        self.sourceText = sourceText
        self.state = state
        self.isVisible = isVisible
    }
}

/// On-device session hub (macOS 15+): the translationTask modifier in
/// the timeline attaches the live TranslationSession; translate calls
/// await it. Never attached → fail fast (`sessionNotAttached`);
/// re-attach pending after `invalidate` → bounded wait (30 s).
@available(macOS 15, *)
final class TranslationSessionHub: @unchecked Sendable {
    private let lock = NSLock()
    private var session: TranslationSession?
    private var everAttached = false
    private var waiters: [CheckedContinuation<TranslationSession, Error>] = []

    func attach(_ session: TranslationSession) {
        lock.lock()
        self.session = session
        everAttached = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for w in pending { w.resume(returning: session) }
    }

    /// Invalidate on config change (target switch): the next translate
    /// awaits the fresh session the new task provides.
    func invalidate() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    func current() -> TranslationSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return everAttached
    }

    func awaitSession() async throws -> TranslationSession {
        if let s = current() { return s }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let s = session {
                lock.unlock()
                cont.resume(returning: s)
            } else if !everAttached {
                lock.unlock()
                cont.resume(throwing: TranslationFailure.sessionNotAttached)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }
}

/// Per-message translation state. One store per timeline (default param,
/// pins/receipts precedent); UserDefaults is the target-lang source of
/// truth so the Settings picker and every store stay in sync.
@MainActor
public final class TranslationStore: ObservableObject {
    /// Cached entries by message id (bubble-local reads only).
    @Published public private(set) var entries: [String: TranslatedEntry] = [:]

    /// Why the most recent translate failed (nil after a success).
    /// `.sessionNotAttached` means the UI never called `attached(_:)`.
    @Published public private(set) var lastFailure: TranslationFailure?

    /// Target language code (UserDefaults-backed, default = system).
    @Published public var targetLanguageCode: String {
        didSet {
            defaults.set(targetLanguageCode, forKey: MessageTranslation.targetDefaultsKey)
        }
    }

    private let defaults: UserDefaults
    private let providerOverride: MessageTranslator?
    /// Type-erased TranslationSessionHub (macOS 15+): AnyObject so this
    /// ungated store loads on macOS 14 (cast only inside #available).
    private var hub: AnyObject?
    private var defaultsObserver: NSObjectProtocol?

    public init(
        provider: MessageTranslator? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.providerOverride = provider
        self.defaults = defaults
        self.targetLanguageCode =
            defaults.string(forKey: MessageTranslation.targetDefaultsKey)
                ?? MessageTranslation.defaultTargetCode()
        if #available(macOS 15, *) {
            self.hub = TranslationSessionHub()
        }
        self.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults,
            queue: .main
        ) { [weak self] _ in
            // queue: .main runs this block on the main thread, so
            // main-actor isolation provably holds (no hop, same timing).
            MainActor.assumeIsolated {
                guard let self else { return }
                // Adopt external writes (Settings picker); ignore removals
                // (test teardown) so the default survives.
                if let code = self.defaults.string(
                    forKey: MessageTranslation.targetDefaultsKey),
                    code != self.targetLanguageCode
                {
                    self.targetLanguageCode = code
                }
            }
        }
    }

    deinit {
        if let o = defaultsObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Reads

    /// This bubble's entry (nil = never translated).
    public func entry(for messageID: String) -> TranslatedEntry? {
        entries[messageID]
    }

    // MARK: - Writes

    /// Menu action: translate, toggle visibility, or retry a failure.
    public func toggle(_ message: ChatMessage) async {
        if let e = entries[message.id] {
            switch e.state {
            case .failed:
                await translate(message)
            case .pending:
                break // in flight — the quiet caption already shows
            case .translated, .sameLanguage:
                var next = e
                next.isVisible.toggle()
                entries[message.id] = next
            }
            return
        }
        await translate(message)
    }

    /// Translate one bubble (cache-aware, same-language no-op).
    public func translate(_ message: ChatMessage) async {
        let input = MessageTranslation.inputText(for: message)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetLanguageCode
        guard MessageTranslation.isAvailable else {
            entries[message.id] = TranslatedEntry(
                text: "", targetCode: target, sourceText: input,
                state: .failed)
            lastFailure = .unavailable
            return
        }
        guard !trimmed.isEmpty else { return }
        // Cache hit: same target + same input re-renders instantly.
        if let e = entries[message.id], e.targetCode == target,
           e.sourceText == input, e.state == .translated || e.state == .sameLanguage
        {
            var next = e
            next.isVisible = true
            entries[message.id] = next
            return
        }
        let detected = MessageTranslation.detectedLanguage(for: input)
        if let detected, MessageTranslation.sameLanguage(detected, target) {
            entries[message.id] = TranslatedEntry(
                text: input, sourceCode: detected, targetCode: target,
                sourceText: input, state: .sameLanguage)
            return
        }
        // Quiet inline pending (caption text only — never a spinner).
        entries[message.id] = TranslatedEntry(
            text: "", sourceCode: detected, targetCode: target,
            sourceText: input, state: .pending)
        do {
            let out: TranslatedText
            if let provider = providerOverride {
                out = try await provider.translate(
                    input, from: detected, to: target)
            } else if #available(macOS 15, *) {
                out = try await appleTranslate(
                    input, source: detected, target: target)
            } else {
                throw TranslationFailure.unavailable
            }
            entries[message.id] = TranslatedEntry(
                text: out.text, sourceCode: out.sourceCode ?? detected,
                targetCode: target, sourceText: input, state: .translated)
            lastFailure = nil
        } catch {
            entries[message.id] = TranslatedEntry(
                text: "", sourceCode: detected, targetCode: target,
                sourceText: input, state: .failed)
            lastFailure = (error as? TranslationFailure)
                ?? .provider(error.localizedDescription)
        }
    }

    // MARK: - Apple on-device provider (macOS 15+)

    /// Live translation through the attached TranslationSession.
    /// On-device only (downloaded models); airplane-mode green.
    @available(macOS 15, *)
    private func appleTranslate(
        _ text: String, source: String?, target: String
    ) async throws -> TranslatedText {
        guard let hub = hub as? TranslationSessionHub else {
            throw TranslationFailure.unavailable
        }
        let session = try await withThrowingTaskGroup(of: TranslationSession.self) { group in
            group.addTask { try await hub.awaitSession() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw TranslationFailure.provider("translation session timed out")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let response = try await session.translate(text)
        return TranslatedText(
            text: response.targetText,
            sourceCode: source ?? response.sourceLanguage.minimalIdentifier)
    }

    /// True once the UI has attached a session (`attached(_:)`). Until
    /// then live translates fail immediately with `.sessionNotAttached`.
    public var isSessionAttached: Bool {
        guard #available(macOS 15, *) else { return false }
        return (hub as? TranslationSessionHub)?.isAttached ?? false
    }

    /// Called by the timeline's translationTask with the live session.
    @available(macOS 15, *)
    public func attached(_ session: TranslationSession) {
        (hub as? TranslationSessionHub)?.attach(session)
    }

    /// Session target for the timeline's translationTask (re-evaluated
    /// when the published target changes → fresh session per language).
    @available(macOS 15, *)
    public var sessionTarget: Locale.Language {
        Locale.Language(identifier: targetLanguageCode)
    }
}

// MARK: - Timeline wiring

