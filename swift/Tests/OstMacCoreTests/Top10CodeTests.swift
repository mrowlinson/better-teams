// Top10CodeTests.swift — top10-code lane: #8 code-first messaging —
// fenced-block parse, indent-preserving send, plain-text-first paste,
// headless highlight.js colors, and fence-aware bubble rendering.
import XCTest

@testable import OstMacCore

@MainActor
final class Top10CodeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MessageRender.resetRenderCaches()
    }

    // MARK: - Fence parse

    func testSegmentsBasicSwift() {
        let segs = CodeBlocks.segments(in: "hi\n```swift\nlet x = 1\n```\nbye")
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0], CodeBlocks.Segment(kind: .prose, text: "hi\n"))
        XCTAssertEqual(segs[1], CodeBlocks.Segment(kind: .code, text: "let x = 1", language: "swift"))
        XCTAssertEqual(segs[2], CodeBlocks.Segment(kind: .prose, text: "\nbye"))
    }

    func testSegmentsIndentByteExact() {
        let code = "func f() {\n    four\n        eight\n\ttab\n  \n}"
        let segs = CodeBlocks.segments(in: "```swift\n" + code + "\n```")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, .code)
        XCTAssertEqual(segs[0].text, code) // spaces/tabs/blank line intact
    }

    func testSegmentsUnclosedRunsToEnd() {
        let segs = CodeBlocks.segments(in: "try this\n```\nlet x = 1\nlet y = 2")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "try this\n")
        XCTAssertEqual(segs[1].kind, .code)
        XCTAssertEqual(segs[1].text, "let x = 1\nlet y = 2")
        XCTAssertNil(segs[1].language)
    }

    func testSegmentsTildeAndIndentedFences() {
        let segs = CodeBlocks.segments(in: "  ~~~py\nprint(1)\n  ~~~\ndone")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0], CodeBlocks.Segment(kind: .code, text: "print(1)", language: "python"))
        XCTAssertEqual(segs[1], CodeBlocks.Segment(kind: .prose, text: "\ndone"))
    }

    func testInfoWithFenceCharIsNotAFence() {
        // CommonMark: an info string holding a backtick voids the fence.
        XCTAssertFalse(CodeBlocks.containsFence(in: "a ``` `x` b"))
        XCTAssertFalse(CodeBlocks.containsFence(in: "``` `x`\ncode"))
    }

    func testContainsFence() {
        XCTAssertTrue(CodeBlocks.containsFence(in: "```\nx\n```"))
        XCTAssertTrue(CodeBlocks.containsFence(in: "  ```js\nx"))
        XCTAssertTrue(CodeBlocks.containsFence(in: "~~~\nx\n~~~"))
        XCTAssertFalse(CodeBlocks.containsFence(in: "run `go build` now"))
        XCTAssertFalse(CodeBlocks.containsFence(in: " `` not a fence `` "))
        XCTAssertFalse(CodeBlocks.containsFence(in: ""))
        XCTAssertFalse(CodeBlocks.containsFence(in: "plain prose"))
    }

    func testSegmentsMultipleBlocksAlternate() {
        let segs = CodeBlocks.segments(in: "```a\n1\n```\nmid\n```b\n2\n```")
        XCTAssertEqual(segs.map(\.kind), [.code, .prose, .code])
        XCTAssertEqual(segs[0].text, "1")
        XCTAssertNil(segs[0].language) // unknown info → auto
        XCTAssertEqual(segs[1].text, "\nmid\n")
        XCTAssertEqual(segs[2].text, "2")
    }

    func testSegmentsEmptyBlock() {
        let segs = CodeBlocks.segments(in: "before\n```\n```\nafter")
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[1], CodeBlocks.Segment(kind: .code, text: ""))
    }

    func testSegmentsCapKeepsRestAsProse() {
        var text = ""
        for i in 0 ..< (CodeBlocks.maxBlocks + 5) {
            text += "```\ncode\(i)\n```\n"
        }
        let segs = CodeBlocks.segments(in: text)
        XCTAssertEqual(segs.filter { $0.kind == .code }.count, CodeBlocks.maxBlocks)
        // Nothing dropped: every code line survives somewhere.
        XCTAssertTrue(segs.allSatisfy { !$0.text.isEmpty || $0.kind == .code })
        let joined = segs.map(\.text).joined()
        for i in 0 ..< (CodeBlocks.maxBlocks + 5) {
            XCTAssertTrue(joined.contains("code\(i)"), "code\(i) survives")
        }
    }

    func testCodeRangesCoverFenceLines() {
        let text = "hi\n```swift\nlet x = 1\n```\nbye"
        let ranges = CodeBlocks.codeRanges(in: text)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "```swift\nlet x = 1\n```\n")
    }

    // MARK: - Language map

    func testCanonicalLanguage() {
        XCTAssertEqual(CodeBlocks.canonicalLanguage("swift"), "swift")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("  Swift  "), "swift")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("js"), "javascript")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("ts"), "typescript")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("py"), "python")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("c++"), "cpp")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("c#"), "csharp")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("sh"), "bash")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("zsh"), "bash")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("yml"), "yaml")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("md"), "markdown")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("rs"), "rust")
        XCTAssertEqual(CodeBlocks.canonicalLanguage("html"), "xml")
        XCTAssertNil(CodeBlocks.canonicalLanguage(""))
        XCTAssertNil(CodeBlocks.canonicalLanguage("cobol"))
        XCTAssertNil(CodeBlocks.canonicalLanguage("dockerfile"))
    }

    // MARK: - Send preserves indent (accept: clipboard → sent message)

    /// Paste indented Swift from the clipboard → the sent message keeps
    /// every indent byte. Simulates the VS Code trap: styled flavors
    /// present, string flavor must win, send must not touch interiors.
    func testPasteIndentedSwiftSendKeepsIndent() {
        let pasted = """
            ```swift
            func greet(name: String) -> String {
                let line = "hi \\(name)" // 4sp
                    let deep = deep(line) // 8sp
            \treturn line // tab
            }
            ```
            """
        let styled = NSAttributedString(string: "mangled flat fallback")
        let rtf = try? styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let resolved = CodePaste.resolve(
            string: pasted, rtf: rtf, html: "<pre>mangled</pre>")
        XCTAssertEqual(resolved, pasted) // string flavor wins
        let store = ConversationStore.demo()
        store.send(text: resolved!)
        XCTAssertEqual(store.messages.last?.content, pasted) // byte-exact
    }

    func testSendBodyNormalizesEndingsTrimsOuterOnly() {
        XCTAssertEqual(CodeBlocks.sendBody(for: "a\r\n  b\r  c"), "a\n  b\n  c")
        XCTAssertEqual(CodeBlocks.sendBody(for: "\n\n  code\n    ind\n\n"), "code\n    ind")
        XCTAssertEqual(CodeBlocks.sendBody(for: "   "), "")
    }

    func testEditPreservesIndent() {
        let store = ConversationStore.demo()
        store.send(text: "placeholder")
        let id = store.messages.last!.id
        let edited = "```\nif x {\n        deep\n}\n```"
        store.edit(messageID: id, text: edited)
        XCTAssertEqual(store.messages.last?.content, edited)
    }

    // MARK: - Paste resolve

    func testResolvePrefersString() {
        XCTAssertEqual(
            CodePaste.resolve(string: "  indented", rtf: Data(), html: "<p>x</p>"),
            "  indented")
    }

    func testResolveRTFFallback() {
        let want = "line1\n    indented"
        let attr = NSAttributedString(string: want)
        let rtf = try! attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertEqual(CodePaste.resolve(string: nil, rtf: rtf, html: nil), want)
    }

    func testResolveBadRTFFallsToHTML() {
        XCTAssertEqual(
            CodePaste.resolve(string: nil, rtf: Data([0, 1, 2]), html: "<p>hi</p>"),
            "hi\n")
    }

    func testResolveNilWhenNoFlavors() {
        XCTAssertNil(CodePaste.resolve(string: nil, rtf: nil, html: nil))
    }

    func testPlainFromHTMLKeepsIndentAndNewlines() {
        let html = "<div><span>func f() {</span><br><span>&nbsp;&nbsp;&nbsp;&nbsp;body()</span></div><p>tail</p>"
        let plain = CodePaste.plainFromHTML(html)
        XCTAssertTrue(plain.contains("func f() {\n"), "br → newline: \(plain.debugDescription)")
        XCTAssertTrue(plain.contains("\n    body()\ntail"), "indent + block close → newline: \(plain.debugDescription)")
    }

    func testNormalizeLineEndingsOnly() {
        XCTAssertEqual(CodePaste.normalize("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(CodePaste.normalize("  \tindent  "), "  \tindent  ")
    }

    func testShouldInterceptPasteOnlyWhenStringMissing() {
        let pb = NSPasteboard(name: NSPasteboard.Name("test-top10-code-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        // String present → never intercept (stock paste proceeds).
        pb.declareTypes([.string, .rtf], owner: nil)
        pb.setString("x", forType: .string)
        XCTAssertFalse(CodePaste.shouldInterceptPaste(from: pb))
        XCTAssertEqual(CodePaste.resolvedPaste(from: pb), "x")
        // Styled-only → intercept + rescue.
        pb.declareTypes([.html], owner: nil)
        pb.setString("<p>hi</p>", forType: .html)
        XCTAssertTrue(CodePaste.shouldInterceptPaste(from: pb))
        XCTAssertEqual(CodePaste.resolvedPaste(from: pb), "hi\n")
        // Empty → nothing to rescue.
        pb.declareTypes([], owner: nil)
        XCTAssertFalse(CodePaste.shouldInterceptPaste(from: pb))
        XCTAssertNil(CodePaste.resolvedPaste(from: pb))
    }

    // MARK: - Highlight engine

    func testEngineAvailableAndPinned() {
        XCTAssertTrue(CodeHighlight.isAvailable())
        XCTAssertEqual(CodeHighlight.engineVersion(), "11.10.0")
    }

    func testEveryBundledLanguageSupported() {
        for lang in CodeBlocks.supportedLanguages {
            XCTAssertTrue(CodeHighlight.supports(lang), lang)
        }
        XCTAssertFalse(CodeHighlight.supports("cobol"))
    }

    func testRunsConcatenateAndClassifySwift() {
        let code = "func greet(name: String) -> String {\n    // hello\n    return \"hi\"\n}"
        let runs = CodeHighlight.runs(code: code, language: "swift")
        XCTAssertEqual(runs.map(\.text).joined(), code)
        XCTAssertTrue(runs.contains { $0.text == "func" && $0.token == .keyword })
        XCTAssertTrue(runs.contains { $0.text == "// hello" && $0.token == .comment })
        XCTAssertTrue(runs.contains { $0.text == "return" && $0.token == .keyword })
        XCTAssertTrue(runs.contains { $0.text == "\"hi\"" && $0.token == .string })
        XCTAssertTrue(runs.contains { $0.text == "String" && $0.token == .type })
    }

    func testRunsAutoConcatenates() {
        let code = "print('hello')\nx = 42\n"
        let runs = CodeHighlight.runs(code: code, language: nil)
        XCTAssertEqual(runs.map(\.text).joined(), code)
    }

    func testRunsUnknownLanguageDegradesToPlain() {
        let code = "SELECT 1"
        let runs = CodeHighlight.runs(code: code, language: "cobol")
        XCTAssertEqual(runs, [CodeHighlight.Run(text: code, token: .plain)])
    }

    func testRunsEmptyAndOversize() {
        XCTAssertEqual(CodeHighlight.runs(code: "", language: "swift"), [])
        let big = String(repeating: "x", count: CodeHighlight.maxCodeChars + 1)
        XCTAssertEqual(
            CodeHighlight.runs(code: big, language: "swift"),
            [CodeHighlight.Run(text: big, token: .plain)])
    }

    func testTokenForMapping() {
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-keyword"]), .keyword)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-string"]), .string)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-comment"]), .comment)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-number"]), .number)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-title function_"]), .title)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-type"]), .type)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-attr"]), .tag)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-params"]), .plain)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: ["hljs-nope"]), .plain)
        XCTAssertEqual(CodeHighlight.tokenFor(classes: []), .plain)
        // Inner wins: title inside params.
        XCTAssertEqual(
            CodeHighlight.tokenFor(classes: ["hljs-params", "hljs-title function_"]), .title)
    }

    func testRunsFromHTMLNestedAndEntities() {
        let html = "<span class=\"hljs-keyword\">func</span> f() <span class=\"hljs-string\">&quot;a&lt;b&quot;</span>"
        let runs = CodeHighlight.runsFromHTML(html, code: "func f() \"a<b\"")
        XCTAssertEqual(runs.map(\.text).joined(), "func f() \"a<b\"")
        XCTAssertEqual(runs.first?.token, .keyword)
        XCTAssertEqual(runs.last?.token, .string)
    }

    func testRunsFromHTMLMisalignedDegrades() {
        let runs = CodeHighlight.runsFromHTML("<span class=\"hljs-keyword\">nope</span>", code: "other")
        XCTAssertEqual(runs, [CodeHighlight.Run(text: "other", token: .plain)])
    }

    // MARK: - Render integration

    private func fencedMessage(_ content: String, raw: String? = nil) -> ChatMessage {
        ChatMessage(id: "m\(content.hashValue)", sender: "A", timestamp: "t", content: content, raw: raw)
    }

    func testFencedRendersWithoutFenceLinesMonoAndColored() {
        let m = fencedMessage("see this\n```swift\nfunc f() {\n    return 1\n}\n```\nneat")
        let a = MessageRender.attributedBody(for: m)
        let shown = String(a.characters)
        XCTAssertFalse(shown.contains("```"), shown)
        XCTAssertEqual(shown, "see this\nfunc f() {\n    return 1\n}\nneat")
        // Keyword run: fenced code role + keyword token (UI maps both).
        let kwRuns = a.runs.filter { $0.codeToken == .keyword }
        XCTAssertFalse(kwRuns.isEmpty)
        XCTAssertTrue(kwRuns.allSatisfy { $0.codeRole == .block })
    }

    func testShortcodeInsideCodeStaysLiteral() {
        let m = fencedMessage("```\nrun (smile) now\n```")
        let a = MessageRender.attributedBody(for: m)
        XCTAssertTrue(String(a.characters).contains("(smile)"))
        XCTAssertFalse(String(a.characters).contains("🙂"))
        // …while prose shortcodes still expand.
        let p = fencedMessage("hi (smile)\n```\nx (smile)\n```")
        XCTAssertEqual(String(MessageRender.attributedBody(for: p).characters), "hi 🙂\nx (smile)")
    }

    func testMentionsLinksTicksInsideCodeNotStyled() {
        let m = fencedMessage("```\n@Bo see https://example.com/x and `tick`\n```")
        let a = MessageRender.attributedBody(for: m)
        XCTAssertTrue(String(a.characters).contains("`tick`"), "ticks literal in code")
        XCTAssertTrue(a.runs.filter { $0.link != nil }.isEmpty, "no links in code")
        // Owner-mention wash as the bold proxy: a mined mention inside
        // code never styles (control without fences washes once).
        let raw = "<p><at id=\"8:b\">@Bo</at> see this</p>"
        let coded = ChatMessage(
            id: "mc", sender: "A", timestamp: "t",
            content: "```\n@Bo see this\n```", raw: raw)
        let ac = MessageRender.attributedBody(for: coded, highlighting: "Bo")
        XCTAssertTrue(ac.runs.filter { $0.mention == .own }.isEmpty, "no wash in code")
        let plain = ChatMessage(
            id: "mp", sender: "A", timestamp: "t",
            content: "@Bo see this", raw: raw)
        let ap = MessageRender.attributedBody(for: plain, highlighting: "Bo")
        XCTAssertEqual(ap.runs.filter { $0.mention == .own }.count, 1, "control washes")
    }

    func testProseAroundCodeStillStyled() {
        let m = fencedMessage(
            "Hi @Bo see https://example.com/x\n```swift\nlet x = 1\n```",
            raw: "<p>Hi <at id=\"8:b\">@Bo</at> see https://example.com/x</p><pre>let x = 1</pre>")
        let a = MessageRender.attributedBody(for: m)
        let bolds = a.runs.filter { run in
            guard run.isStyledSpan else { return false }
            // Bold mention vs mono code: only the mention range bolds.
            return String(a.characters[run.range]).contains("@Bo")
        }
        XCTAssertEqual(bolds.count, 1)
        XCTAssertEqual(a.runs.filter { $0.link != nil }.count, 1)
    }

    func testCopyTextKeepsFences() {
        // Display strips fences; Copy/forward keep them (content untouched).
        let m = fencedMessage("```swift\nlet x = 1\n```")
        XCTAssertTrue(MessageActions.copyText(for: m).contains("```swift"))
    }

    func testPreBlocksHighlightWithoutWashShift() {
        // Legacy path: <pre> keeps mono + gains colors; mention wash
        // counts never shift (foreground only, no background).
        let m = ChatMessage(
            id: "m", sender: "A", timestamp: "t",
            content: "Hi @Bo, run let x = 1 now",
            raw: "<p>Hi <at id=\"8:b\">@Bo</at>, run <pre>let x = 1</pre> now</p>")
        let a = MessageRender.attributedBody(for: m, highlighting: "Bo")
        XCTAssertEqual(a.runs.filter { $0.mention == .own }.count, 1)
        XCTAssertFalse(a.runs.filter { $0.isStyledSpan }.isEmpty)
    }

    func testFencedMemoizes() {
        let m = fencedMessage("```swift\nfunc f() {}\n```")
        let text = MessageRender.bubbleText(for: m)
        _ = MessageRender.attributedBody(text: text, raw: m.raw)
        let (_, _, _, first, _) = MessageRender.renderStats()
        _ = MessageRender.attributedBody(text: text, raw: m.raw)
        let (_, _, _, second, _) = MessageRender.renderStats()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1) // cache hit, no recompute
    }

    func testExpandShortcodesExcludesFences() {
        XCTAssertEqual(
            MessageRender.expandShortcodes("a (smile)\n```\n(smile)\n```\n(smile)"),
            "a 🙂\n```\n(smile)\n```\n🙂")
    }
}
