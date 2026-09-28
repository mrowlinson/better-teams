// SemanticRunTestSupport.swift — P0: message bodies carry semantic
// attributes (MessageTextAttributes.swift), not SwiftUI fonts/colors.
// "Styled" = any span the UI restyles: a mention or a code span.
import Foundation

@testable import OstMacCore

extension AttributedString.Runs.Run {
    var isStyledSpan: Bool { self.mention != nil || self.codeRole != nil }
}
