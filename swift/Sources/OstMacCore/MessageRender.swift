// MessageRender.swift — om-convrich lane: rich bubble text + day sections.
//
// Rendering model: core ships stripped `content` (ost strip_html) plus the
// unstripped `raw` HTML. We render from `content` and mine `raw` for span
// positions (mentions, code blocks) — never render raw HTML directly, so
// bubble colors stay in control (no black-on-blue from HTML defaults).
import Foundation

/// Pure rendering helpers. No view code: the AttributedString builder
/// emits semantic attributes only (MessageTextAttributes.swift).
public enum MessageRender {
    // MARK: - Entity decoding (mirrors ost strip_html's entity list)

    private static let entities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
    ]

    public static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, c) in entities { out = out.replacingOccurrences(of: e, with: c) }
        return out
    }

    // MARK: - Raw-HTML mining

    /// Names inside `<at …>Name</at>` mention tags plus Teams
    /// `<span itemtype="…Mention" …>Name</span>` mention spans,
    /// entity-decoded. Live history ships spans (verified 2026-09-24:
    /// no `<at>`, no `@` sigil, sometimes one person split across two
    /// spans); demo seeds `<at>`. Both highlight identically.
    public static func mentions(fromRaw raw: String?) -> [String] {
        guard let raw else { return [] }
        var out = innerTexts(of: "at", in: raw).map(decodeEntities).filter { !$0.isEmpty }
        for m in Mentions.parseFromContent(raw) where !m.displayName.isEmpty {
            if !out.contains(m.displayName) { out.append(m.displayName) }
        }
        return out
    }

    /// Inner text of `<pre>…</pre>` code blocks, tags stripped, decoded.
    public static func codeBlocks(fromRaw raw: String?) -> [String] {
        guard let raw else { return [] }
        return innerTexts(of: "pre", in: raw)
            .map { decodeEntities(stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Text between `<tag …>` and `</tag>` (case-insensitive tag name).
    static func innerTexts(of tag: String, in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        let open = "<" + tag, close = "</" + tag + ">"
        while let s = rest.range(of: open, options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">"),
              let e = rest[gt...].range(of: close, options: .caseInsensitive)
        {
            out.append(String(rest[rest.index(after: gt) ..< e.lowerBound]))
            rest = rest[e.upperBound...]
        }
        return out
    }

    /// Block tags whose boundaries separate words (mirrors ost
    /// strip_html; keep the lists in sync).
    private static let blockTags: Set<String> = [
        "p", "div", "br", "section", "article", "header", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "tr", "td", "th",
        "blockquote", "pre", "hr",
    ]

    /// Tag stripper mirroring ost strip_html (no entity decoding).
    /// Spacing-aware (om-chatnames): block boundaries become one space
    /// so `</p><p>` never glues words; inline tags vanish silently.
    public static func stripTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var tag = ""
        var inTag = false
        var pendingSpace = false
        for ch in s {
            if inTag {
                if ch == ">" {
                    inTag = false
                    var body = tag
                    if body.hasPrefix("/") { body.removeFirst() }
                    let name = body.prefix(while: { !$0.isWhitespace && $0 != "/" }).lowercased()
                    if blockTags.contains(name) { pendingSpace = true }
                    tag = ""
                } else {
                    tag.append(ch)
                }
            } else if ch == "<" {
                inTag = true
            } else {
                if pendingSpace {
                    pendingSpace = false
                    if !out.isEmpty, let last = out.last,
                       !last.isWhitespace, !ch.isWhitespace
                    {
                        out.append(" ")
                    }
                }
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Day sections

    /// "2026-09-22T12:53:06…" -> local "2026-09-22" (fid-time D8: parsed
    /// to a Date, day boundary in `timeZone`, not the UTC slice).
    /// Garbage keeps the legacy prefix/passthrough contract.
    public static func dayKey(_ iso: String, timeZone: TimeZone = .current) -> String {
        let t = iso.trimmingCharacters(in: .whitespaces)
        if let d = TeamsTime.parseISO(t) {
            return TeamsTime.dayKey(d, timeZone: timeZone)
        }
        guard t.count >= 10 else { return t }
        let k = String(t.prefix(10))
        return k.count == 10 && k[k.index(k.startIndex, offsetBy: 4)] == "-"
            ? k : t
    }

    /// "2026-09-22" -> "Today" / "Yesterday" / "Sep 22, 2026".
    public static func dayLabel(_ key: String) -> String {
        let cal = Calendar.current
        guard let d = dayFormats.date(from: key) else { return key.isEmpty ? "Unknown date" : key }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return dayFormats.print(d)
    }

    /// Shared day formatters (om-s6-renderparse): one locked pair replaces
    /// the per-call allocs. Timezone refreshes per call (travel-safe);
    /// locale stays default (same strings as before).
    private static let dayFormats = DayFormatBox()

    public struct DaySection: Sendable {
        public let key: String
        public let label: String
        public let messages: [ChatMessage]
    }

    /// Chronological messages -> day groups, order preserved. Memoized on
    /// the last input: repeat body-evals with unchanged messages reuse the
    /// previous sections (same values, no recompute).
    public static func daySections(_ messages: [ChatMessage]) -> [DaySection] {
        renderLock.lock()
        if let prev = sectionsInput, prev == messages {
            let hit = sectionsOutput
            renderLock.unlock()
            return hit
        }
        renderLock.unlock()
        let out = daySectionsUncached(messages)
        renderLock.lock()
        sectionComputes += 1
        sectionsInput = messages
        sectionsOutput = out
        renderLock.unlock()
        return out
    }

    /// O(n) grouping: one pass into per-day buckets, one label per day.
    /// Same output as the old copy-per-append loop (labels are pure).
    static func daySectionsUncached(_ messages: [ChatMessage]) -> [DaySection] {
        var keys: [String] = []
        var buckets: [[ChatMessage]] = []
        for m in messages {
            let k = dayKey(m.timestamp)
            if keys.last == k {
                buckets[buckets.count - 1].append(m)
            } else {
                keys.append(k)
                buckets.append([m])
            }
        }
        return zip(keys, buckets).map { key, msgs in
            DaySection(key: key, label: dayLabel(key), messages: msgs)
        }
    }

    // MARK: - Render-parse memo (om-s6-renderparse)

    /// Cap across the parse dicts (bubble text, images, bot posts, styled
    /// bodies). Overflow drops everything (cheap rebuild, bounded memory).
    static let maxRenderCacheEntries = 1000

    private static let renderLock = NSLock()
    private struct TextEntry {
        let content: String
        let raw: String?
        let text: String
    }

    private struct StyledKey: Hashable {
        let text: String
        let raw: String?
        let own: String?
    }

    private static var bubbleTextCache: [String: TextEntry] = [:]
    private static var imagesCache: [String: [RichImage]] = [:]
    private static var botPostsCache: [String: [BotPost]] = [:]
    private static var styledCache: [StyledKey: AttributedString] = [:]
    private static var sectionsInput: [ChatMessage]?
    private static var sectionsOutput: [DaySection] = []

    /// Actual computes, excluding cache hits (perf-guard tests only).
    static var bubbleTextComputes = 0
    static var imagesComputes = 0
    static var botPostsComputes = 0
    static var styledComputes = 0
    static var sectionComputes = 0

    /// (text, images, posts, styled, sections) compute counts.
    static func renderStats() -> (Int, Int, Int, Int, Int) {
        renderLock.lock()
        defer { renderLock.unlock() }
        return (
            bubbleTextComputes, imagesComputes, botPostsComputes,
            styledComputes, sectionComputes)
    }

    /// Entries held across the parse dicts (cap-guard tests only).
    static func renderCacheCount() -> Int {
        renderLock.lock()
        defer { renderLock.unlock() }
        return bubbleTextCache.count + imagesCache.count
            + botPostsCache.count + styledCache.count
    }

    /// Drop every cached parse + zero the counters (tests only).
    static func resetRenderCaches() {
        renderLock.lock()
        defer { renderLock.unlock() }
        bubbleTextCache.removeAll()
        imagesCache.removeAll()
        botPostsCache.removeAll()
        styledCache.removeAll()
        sectionsInput = nil
        sectionsOutput = []
        bubbleTextComputes = 0
        imagesComputes = 0
        botPostsComputes = 0
        styledComputes = 0
        sectionComputes = 0
    }

    /// Caller holds `renderLock`. Overflow clears all (sections included).
    private static func evictRenderCachesLocked() {
        let n = bubbleTextCache.count + imagesCache.count
            + botPostsCache.count + styledCache.count
        guard n >= maxRenderCacheEntries else { return }
        bubbleTextCache.removeAll()
        imagesCache.removeAll()
        botPostsCache.removeAll()
        styledCache.removeAll()
        sectionsInput = nil
        sectionsOutput = []
    }

    // MARK: - Span ranges over plain content

    /// Ranges of `needle` occurrences (literal, case-sensitive).
    static func ranges(of needle: String, in hay: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var rest = hay.startIndex ..< hay.endIndex
        while let r = hay.range(of: needle, range: rest) {
            out.append(r)
            rest = r.upperBound ..< hay.endIndex
        }
        return out
    }

    /// `code` spans: single-backtick pairs, no newlines inside.
    public static func backtickSpans(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var rest = text.startIndex ..< text.endIndex
        while let open = text.range(of: "`", range: rest) {
            let after = open.upperBound ..< text.endIndex
            guard let shut = text.range(of: "`", range: after) else { break }
            let inner = open.upperBound ..< shut.lowerBound
            if !text[inner].isEmpty, !text[inner].contains("\n") { out.append(inner) }
            rest = shut.upperBound ..< text.endIndex
        }
        return out
    }

    /// Tick-stripped text + the code ranges in the STRIPPED coordinates.
    /// Only valid spans (per `backtickSpans`) lose their ticks; stray
    /// ticks (unbalanced, empty, newline-spanning) stay literal so the
    /// bubble never eats user text. The styled builder runs every span
    /// miner on `clean`, so ticks vanish from display while plain-text
    /// paths (copy, quote previews) keep the source untouched.
    public static func stripBackticks(_ text: String) -> (clean: String, spans: [Range<String.Index>]) {
        let inners = backtickSpans(in: text)
        guard !inners.isEmpty else { return (text, []) }
        var clean = ""
        clean.reserveCapacity(text.count)
        var spans: [Range<String.Index>] = []
        var cursor = text.startIndex
        for inner in inners {
            clean += text[cursor ..< text.index(before: inner.lowerBound)]
            let start = clean.endIndex
            clean += text[inner]
            spans.append(start ..< clean.endIndex)
            cursor = text.index(after: inner.upperBound)
        }
        clean += text[cursor...]
        return (clean, spans)
    }

    // MARK: - AttributedString builder

    /// Semantic body: mention spans tagged `mention` (`.own` for the
    /// owner, else `.other`), code blocks + backtick spans tagged
    /// `codeRole` (+ `codeToken` syntax buckets), URLs tagged `link`.
    /// No fonts or colors — the UI maps these (MessageTextAttributes).
    /// Runs over `renderText` (shortcodes expanded), so spans land on what
    /// the bubble shows. `highlighting` names the owner; nil (or blank)
    /// marks every mention `.other`.
    public static func attributedBody(for message: ChatMessage, highlighting ownName: String? = nil) -> AttributedString {
        attributedBody(text: renderText(for: message), raw: message.raw, highlighting: ownName)
    }

    /// One mined mention name against the owner name: trimmed, one
    /// leading `@` stripped (mined `<at>@Name</at>` inner text carries
    /// the sigil; the owner name never does), case-insensitive.
    /// Blank owners — or blank bare names — never match.
    public static func isOwnerMention(_ name: String, ownName: String?) -> Bool {
        guard let own = ownName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !own.isEmpty
        else { return false }
        let bare = Mentions.bareName(name)
        return !bare.isEmpty && bare.caseInsensitiveCompare(own) == .orderedSame
    }

    /// Styled body over explicit text. The bubble passes `bubbleText`
    /// (bot posts drop attachment-block prose), so spans land on what
    /// the bubble shows; miners still read `raw`. Memoized on the full
    /// inputs: repeat body-evals reuse the styled value.
    public static func attributedBody(text: String, raw: String?, highlighting ownName: String? = nil) -> AttributedString {
        let key = StyledKey(text: text, raw: raw, own: ownName)
        renderLock.lock()
        if let hit = styledCache[key] {
            renderLock.unlock()
            return hit
        }
        renderLock.unlock()
        let out = attributedBodyUncached(text: text, raw: raw, highlighting: ownName)
        renderLock.lock()
        styledComputes += 1
        evictRenderCachesLocked()
        styledCache[key] = out
        renderLock.unlock()
        return out
    }

    /// One shared link detector (NSRegularExpression matching is
    /// thread-safe; construction is the expensive part).
    private static let sharedLinkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedBodyUncached(text: String, raw: String?, highlighting ownName: String? = nil) -> AttributedString {
        // Fenced blocks (top10-code): fence-less messages keep the legacy
        // path below bit-identical; fenced ones split into prose/code
        // segments (fences stripped like backticks, code highlighted).
        if CodeBlocks.containsFence(in: text) {
            return attributedBodyFenced(text: text, raw: raw, highlighting: ownName)
        }
        // Backticks are markup, not content: every miner below runs on
        // the tick-stripped text, so `code` renders mono without ticks.
        let stripped = stripBackticks(text)
        let clean = stripped.clean
        var a = AttributedString(clean)
        func convert(_ r: Range<String.Index>) -> Range<AttributedString.Index>? {
            Range(r, in: a)
        }
        // Mentions (<at> tags + Mention spans; fall back to @token scan).
        var names = mentions(fromRaw: raw)
        if names.isEmpty {
            names = mentionTokens(in: clean)
        }
        for n in names {
            let role: MentionRole = isOwnerMention(n, ownName: ownName) ? .own : .other
            for r in ranges(of: n, in: clean) {
                guard let ar = convert(r) else { continue }
                a[ar].mention = role
            }
        }
        // Code blocks from <pre> + backtick spans. Server snippets get
        // auto-detected token colors too (top10-code; foreground only,
        // so font/wash pins never shift).
        for b in codeBlocks(fromRaw: raw) {
            for r in ranges(of: b, in: clean) {
                guard let ar = convert(r) else { continue }
                a[ar].codeRole = .preformatted
                applyHighlight(code: String(clean[r]), language: nil, to: &a, base: r, clean: clean)
            }
        }
        for r in stripped.spans {
            guard let ar = convert(r) else { continue }
            a[ar].codeRole = .inline
        }
        // URLs.
        if let det = Self.sharedLinkDetector {
            let ns = clean as NSString
            for m in det.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url,
                      let r = Range(m.range, in: clean),
                      let ar = convert(r)
                else { continue }
                a[ar].link = url
            }
        }
        return a
    }

    // MARK: - Fenced code styling (top10-code lane)

    /// Styled body for messages holding ``` fences: prose segments get the
    /// legacy styling (mentions, `<pre>` mono, `ticks`, links); code
    /// segments get mono + syntax colors and NOTHING else (no mention
    /// bolds, no link underlines, no shortcode expansion — code is
    /// literal). Concatenated in order; fence lines never display (the
    /// content keeps them, so Copy/forward stay faithful).
    static func attributedBodyFenced(text: String, raw: String?, highlighting ownName: String?) -> AttributedString {
        var out = AttributedString("")
        for seg in CodeBlocks.segments(in: text) {
            switch seg.kind {
            case .prose:
                out += attributedProseSegment(seg.text, raw: raw, highlighting: ownName)
            case .code:
                out += attributedCodeSegment(seg.text, language: seg.language)
            }
        }
        return out
    }

    /// Legacy styling over one prose segment (same miners as the
    /// fence-less path, scoped to the segment).
    static func attributedProseSegment(_ text: String, raw: String?, highlighting ownName: String?) -> AttributedString {
        let stripped = stripBackticks(text)
        let clean = stripped.clean
        var a = AttributedString(clean)
        func convert(_ r: Range<String.Index>) -> Range<AttributedString.Index>? {
            Range(r, in: a)
        }
        var names = mentions(fromRaw: raw)
        if names.isEmpty {
            names = mentionTokens(in: clean)
        }
        for n in names {
            let role: MentionRole = isOwnerMention(n, ownName: ownName) ? .own : .other
            for r in ranges(of: n, in: clean) {
                guard let ar = convert(r) else { continue }
                a[ar].mention = role
            }
        }
        // Server `<pre>` snippets: same mono as the fence-less path,
        // plus auto-detected token colors (foreground only).
        for b in codeBlocks(fromRaw: raw) {
            for r in ranges(of: b, in: clean) {
                guard let ar = convert(r) else { continue }
                a[ar].codeRole = .preformatted
                applyHighlight(code: String(clean[r]), language: nil, to: &a, base: r, clean: clean)
            }
        }
        for r in stripped.spans {
            guard let ar = convert(r) else { continue }
            a[ar].codeRole = .inline
        }
        if let det = Self.sharedLinkDetector {
            let ns = clean as NSString
            for m in det.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url,
                      let r = Range(m.range, in: clean),
                      let ar = convert(r)
                else { continue }
                a[ar].link = url
            }
        }
        return a
    }

    /// One fenced code block: whole range `codeRole = .block` + highlight
    /// tokens (no mention/link attributes inside code).
    /// Empty code → empty string.
    static func attributedCodeSegment(_ code: String, language: String?) -> AttributedString {
        var a = AttributedString(code)
        guard !code.isEmpty else { return a }
        guard let whole = Range(code.startIndex ..< code.endIndex, in: a) else { return a }
        a[whole].codeRole = .block
        applyHighlight(code: code, language: language, to: &a, base: code.startIndex ..< code.endIndex, clean: code)
        return a
    }

    /// Tag `CodeHighlight` tokens for `code` onto `target` (`.plain`
    /// runs stay untagged). `base`
    /// is `code`'s range inside `clean` (same string for code segments, a
    /// `<pre>`-matched subrange for prose). Runs concatenate to `code`
    /// exactly, so walking by run length never misaligns; any failure
    /// inside the engine degrades to `.plain` (untagged).
    static func applyHighlight(
        code: String, language: String?,
        to target: inout AttributedString,
        base: Range<String.Index>, clean: String
    ) {
        guard !code.isEmpty else { return }
        var cursor = base.lowerBound
        for run in CodeHighlight.runs(code: code, language: language) {
            guard !run.text.isEmpty else { continue }
            let next = clean.index(cursor, offsetBy: run.text.count, limitedBy: base.upperBound)
                ?? base.upperBound
            if run.token != .plain,
               let ar = Range(cursor ..< next, in: target)
            {
                target[ar].codeToken = run.token
            }
            cursor = next
        }
    }

    // MARK: - Rich media (om-richmedia lane)

    /// One `<img>` mined from raw message HTML.
    public struct RichImage: Sendable, Equatable, Identifiable {
        public var id: String { url }
        public let url: String
        public let alt: String
        /// Emoticon art: explicit w/h ≤ 32, an emoticon marker attr, or a
        /// shortcode alt like `(smile)`. Renders small, not as a photo.
        public let isEmoticon: Bool

        public init(url: String, alt: String = "", isEmoticon: Bool = false) {
            self.url = url
            self.alt = alt
            self.isEmoticon = isEmoticon
        }
    }

    /// `<img …>` tags in raw HTML, in order. Tags without `src` are dropped.
    /// Tag/attr names are case-insensitive; values may be double-quoted,
    /// single-quoted, or bare. `alt` is entity-decoded.
    public static func images(fromRaw raw: String?) -> [RichImage] {
        guard let raw else { return [] }
        renderLock.lock()
        if let hit = imagesCache[raw] {
            renderLock.unlock()
            return hit
        }
        renderLock.unlock()
        let out = imagesUncached(fromRaw: raw)
        renderLock.lock()
        imagesComputes += 1
        evictRenderCachesLocked()
        imagesCache[raw] = out
        renderLock.unlock()
        return out
    }

    static func imagesUncached(fromRaw raw: String) -> [RichImage] {
        imgTags(in: raw).compactMap { tag in
            let attrs = attributes(of: tag)
            guard let src = attrs["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !src.isEmpty
            else { return nil }
            return RichImage(
                url: decodeEntities(src),
                alt: decodeEntities(attrs["alt"] ?? ""),
                isEmoticon: isEmoticonTag(attrs))
        }
    }

    /// Raw `<img …>` tag spans (case-insensitive open, first `>` closes).
    static func imgTags(in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let s = rest.range(of: "<img", options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">")
        {
            out.append(String(rest[s.lowerBound ... gt]))
            rest = rest[rest.index(after: gt)...]
        }
        return out
    }

    /// Attr map of one tag (names lowercased). Tolerates missing values.
    static func attributes(of tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = tag.startIndex
        // Skip "<tagname" (any tag: img, a, attachment, ...).
        if tag.hasPrefix("<") {
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i].isLetter || tag[i].isNumber {
                i = tag.index(after: i)
            }
        }
        func skipSpace() {
            while i < tag.endIndex, tag[i].isWhitespace || tag[i] == "/" { i = tag.index(after: i) }
        }
        while i < tag.endIndex {
            skipSpace()
            guard i < tag.endIndex, tag[i] != ">" else { break }
            let ns = i
            while i < tag.endIndex, tag[i].isLetter || tag[i].isNumber || tag[i] == "-" || tag[i] == "_" || tag[i] == ":" {
                i = tag.index(after: i)
            }
            let name = String(tag[ns ..< i]).lowercased()
            guard !name.isEmpty else {
                // Junk char (e.g. `?`): skip one, keep scanning.
                i = tag.index(after: i)
                continue
            }
            skipSpace()
            var value = ""
            if i < tag.endIndex, tag[i] == "=" {
                i = tag.index(after: i)
                skipSpace()
                if i < tag.endIndex, tag[i] == "\"" || tag[i] == "'" {
                    let q = tag[i]
                    i = tag.index(after: i)
                    let vs = i
                    while i < tag.endIndex, tag[i] != q { i = tag.index(after: i) }
                    value = String(tag[vs ..< i])
                    if i < tag.endIndex { i = tag.index(after: i) }
                } else {
                    let vs = i
                    while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != ">", tag[i] != "\"", tag[i] != "'" {
                        i = tag.index(after: i)
                    }
                    value = String(tag[vs ..< i])
                }
            }
            attrs[name] = value
        }
        return attrs
    }

    /// Emoticon iff explicit w/h both ≤ 32, an emoticon marker attr, or a
    /// `(code)` alt. Percent/other non-integer sizes never count as small.
    static func isEmoticonTag(_ attrs: [String: String]) -> Bool {
        if let w = attrs["width"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           let h = attrs["height"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           w <= 32, h <= 32
        {
            return true
        }
        for k in ["class", "itemtype", "type", "emoticon"] {
            if let v = attrs[k]?.lowercased(), v.contains("emoticon") { return true }
        }
        if let alt = attrs["alt"]?.trimmingCharacters(in: .whitespaces),
           alt.count >= 3, alt.hasPrefix("("), alt.hasSuffix(")")
        {
            return true
        }
        return false
    }

    // MARK: - Emoji (unicode native + Teams/Skype `(code)` shortcodes)

    /// Classic Teams/Skype picker shortcuts. Unknown codes pass through
    /// untouched (never mangle prose like `(see note)`).
    public static let emojiShortcodes: [String: String] = [
        "smile": "🙂", "bigsmile": "😁", "laugh": "😄", "wink": "😉",
        "sad": "😞", "cry": "😢", "tears": "😂", "angry": "😠",
        "cool": "😎", "nerd": "🤓", "surprised": "😮", "shock": "😲",
        "confused": "😕", "thinking": "🤔", "kiss": "😘", "sleepy": "😴",
        "sleep": "😴", "sick": "🤢", "devil": "😈", "angel": "😇",
        "ghost": "👻", "skull": "💀", "clown": "🤡",
        "heart": "❤️", "hearts": "💕", "brokenheart": "💔", "like": "👍",
        "thumbsup": "👍", "y": "👍", "dislike": "👎", "thumbsdown": "👎",
        "n": "👎", "clap": "👏", "pray": "🙏", "muscle": "💪",
        "handshake": "🤝", "wave": "👋", "eyes": "👀", "fire": "🔥",
        "star": "⭐", "check": "✅", "party": "🥳", "tada": "🎉",
        "gift": "🎁", "cake": "🎂", "coffee": "☕", "beer": "🍺",
        "rocket": "🚀", "sun": "☀️", "moon": "🌙", "rainbow": "🌈",
        "bell": "🔔", "dance": "💃", "punch": "👊", "fistbump": "🤜",
    ]

    /// What the bubble shows: `content` with `(code)` shortcodes expanded to
    /// unicode. Native unicode passes through. Backtick spans are left
    /// alone, so `` `(smile)` `` stays literal.
    public static func renderText(for message: ChatMessage) -> String {
        expandShortcodes(message.content)
    }

    public static func expandShortcodes(_ text: String) -> String {
        // Exclusion ranges: backtick spans widened to swallow the ticks,
        // plus fenced code blocks (top10-code: `(code)` inside code stays
        // literal). Sorted, non-overlapping; fences win overlaps.
        let excl = mergeExclusions(
            fences: CodeBlocks.codeRanges(in: text),
            ticks: backtickSpans(in: text).map { r in
                text.index(before: r.lowerBound) ..< text.index(after: r.upperBound)
            })
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        for r in excl {
            out += expandSegment(String(text[cursor ..< r.lowerBound]))
            out += text[r]
            cursor = r.upperBound
        }
        out += expandSegment(String(text[cursor...]))
        return out
    }

    /// Merge two sorted non-overlapping exclusion lists; fence ranges
    /// win (tick spans inside code are redundant — the fence already
    /// excludes them).
    static func mergeExclusions(
        fences: [Range<String.Index>], ticks: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        guard !fences.isEmpty else { return ticks }
        let kept = ticks.filter { t in !fences.contains { $0.overlaps(t) } }
        return (fences + kept).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// One `(code)` pass over code-free text. Case-insensitive lookup.
    static func expandSegment(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "(" else { out.append(s[i]); i = s.index(after: i); continue }
            var j = s.index(after: i)
            var count = 0
            while j < s.endIndex, count < 20, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "+" || s[j] == "-" {
                j = s.index(after: j); count += 1
            }
            if j < s.endIndex, s[j] == ")", count > 0,
               let emoji = emojiShortcodes[String(s[s.index(after: i) ..< j]).lowercased()]
            {
                out += emoji
                i = s.index(after: j)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    /// `@Name` tokens when no `<at>` tags exist (plain-text path).
    /// Matches @ + letters/spaces/commas/dots/apostrophes, up to 40 chars.
    static func mentionTokens(in text: String) -> [String] {
        var out: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "@" else { i = text.index(after: i); continue }
            var j = text.index(after: i)
            var count = 0
            while j < text.endIndex, count < 40 {
                let c = text[j]
                if c.isLetter || c == " " || c == "," || c == "." || c == "'" || c == "-" {
                    j = text.index(after: j); count += 1
                } else { break }
            }
            let name = String(text[text.index(after: i) ..< j])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
            i = j
        }
        return out
    }

    // MARK: - Bot posts (om-botposts lane)

    /// One RSS/bot/card row: a title plus an optional link target.
    /// Mined from `raw` (attachment blocks or card JSON). The bubble
    /// renders one native row per post, so structured posts never
    /// collapse into a blank bubble or a raw JSON blob.
    public struct BotPost: Sendable, Equatable {
        public let title: String
        public let url: String?

        public init(title: String, url: String? = nil) {
            self.title = title
            self.url = url
        }
    }

    /// Card content-type markers (same set as ost `has_card_payload`).
    static let cardMarkers = [
        "o365connector", "adaptivecard", "messagecard",
        "application/vnd.microsoft",
    ]

    /// Max rows per bubble (RSS digests are small; caps a hostile blob).
    static let maxBotRows = 10

    /// Rows for one message: `<attachment>` blocks first (title + link
    /// mined from each block's inner HTML), else a card-JSON payload
    /// mined for title + URL. Anything else (plain text, images) yields
    /// no rows. Callers pass `message.raw ?? message.content`.
    public static func botPosts(fromRaw raw: String?) -> [BotPost] {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        renderLock.lock()
        if let hit = botPostsCache[raw] {
            renderLock.unlock()
            return hit
        }
        renderLock.unlock()
        let out = botPostsUncached(fromRaw: raw)
        renderLock.lock()
        botPostsComputes += 1
        evictRenderCachesLocked()
        botPostsCache[raw] = out
        renderLock.unlock()
        return out
    }

    static func botPostsUncached(fromRaw raw: String) -> [BotPost] {
        let blocks = innerTexts(of: "attachment", in: raw)
        if !blocks.isEmpty {
            return blocks.compactMap(postFromAttachment).prefix(maxBotRows).map { $0 }
        }
        guard looksLikeJSONObject(raw) else { return [] }
        return cardPosts(fromJSON: raw)
    }

    /// One attachment block → one row. The first link wins: its anchor
    /// text is the title (stripped block text when the anchor is bare,
    /// the URL itself when that is empty too). Link-less blocks fall
    /// back to their collapsed text; empty blocks are unparseable (nil).
    static func postFromAttachment(_ inner: String) -> BotPost? {
        if let link = links(in: inner).first(where: { !$0.href.isEmpty }) {
            let anchor = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = decodeEntities(stripTags(inner))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = !anchor.isEmpty ? anchor : (!stripped.isEmpty ? stripped : link.href)
            return BotPost(title: title, url: link.href)
        }
        let title = decodeEntities(stripTags(inner))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : BotPost(title: String(title.prefix(140)))
    }

    /// `(anchor text, href)` pairs in order. The open match requires a
    /// tag boundary after `<a`, so `<attachment>`/`<at>` never match.
    /// Tag/attr names are case-insensitive; href-less anchors are dropped.
    static func links(in html: String) -> [(text: String, href: String)] {
        var out: [(text: String, href: String)] = []
        var rest = html[...]
        while let s = rest.range(of: "<a", options: .caseInsensitive) {
            let afterA = rest.index(s.lowerBound, offsetBy: 2, limitedBy: rest.endIndex)
            guard let afterA, afterA < rest.endIndex else { break }
            let boundary = rest[afterA]
            guard boundary.isWhitespace || boundary == ">" || boundary == "/" else {
                rest = rest[afterA...]
                continue
            }
            guard let gt = rest[s.upperBound...].firstIndex(of: ">"),
                  let e = rest[gt...].range(of: "</a>", options: .caseInsensitive)
            else { break }
            let open = String(rest[s.lowerBound ... gt])
            let href = attributes(of: open)["href"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !href.isEmpty {
                let text = decodeEntities(stripTags(String(
                    rest[rest.index(after: gt) ..< e.lowerBound])))
                out.append((text: text, href: decodeEntities(href)))
            }
            rest = rest[e.upperBound...]
        }
        return out
    }

    /// Trimmed text starting with `{` (a probable JSON payload).
    static func looksLikeJSONObject(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.contains("}")
    }

    /// True for card JSON: a JSON object carrying a card content-type
    /// marker. Such blobs never render as bubble text (rows or the
    /// placeholder replace them).
    public static func isCardPayload(_ text: String) -> Bool {
        guard looksLikeJSONObject(text) else { return false }
        let lower = text.lowercased()
        return cardMarkers.contains { lower.contains($0) }
    }

    /// True when the bubble text must be hidden: card-marked JSON, or
    /// any JSON object that already yielded rows (raw JSON is noise
    /// once rows exist). Plain prose + rows coexist (mixed bot posts).
    public static func suppressText(content: String, posts: [BotPost]) -> Bool {
        isCardPayload(content)
            || (looksLikeJSONObject(content) && !posts.isEmpty)
    }

    /// Body text for the bubble's text area: `renderText`, except bot
    /// posts show only the prose OUTSIDE attachment blocks (the rows
    /// carry the block titles, so showing both would duplicate them),
    /// and suppressed JSON shows nothing. Replies keep `renderText`
    /// (the quote block owns attribution; never rewrite reply bodies).
    public static func bubbleText(for message: ChatMessage) -> String {
        renderLock.lock()
        if let e = bubbleTextCache[message.id],
           e.content == message.content, e.raw == message.raw
        {
            renderLock.unlock()
            return e.text
        }
        renderLock.unlock()
        let text = bubbleTextUncached(for: message)
        renderLock.lock()
        bubbleTextComputes += 1
        evictRenderCachesLocked()
        bubbleTextCache[message.id] = TextEntry(
            content: message.content, raw: message.raw, text: text)
        renderLock.unlock()
        return text
    }

    static func bubbleTextUncached(for message: ChatMessage) -> String {
        let posts = botPosts(fromRaw: message.raw ?? message.content)
        if suppressText(content: message.content, posts: posts) { return "" }
        guard !posts.isEmpty, message.reply_to == nil, let raw = message.raw else {
            return renderText(for: message)
        }
        let outside = expandShortcodes(outsideText(fromRaw: raw))
        // Title-dup (om-lt3-titlededupe): Media_Card digests repeat the
        // card title as the outside prose ("Digest" body + "Digest" row).
        // Rows carry titles, so a dup outside line renders nothing (once).
        if isTitleDup(outside, posts: posts) { return "" }
        return outside
    }

    /// True when trimmed `text` equals a row title (case-insensitive):
    /// the bubble would show the same string twice (text + row).
    /// Equality only — prose merely containing a title still shows.
    static func isTitleDup(_ text: String, posts: [BotPost]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        return posts.contains {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == t
        }
    }

    /// Stripped text with `<attachment>…</attachment>` spans removed.
    static func outsideText(fromRaw raw: String) -> String {
        decodeEntities(stripTags(removeAttachmentBlocks(from: raw)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw HTML minus attachment spans (case-insensitive). Unterminated
    /// blocks are kept (malformed input still renders as text).
    static func removeAttachmentBlocks(from html: String) -> String {
        var result = ""
        var rest = html[...]
        let open = "<attachment", close = "</attachment>"
        while let s = rest.range(of: open, options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">"),
              let e = rest[gt...].range(of: close, options: .caseInsensitive)
        {
            result += rest[..<s.lowerBound]
            rest = rest[e.upperBound...]
        }
        result += rest
        return result
    }

    /// True when the bubble would otherwise render empty but carries a
    /// server payload: no visible text, no images, no rows, yet
    /// content/raw is non-blank. The bubble shows the placeholder
    /// instead — a thread never shows a blank bubble for server data.
    /// Truly empty synthetic bubbles (no content, no raw) stay blank.
    public static func showsPlaceholder(for message: ChatMessage) -> Bool {
        // Rendered cards own the bubble: never placeholder beside them.
        if MessageBubbleState.shouldShowCards(for: message) { return false }
        let posts = botPosts(fromRaw: message.raw ?? message.content)
        if !posts.isEmpty { return false }
        if !bubbleText(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if !images(fromRaw: message.raw).isEmpty { return false }
        let contentBlank = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rawBlank = (message.raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(contentBlank && rawBlank)
    }

    /// Card JSON → rows: the top object plus each `attachments[]`
    /// element (Adaptive cards nest under `content`). Each candidate
    /// contributes title (first `title`/`text`/`summary`/`name` string)
    /// + URL (link-keyed first, else any http(s) string). Candidates
    /// with neither are skipped (unparseable → the placeholder covers
    /// the bubble).
    static func cardPosts(fromJSON text: String) -> [BotPost] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var candidates: [Any] = [json]
        if let top = json as? [String: Any],
           let attachments = top["attachments"] as? [Any]
        {
            candidates += attachments
        }
        var out: [BotPost] = []
        for candidate in candidates.prefix(maxBotRows) {
            let obj = (candidate as? [String: Any])?["content"] ?? candidate
            let title = firstTitle(in: obj, depth: 6)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = firstKeyedURL(in: obj, depth: 6)
                ?? firstURLString(in: obj, depth: 6).flatMap { firstURL(in: $0) }
            if title.isEmpty, url == nil { continue }
            out.append(BotPost(
                title: title.isEmpty ? url! : title,
                url: url))
        }
        return out
    }

    /// First http(s) URL under a link-ish key (`uri`, `url`, `target`,
    /// `openUri`, `contentUrl`, `webUrl`, `href`), depth-capped. Keys
    /// are matched case-insensitively. Preferred over any-URL so
    /// incidental URLs (`@context`, avatars) never win over the card's
    /// real target.
    static func firstKeyedURL(in value: Any, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        if let dict = value as? [String: Any] {
            for (key, found) in dict
                where ["url", "uri", "target", "openuri", "contenturl", "weburl", "href"]
                .contains(key.lowercased())
            {
                if let s = found as? String, let url = firstURL(in: s) { return url }
            }
            for (_, found) in dict {
                if let hit = firstKeyedURL(in: found, depth: depth - 1) { return hit }
            }
            return nil
        }
        if let array = value as? [Any] {
            for element in array {
                if let hit = firstKeyedURL(in: element, depth: depth - 1) { return hit }
            }
        }
        return nil
    }

    /// First non-empty string under a title-ish key, depth-capped.
    /// Keys are matched case-insensitively (`Title`, `TITLE`, ...).
    static func firstTitle(in value: Any, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        if let dict = value as? [String: Any] {
            for wanted in ["title", "text", "summary", "name"] {
                for (key, found) in dict where key.lowercased() == wanted {
                    if let s = found as? String,
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        return s
                    }
                }
            }
            for (_, found) in dict {
                if let hit = firstTitle(in: found, depth: depth - 1) { return hit }
            }
            return nil
        }
        if let array = value as? [Any] {
            for element in array {
                if let hit = firstTitle(in: element, depth: depth - 1) { return hit }
            }
        }
        return nil
    }

    /// First string containing an http(s) URL, depth-capped.
    static func firstURLString(in value: Any, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        if let s = value as? String {
            return firstURL(in: s) == nil ? nil : s
        }
        if let dict = value as? [String: Any] {
            for (_, found) in dict {
                if let hit = firstURLString(in: found, depth: depth - 1) { return hit }
            }
            return nil
        }
        if let array = value as? [Any] {
            for element in array {
                if let hit = firstURLString(in: element, depth: depth - 1) { return hit }
            }
        }
        return nil
    }

    /// First `https?://…` substring, cut at whitespace or a JSON/HTML
    /// delimiter. Nil when none is present.
    static func firstURL(in text: String) -> String? {
        var best: String.Index?
        for scheme in ["https://", "http://"] {
            if let r = text.range(of: scheme, options: .caseInsensitive),
               best == nil || r.lowerBound < best!
            {
                best = r.lowerBound
            }
        }
        guard let start = best else { return nil }
        var end = start
        while end < text.endIndex {
            let c = text[end]
            if c.isWhitespace || c == "\"" || c == "'" || c == "}" || c == "]"
                || c == ")" || c == "<" || c == "\\"
            {
                break
            }
            end = text.index(after: end)
        }
        let url = String(text[start ..< end])
        return URL(string: url) == nil ? nil : url
    }
}

/// Shared local-time plumbing (fid-time D8/D9). One locked
/// formatter set for every user-visible clock: ISO parsing mirrors
/// `ConversationStore.messageDate` (fractional + plain + no-offset
/// prefix read as UTC), clocks render the caller's locale short
/// style ("2:12 PM" en_US, "14:12" de_DE) in the caller's zone.
public enum TeamsTime {
    private static let lock = NSLock()

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFallback: DateFormatter = {
        let g = DateFormatter()
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        g.timeZone = TimeZone(secondsFromGMT: 0)
        g.locale = Locale(identifier: "en_US_POSIX")
        return g
    }()

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayMonthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Tolerant server-stamp parse (nil for garbage/empty). Same
    /// inputs as `ConversationStore.messageDate` give the same Dates.
    public static func parseISO(_ s: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = isoFrac.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        guard s.count >= 19 else { return nil }
        return isoFallback.date(from: String(s.prefix(19)))
    }

    /// Locale short clock in `timeZone` ("2:12 PM" en_US).
    public static func clock(
        _ date: Date, timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        clockFmt.timeZone = timeZone
        clockFmt.locale = locale
        return clockFmt.string(from: date)
    }

    /// "22 Sep" in `timeZone` (English abbrevs, legacy shape).
    public static func dayMonth(
        _ date: Date, timeZone: TimeZone = .current
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        dayMonthFmt.timeZone = timeZone
        return dayMonthFmt.string(from: date)
    }

    /// "yyyy-MM-dd" in `timeZone`.
    public static func dayKey(
        _ date: Date, timeZone: TimeZone = .current
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        dayKeyFmt.timeZone = timeZone
        return dayKeyFmt.string(from: date)
    }
}

/// Shared day formatters (om-s6-renderparse). DateFormatter is not
/// thread-safe, so every use runs under the lock with a refreshed
/// timezone (same strings as a fresh formatter, none of the allocs).
private final class DayFormatBox {
    private let lock = NSLock()
    private let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The app's one absolute day form ("Sep 22, 2026" in en_US): the
    /// locale's medium-style month-day-year, as file dates use.
    private let label: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    func date(from key: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        parse.timeZone = TimeZone.current
        return parse.date(from: key)
    }

    func print(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        label.timeZone = TimeZone.current
        return label.string(from: date)
    }
}
