// CatchUpFilter.swift — CATCHTABS lane: what a catch-up may read.
//
// 1. Period bound (hard): a summary for "24 hours" reads only messages
//    stamped inside the last 24 hours. Unparseable stamps never pass.
// 2. Deterministic noise filter before the model: social chit-chat
//    (food/coffee orders, greetings, thanks/lol/emoji-only, reaction
//    notices, birthdays/kudos-only, weekend small talk) and time-bound
//    immediacy asks whose moment has passed ("anyone around?", "running
//    late", "quick call now?").
// 3. Salience ranking: asks/questions to the user, mentions, decisions,
//    deadlines/dates, blockers, work files/links and plan changes score
//    up; "Not important" feedback scores similar items and that chat
//    down. When a conversation overflows the model window, the lowest
//    scores drop first (not simply the oldest).
// 4. Bullet pass after the model: deterministic social bullets and
//    bullets like a dismissed one drop, then the model rates the rest
//    0–3 (plain text, "number: rating") and only ≥ 2 stay.
import Foundation

// MARK: - Periods

/// Catch Up period tabs. Raw values double as evidence route values.
public enum CatchUpPeriod: String, CaseIterable, Identifiable, Sendable, Codable {
    case day = "24h"
    case threeDays = "3d"
    case fiveDays = "5d"
    case twoWeeks = "2w"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "24 Hours"
        case .threeDays: "3 Days"
        case .fiveDays: "5 Days"
        case .twoWeeks: "2 Weeks"
        }
    }

    public var interval: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .threeDays: 3 * 24 * 3600
        case .fiveDays: 5 * 24 * 3600
        case .twoWeeks: 14 * 24 * 3600
        }
    }

    /// Oldest instant a message may carry to belong to this period.
    public func cutoff(now: Date) -> Date { now.addingTimeInterval(-interval) }

    /// The longest period: nothing older is ever held.
    public static let longest: CatchUpPeriod = .twoWeeks
    public static let defaultsKey = "catchup.period"
}

public enum CatchUpBound {
    /// Messages stamped at or after the period's cutoff, in input order.
    /// Unparseable stamps are dropped: an age that can't be read can't
    /// be proven to be inside the period.
    public static func messages(_ messages: [ChatMessage], period: CatchUpPeriod, now: Date) -> [ChatMessage] {
        let cutoff = period.cutoff(now: now)
        return messages.filter { m in
            guard let d = TeamsTime.parseISO(m.timestamp.trimmingCharacters(in: .whitespaces)) else { return false }
            return d >= cutoff
        }
    }

