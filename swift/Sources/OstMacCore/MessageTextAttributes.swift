// MessageTextAttributes.swift — UI-agnostic render model for message
// bodies (P0 core consolidation).
//
// `MessageRender.attributedBody` returns a Foundation `AttributedString`
// whose runs carry SEMANTIC attributes only — what a span IS, never how
// it looks. The UI target maps them to fonts and colors (mention → bold,
// own mention → accent wash, code → monospaced, codeToken → palette
// color, link → link style). Core imports no SwiftUI/AppKit styling.
//
//   run.mention    MentionRole?          a mined @mention (.own = the
//                                        signed-in user)
//   run.codeRole   CodeRole?             inline `ticks` / server <pre> /
//                                        ``` fenced block
//   run.codeToken  CodeHighlight.Token?  syntax bucket inside code
//                                        (never .plain — plain = nil)
//   run.link       URL?                  Foundation's link attribute
import Foundation

/// Who a mention names.
public enum MentionRole: String, Hashable, Sendable, Codable {
    /// Someone else.
    case other
    /// The signed-in user ("mine" — the UI washes these).
    case own
}

/// Where a code span came from.
public enum CodeRole: String, Hashable, Sendable, Codable {
    /// Backtick span in prose (ticks stripped).
    case inline
    /// Server `<pre>` snippet inside prose (auto-detected grammar).
    case preformatted
    /// ``` fenced block (fence lines stripped).
    case block
}

public enum MessageTextAttributes {
    public enum MentionAttribute: CodableAttributedStringKey {
        public typealias Value = MentionRole
        public static let name = "BetterTeams.mention"
    }

    public enum CodeRoleAttribute: CodableAttributedStringKey {
        public typealias Value = CodeRole
        public static let name = "BetterTeams.codeRole"
    }

    public enum CodeTokenAttribute: CodableAttributedStringKey {
        public typealias Value = CodeHighlight.Token
        public static let name = "BetterTeams.codeToken"
    }
}

extension AttributeScopes {
    /// Message-body semantics + Foundation (for `link`).
    public struct MessageAttributes: AttributeScope {
        public let mention: MessageTextAttributes.MentionAttribute
        public let codeRole: MessageTextAttributes.CodeRoleAttribute
        public let codeToken: MessageTextAttributes.CodeTokenAttribute
        public let foundation: FoundationAttributes
    }

    public var message: MessageAttributes.Type { MessageAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.MessageAttributes, T>
    ) -> T {
        self[T.self]
    }
}
