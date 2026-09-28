// MessageTranslation.swift — e1-translation lane: pure inline-translation
// policy. Eligibility (non-empty copyText), source detection (on-device
// NLLanguageRecognizer), same-language no-op, cache keying (message id +
// target lang), the availability gate (Translation framework needs
// macOS 15+; the package floor is 14), and the provider seam (Apple
// on-device + stub). No network: this file and TranslationStore.swift
// must never gain a URL host (pinned by MessageTranslationTests).
import Foundation
import NaturalLanguage

/// Inline per-bubble translation policy. No view or FFI code.
public enum MessageTranslation {
    /// ONE title for both bubble menus (AppKit right-click + keyboard/VO).
    public static let menuTitle = "Translate"

    /// UserDefaults key for the target language code.
    public static let targetDefaultsKey = "om.translation.target"

    // MARK: - Availability gate (accept 5)

    /// Test seam: forces `isAvailable` either way (macOS-14 branch is
    /// covered without old-OS CI). Nil (production) reads the OS gate.
    public static var availabilityOverride: Bool?

    /// True when the on-device Translation framework can run (macOS 15+).
    public static var isAvailable: Bool {
        if let forced = availabilityOverride { return forced }
        if #available(macOS 15, *) { return true }
        return false
    }

    /// Reason shown when translation is unavailable (Settings + tests).
    public static let unavailableReason = "Translation needs macOS 15 or later."

    // MARK: - Input + eligibility (accept 1)

    /// Translation input: exactly what Copy takes (bubble text + card
    /// copy lines + fallback rows). Read-only — never alters copyText.
    public static func inputText(for message: ChatMessage) -> String {
        MessageActions.copyText(for: message)
    }

    /// A bubble offers Translate iff the framework is available and the
    /// bubble carries non-blank text (image-only/empty bubbles omit it).
    public static func isEligible(_ message: ChatMessage) -> Bool {
        guard isAvailable else { return false }
        return !inputText(for: message)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Languages (accept 4)

    /// On-device source detection. Nil when the text is too short or
    /// ambiguous (the provider then auto-detects instead).
    public static func detectedLanguage(for text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    /// Default target = the system's preferred language (fallback en).
    public static func defaultTargetCode() -> String {
        Locale.preferredLanguages.first
            .flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
            ?? "en"
    }

    /// Same-language check on the base language (en-US == en). Either
    /// side unparseable or empty → false (translate, never no-op blind).
    public static func sameLanguage(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty,
              let la = Locale.Language(identifier: a).languageCode?.identifier,
              let lb = Locale.Language(identifier: b).languageCode?.identifier
        else { return false }
        return la.lowercased() == lb.lowercased()
    }

    /// Localized display name for a target code (fallback: the code).
    public static func displayName(for code: String) -> String {
        if code == "zh-Hans" { return "Chinese (Simplified)" }
        if code == "zh-Hant" { return "Chinese (Traditional)" }
        return Locale.current.localizedString(forLanguageCode: code)?
            .capitalized ?? code
    }

    /// Curated target list for the Settings picker (system default is
    /// prepended at render when missing). Codes are BCP-47 for
    /// Locale.Language / the Translation framework.
    public static let targetCodes: [String] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "ja", "ko",
        "zh-Hans", "zh-Hant", "ar", "hi", "pl", "tr", "sv", "da",
        "nb", "fi", "el", "he", "th", "vi", "id", "ms", "uk", "cs",
        "ro", "hu",
    ]

    // MARK: - Cache (accept 6)

    /// Cache key: message id + target lang (scope-pinned). The entry
    /// also records its source text so an edit retranslates.
    public static func cacheKey(messageID: String, targetCode: String) -> String {
        "\(messageID)\n\(targetCode)"
    }
}

/// One translation result: text plus the source the provider used.
public struct TranslatedText: Sendable, Equatable {
    public let text: String
    public let sourceCode: String?

    public init(text: String, sourceCode: String? = nil) {
        self.text = text
        self.sourceCode = sourceCode
    }
}

/// On-device translation provider seam. Production uses the Apple
/// Translation framework (TranslationStore, macOS 15+); tests inject
/// StubMessageTranslator (no models, no network).
public protocol MessageTranslator: Sendable {
    func translate(
        _ text: String, from sourceCode: String?, to targetCode: String
    ) async throws -> TranslatedText
}

/// Translation failure modes (quiet inline states, never alerts).
public enum TranslationFailure: Error, Equatable, Sendable {
    case unavailable
    case emptyInput
    case provider(String)
    /// No TranslationSession was ever attached (`TranslationStore.attached`
    /// is the UI's job — a `.translationTask` or equivalent host must
    /// push one before the first translate).
    case sessionNotAttached
}

/// Canned provider for tests and model-less runs: returns the mapped
/// text (bracketed echo when unmapped), counts calls, and can fail the
/// first N calls to exercise retry.
public final class StubMessageTranslator: MessageTranslator, @unchecked Sendable {
    private let lock = NSLock()
    private let mapping: [String: String]
    private var failuresLeft: Int
    private var _calls = 0

    public init(mapping: [String: String] = [:], failures: Int = 0) {
        self.mapping = mapping
        self.failuresLeft = failures
    }

    /// Calls served (failures count — they reached the provider).
    public var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func translate(
        _ text: String, from sourceCode: String?, to _: String
    ) async throws -> TranslatedText {
        let fail: Bool = lock.withLock {
            _calls += 1
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if fail { throw TranslationFailure.provider("stubbed failure") }
        return TranslatedText(
            text: mapping[text] ?? "⟦\(text)⟧", sourceCode: sourceCode)
    }
}