    public static func date(_ m: ChatMessage) -> Date? {
        TeamsTime.parseISO(m.timestamp.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Filter context

/// Everything the filter needs besides the messages (a value: the
/// engine runs off the main actor).
public struct CatchUpFilterContext: Sendable {
    public var now: Date
    public var chatID: String?
    public var ownerMRI: String?
    public var ownerDisplayName: String
    /// Lowercased names of Teams tags that include the user.
    public var ownerTags: Set<String>
    public var feedback: CatchUpFeedback

    public init(now: Date, chatID: String? = nil, ownerMRI: String? = nil, ownerDisplayName: String = "",
                ownerTags: Set<String> = [], feedback: CatchUpFeedback = CatchUpFeedback())
    {
        self.now = now
        self.chatID = chatID
        self.ownerMRI = ownerMRI
        self.ownerDisplayName = ownerDisplayName
        self.ownerTags = ownerTags
        self.feedback = feedback
    }
}

// MARK: - "Not important" feedback (value)

/// Dismissed bullets, stored locally. Hides the exact bullet and
/// down-weights similar messages/bullets and the conversation.
public struct CatchUpFeedback: Sendable, Codable, Equatable {
    public struct Dismissal: Sendable, Codable, Equatable {
        public var chatID: String?
        public var text: String
        public var date: Date
    }

    public var dismissals: [Dismissal] = []
    public static let capacity = 200
    /// Word overlap (Jaccard) at or above which two texts are "similar".
    public static let similarity = 0.5

    public init(dismissals: [Dismissal] = []) { self.dismissals = dismissals }

    public mutating func dismiss(_ text: String, chatID: String?, now: Date = Date()) {
        let norm = CatchUpNoise.normalized(text)
        guard !norm.isEmpty else { return }
        dismissals.removeAll { $0.text == norm && $0.chatID == chatID }
        dismissals.append(Dismissal(chatID: chatID, text: norm, date: now))
        if dismissals.count > Self.capacity { dismissals.removeFirst(dismissals.count - Self.capacity) }
    }

    /// The exact bullet was dismissed (in this conversation, or anywhere
    /// when `chatID` is nil).
    public func isHidden(_ text: String, chatID: String?) -> Bool {
        let norm = CatchUpNoise.normalized(text)
        return dismissals.contains { $0.text == norm && (chatID == nil || $0.chatID == nil || $0.chatID == chatID) }
    }

    /// True when `text` reads like a dismissed bullet (any conversation).
    public func isSimilarToDismissed(_ text: String) -> Bool {
        let words = CatchUpNoise.words(text)
        guard words.count >= 2 else { return false }
        return dismissals.contains { CatchUpNoise.jaccard(words, CatchUpNoise.words($0.text)) >= Self.similarity }
    }

    /// Salience penalty for a conversation: −1 per two dismissals, max −2.
    public func chatPenalty(_ chatID: String?) -> Int {
        guard let chatID else { return 0 }
        return min(2, dismissals.filter { $0.chatID == chatID }.count / 2)
    }
}

// MARK: - Deterministic noise + salience

public enum CatchUpNoise {
    public enum Reason: String, Sendable, Equatable {
        case empty, emojiOnly, acknowledgment, greeting, food, celebration, smallTalk, reaction, expired
    }

    /// Immediacy asks go stale after this long.
    public static let immediacyLifetime: TimeInterval = 2 * 3600

    // Vocabulary (lowercased, whole words).
    static let ackWords: Set<String> = [
        "thanks", "thank", "you", "thx", "ty", "tysm", "cheers", "lol", "lmao", "rofl", "haha", "hahaha", "hehe",
        "nice", "cool", "great", "awesome", "ok", "okay", "k", "kk", "sure", "yep", "yup", "yes", "yeah", "no",
        "nope", "np", "worries", "sounds", "good", "will", "do", "got", "it", "noted", "perfect", "agreed",
        "same", "love", "congrats", "congratulations", "welcome", "anytime", "much", "so", "very", "all",
        "everyone", "team", "folks", "guys", "a", "lot", "ha", "wow", "omg", "amazing", "brilliant", "yay",
        "woohoo", "hooray", "totally", "indeed", "true", "fair", "enough", "exactly", "done", "ack", "roger",
        "alright", "right", "gotcha", "understood", "appreciate", "appreciated", "again", "kudos", "bravo",
        "morning", "afternoon", "evening", "night", "hi", "hey", "hello", "hiya", "howdy", "yo", "gm", "gn",
        "bye", "later", "cya", "ttyl", "and", "the", "to",
    ]
    static let greetingWords: Set<String> = [
        "hi", "hey", "hello", "hiya", "howdy", "yo", "gm", "morning", "afternoon", "evening", "good", "all",
        "everyone", "team", "folks", "guys", "there", "bye", "night", "gn", "later", "cya", "ttyl", "happy",
        "friday", "monday", "have", "a", "great", "nice", "weekend", "day",
    ]
    static let weekdayOrMonth: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "today", "tomorrow", "tonight",
    ]

    static let food = #"\b(lunch|dinner|breakfast|brunch|coffees?|lattes?|tea|pizzas?|sandwich(es)?|burritos?|tacos?|sushi|bagels?|donuts?|doughnuts?|snacks?|cakes?|cupcakes?|cookies|drinks|beers?|happy hour|food truck|takeout|take-out|doordash|uber ?eats|grubhub|deli|salads?|burgers?|noodles|ramen|pho|thai food|curry|boba|smoothies?)\b"#
    static let foodOrder = #"\b(order(s|ing)?|grab(bing)?|getting|pick(ing)? up|who wants|anyone wants?|want anything|wants anything|menu|hungry|craving|my usual|i'?ll have|count me in|i'?m in|who'?s in|add me|for me)\b"#
    static let celebration = #"\b(happy birthday|birthday|bday|b-day|anniversary|congrats|congratulations|kudos|shout ?-?out|well done|great job|nice work|good job|welcome (to the team|aboard)|farewell|happy (friday|monday|holidays?|new year|thanksgiving)|have a (great|good|nice|lovely) (weekend|day|evening|holiday|vacation)|enjoy (your|the) (weekend|holiday|vacation)|cake in the kitchen)\b"#
    static let smallTalk = #"\b(weekend was|how was your (weekend|trip|holiday|vacation)|hope you (had|have) a|(nice|good|great|lovely|relaxing) weekend|memes?|the game last night|weather|sunny|raining|snowing|so cold|so hot|cute dog|puppy|kitten)\b"#
    static let immediacy = #"\b(any(one|body) (around|free|online|here|up for|in the office)|who('s| is) (around|free|online|in the office|up for)|free (right )?now|quick (call|chat|sync)|hop on a call|jump on a call|running (a bit |a little |\d+ min(ute)?s? )?late|on my way|omw|be there in|brb|stepping (out|away)|back in \d+|heading (out|over)|in the office today|wfh today|at my desk)\b"#
    static let reaction = #"^(liked|loved|laughed at|emphasized|reacted( with [^ ]+)? to)\b"#
    static let gifHost = #"(giphy\.com|tenor\.com|klipy\.com|\.gif\b)"#

    // Salience cues.
    static let ask = #"(\?|\b(can you|could you|would you|will you|please|pls|need you|can someone|could someone|any(one|body) (know|have|seen)|let me know|lmk|thoughts|review|approve|sign off|feedback|take a look|your call|waiting on you|need (a|your) decision)\b)"#
    static let decision = #"\b(decided|decision|agreed (on|to|that)|we('ll| will) go with|going with|finali[sz]ed|approved|signed off|confirmed|chose|settled on|go(ing)? ahead with|(we'?re|we are|we'?ll|we will) (keep|keeping|drop|dropping|stick|sticking|ship|shipping))\b"#
    static let deadline = #"\b(eod|eow|end of (the )?(day|week|month|quarter)|deadline|due|by (mon|tue|wed|thu|fri|sat|sun|tomorrow|today|tonight|noon|\d)|tomorrow|monday|tuesday|wednesday|thursday|friday|next week|this week|(jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]* \d{1,2}|\d{1,2}/\d{1,2}|\d{1,2}(:\d{2})? ?(am|pm)|q[1-4])\b"#
    static let blocker = #"\b(block(ed|er|ers|ing)?|stuck|broken|outage|incident|down for|failing|fails|failed|bug|regression|urgent|asap|critical|sev ?[12]|p0|p1|risk|escalat\w*|rollback|roll(ed)? back|hotfix)\b"#
    static let fileOrLink = #"(https?://|\.(pdf|docx?|xlsx?|pptx?|key|numbers|csv|fig|sketch|zip)\b|\b(attached|attachment|spec|deck|doc|document|draft|slides|spreadsheet|contract|proposal|pull request|pr #?\d+|ticket|jira)\b)"#
    static let planChange = #"\b(moved|moving|rescheduled|postponed|pushed (back|out|to)|cancel+ed|delayed|instead|change of plans?|no longer|switch(ed|ing) to|new (time|date)|updated (plan|date|time|timeline)|slipp(ed|ing))\b"#

    static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Lowercased words (letters/digits/apostrophes), punctuation and
    /// emoji dropped.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'+")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    public static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }

    static let stopWords: Set<String> = ["the", "a", "an", "to", "and", "or", "of", "in", "on", "for", "is", "are",
                                         "was", "it", "that", "this", "with", "at", "be", "by", "from", "has", "have"]

    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let x = Set(a).subtracting(stopWords), y = Set(b).subtracting(stopWords)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// True when the text carries a strong work cue (these rescue a
    /// message from the food / celebration / small-talk buckets).
    static func workCue(_ text: String) -> Bool {
        has(decision, text) || has(deadline, text) || has(blocker, text) || has(fileOrLink, text) || has(planChange, text)
    }

    /// Why a message is noise, or nil when it may carry signal. `now`
    /// decides whether an immediacy ask has expired.
    public static func reason(_ m: ChatMessage, now: Date) -> Reason? {
        if m.deleted { return .empty }
        let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = reason(text: text) { return r }
        if has(immediacy, text) {
            guard let d = CatchUpBound.date(m) else { return .expired }
            if now.timeIntervalSince(d) > immediacyLifetime { return .expired }
        }
        return nil
    }

    /// Text-only buckets (no age): also used on model bullets.
    public static func reason(text raw: String) -> Reason? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if has(reaction, text) { return .reaction }
        let w = words(text)
        if w.isEmpty { return .emojiOnly }
        if has(gifHost, text), w.count <= 12, !workCue(text) { return .emojiOnly }
        // Food/coffee orders are social even with a time on them.
        if has(food, text) {
            if has(foodOrder, text) { return .food }
            if !workCue(text) { return .food }
        }
        if has(celebration, text), !has(decision, text), !has(blocker, text), !has(fileOrLink, text) { return .celebration }
        if has(smallTalk, text), !workCue(text) { return .smallTalk }
        if !text.contains("?"), w.count <= 6 {
            if w.allSatisfy({ greetingWords.contains($0) }), w.contains(where: { ["hi", "hey", "hello", "hiya", "howdy", "yo", "gm", "morning", "bye", "gn", "cya", "ttyl"].contains($0) }) {
                return .greeting
            }
            // All acknowledgment words, allowing one capitalized name
            // ("Thanks Ava!") that is not a day or month.
            let unknown = w.enumerated().filter { !ackWords.contains($0.element) }
            if unknown.isEmpty { return .acknowledgment }
            if unknown.count == 1, w.count >= 2, !weekdayOrMonth.contains(unknown[0].element),
               nameLike(unknown[0].element, in: text)
            {
                return .acknowledgment
            }
        }
        return nil
    }

    /// The word appears capitalized in the original text (a name).
    static func nameLike(_ word: String, in text: String) -> Bool {
        guard let first = word.first else { return false }
        let cap = String(first).uppercased() + word.dropFirst()
        return text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: cap) + #"\b"#, options: .regularExpression) != nil
    }

    /// Salience of a kept message (higher = more worth a summary line).
    /// 1 = plain work chatter (kept for context); ≤ 0 = dropped.
    public static func salience(_ m: ChatMessage, _ ctx: CatchUpFilterContext) -> Int {
        let text = m.content
        var s = 1
        let kind = CatchUpMentions.kind(of: m, ownerMRI: ctx.ownerMRI, ownerDisplayName: ctx.ownerDisplayName,
                                        ownerTags: ctx.ownerTags)
        switch kind {
        case .you?, .tag?: s += 3
        case .everyone?: s += 2
        case nil: break
        }
        if !m.isOwn, has(ask, text) { s += 2 }
        if has(decision, text) { s += 2 }
        if has(deadline, text) { s += 2 }
        if has(blocker, text) { s += 2 }
        if has(fileOrLink, text) { s += 1 }
        if has(planChange, text) { s += 2 }
        if ctx.feedback.isSimilarToDismissed(text) { s -= 3 }
        s -= ctx.feedback.chatPenalty(ctx.chatID)
        return s
    }
}

// MARK: - Pipeline

public enum CatchUpPipeline {
    /// Model input for one conversation: period-bounded, noise dropped,
    /// then salience-ranked into the model's reading budget (lowest
    /// scores out first; ties drop the oldest). Chronological order.
    public static func prepare(_ messages: [ChatMessage], period: CatchUpPeriod, _ ctx: CatchUpFilterContext,
                               budget: Int = CatchUpChunker.inputBudget * CatchUpChunker.maxChunks) -> [ChatMessage]
    {
        let bounded = CatchUpBound.messages(messages, period: period, now: ctx.now)
        var scored: [(i: Int, m: ChatMessage, s: Int, t: Int)] = []
        for (i, m) in bounded.enumerated() {
            guard CatchUpNoise.reason(m, now: ctx.now) == nil else { continue }
            let s = CatchUpNoise.salience(m, ctx)
            guard s >= 1 else { continue }
            let line = CatchUpChunker.lines([m]).first ?? ""
            scored.append((i, m, s, CatchUpChunker.estimateTokens(line) + 1))
        }
        var total = scored.reduce(0) { $0 + $1.t }
        if total > budget {
            // Drop order: lowest salience, then oldest.
            let order = scored.indices.sorted { (scored[$0].s, scored[$0].i) < (scored[$1].s, scored[$1].i) }
            var drop = Set<Int>()
            for k in order where total > budget {
                drop.insert(k)
                total -= scored[k].t
            }
            scored = scored.indices.filter { !drop.contains($0) }.map { scored[$0] }
        }
        return scored.map(\.m)
    }

    /// Bullet pass: drops social bullets and ones like a dismissed
    /// bullet, then (when a transport is given) has the model rate the
    /// rest 0–3 and keeps ≥ 2. A bullet with a strong deterministic cue
    /// (ask, mention, decision, deadline, blocker, plan change: salience
    /// ≥ 3) has a floor of 2, so the model can't drop it — and isn't
    /// asked about it (no call at all when every bullet is strong; the
    /// model's ratings measured noisy on decisions and plan changes).
    /// Unrated bullets stay (fail-open: a parse miss never blanks a
    /// summary). Returns the rebuilt plain text.
    public static func refine(_ text: String, _ ctx: CatchUpFilterContext,
                              rater: (any CatchUpTransport)?) async -> String
    {
        var parsed = CatchUpSummaryParser.parse(text)
        guard !parsed.points.isEmpty || !parsed.actions.isEmpty else { return text }
        func keepDeterministic(_ s: String) -> Bool {
            CatchUpNoise.reason(text: s) == nil && !ctx.feedback.isSimilarToDismissed(s)
        }
        parsed.points = parsed.points.filter(keepDeterministic)
        parsed.actions = parsed.actions.filter(keepDeterministic)
        let uncertain = Array(Set(parsed.points + parsed.actions).filter { !CatchUpRating.isStrong($0, ctx) }).sorted()
        if let rater, !uncertain.isEmpty {
            let prompt = CatchUpRating.prompt(uncertain)
            if let reply = try? await rater.complete(baseURL: "", apiKey: "", model: "", prompt: prompt) {
                let ratings = CatchUpRating.parse(reply, count: uncertain.count)
                var drop = Set<String>()
                for (i, b) in uncertain.enumerated() {
                    if let r = ratings[i + 1], r < CatchUpRating.keepAtLeast { drop.insert(b) }
                }
                parsed.points.removeAll { drop.contains($0) }
                parsed.actions.removeAll { drop.contains($0) }
            }
        }
        return CatchUpRating.render(parsed)
    }
}

// MARK: - Rating pass

public enum CatchUpRating {
    public static let keepAtLeast = 2
    public static let responseTokens = 80

    /// Deterministic floor: salience ≥ 3 reads as at least a 2.
    public static func isStrong(_ bullet: String, _ ctx: CatchUpFilterContext) -> Bool {
        CatchUpNoise.salience(ChatMessage(id: "", sender: "", timestamp: "", content: bullet), ctx) >= 3
    }

    /// Plain-text prompt (the system model refuses @Generable often).
    /// No example content, like the summary prompts.
    static let promptLead = "Below are numbered points from a catch-up of a work conversation."

    public static func prompt(_ bullets: [String]) -> String {
        let list = bullets.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
            \(promptLead) Rate how much each point needs the reader's attention now:
            3 means a request or question for the reader, a decision, a deadline or a blocker.
            2 means useful work news or a change of plan.
            1 means a minor detail.
            0 means social chat, food or drink, greetings, thanks, celebrations, or something whose moment has passed.
            Write one line per point with the point's number, a colon and the rating, and nothing else.

            Points:
            \(list)
            """
    }

    /// "3: 2", "Point 3 - 2", "3) 2 (reason)", "#3: rating 2" → [3: 2].
    /// Ratings outside 0–3 and numbers outside 1…count are ignored.
    public static func parse(_ reply: String, count: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let pattern = #"^\s*[-*•]?\s*(?:point|item|#)?\s*(\d{1,2})\s*[:.)\-–—=]\s*(?:rating\s*[:=]?\s*)?\**\s*([0-3])\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return out }
        for line in reply.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))),
                  let r = Int(ns.substring(with: m.range(at: 2))),
                  (1 ... count).contains(n), out[n] == nil
            else { continue }
            out[n] = r
        }
        return out
    }

    /// Parsed parts back to the SUMMARY / POINTS / ACTIONS layout.
    public static func render(_ p: ParsedCatchUp) -> String {
        var lines: [String] = []
        if !p.summary.isEmpty { lines.append("SUMMARY: \(p.summary)") }
        lines.append("POINTS:")
        lines.append(contentsOf: p.points.isEmpty ? ["- None"] : p.points.map { "- \($0)" })
        lines.append("ACTIONS:")
        lines.append(contentsOf: p.actions.isEmpty ? ["- None"] : p.actions.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }
}

// MARK: - Feedback store

/// "Not important" dismissals, persisted locally (never synced). Reset
/// from Settings ▸ AI.
@MainActor
public final class CatchUpFeedbackStore: ObservableObject {
    @Published public private(set) var value: CatchUpFeedback
    private let defaults: UserDefaults
    static let key = "catchup.feedback"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let v = try? JSONDecoder().decode(CatchUpFeedback.self, from: data)
        {
            value = v
        } else {
            value = CatchUpFeedback()
        }
    }

    public var count: Int { value.dismissals.count }

    public func dismiss(_ text: String, chatID: String?) {
        var v = value
        v.dismiss(text, chatID: chatID)
        value = v
        save()
    }

    public func isHidden(_ text: String, chatID: String?) -> Bool { value.isHidden(text, chatID: chatID) }

    public func reset() {
        value = CatchUpFeedback()
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
    }
}
