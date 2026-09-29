// CatchUpFixtureCorpus.swift — CATCHTABS lane: labeled synthetic Catch Up
// corpus (68 messages, 5 conversations, two weeks plus 2 older items).
// Fictional crew, no real content. Each item is labeled signal or noise
// and carries a keyword unique to it, used to match model bullets back
// to their source when scoring precision/recall.
import Foundation

@testable import OstMacCore

enum CatchUpFixture {
    static let owner = "Jordan Fox"
    static let ownerAt = #"<at id="0">Jordan Fox</at>"#
    static let everyoneAt = #"<at id="1">everyone</at>"#

    struct Item {
        let chatID: String
        let id: String
        let sender: String
        let ageHours: Double
        let text: String
        let signal: Bool
        let keyword: String
        var mention: String?
        var own = false
    }

    static let chats: [(id: String, name: String)] = [
        ("c-launch", "Launch Crew"), ("c-design", "Design Review"), ("c-oncall", "Platform On-Call"),
        ("c-ava", "Ava Lindqvist"), ("c-office", "Office Crew"),
    ]

    // swiftlint:disable line_length
    static let items: [Item] = [
        // Launch Crew
        Item(chatID: "c-launch", id: "l01", sender: "Megan Harper", ageHours: 2, text: "@Jordan Fox can you sign off on the Atlas release notes by 4pm today?", signal: true, keyword: "atlas", mention: ownerAt),
        Item(chatID: "c-launch", id: "l02", sender: "Tom Becker", ageHours: 5, text: "Blocker: the payments sandbox is down for staging, QA is stuck until it's back.", signal: true, keyword: "sandbox"),
        Item(chatID: "c-launch", id: "l03", sender: "Liam Carter", ageHours: 6, text: "Morning all!", signal: false, keyword: "morning all"),
        Item(chatID: "c-launch", id: "l04", sender: "Chloe Bennett", ageHours: 6.1, text: "thanks Tom!", signal: false, keyword: "thanks tom"),
        Item(chatID: "c-launch", id: "l05", sender: "Megan Harper", ageHours: 20, text: "We decided to go with the phased rollout, 10% on Tuesday then 50% on Thursday.", signal: true, keyword: "phased"),
        Item(chatID: "c-launch", id: "l06", sender: "Liam Carter", ageHours: 22, text: "lol 😂", signal: false, keyword: "lol"),
        Item(chatID: "c-launch", id: "l07", sender: "Tom Becker", ageHours: 30, text: "Moved the go/no-go meeting to Wednesday 3pm because of the audit.", signal: true, keyword: "go/no-go"),
        Item(chatID: "c-launch", id: "l08", sender: "Chloe Bennett", ageHours: 40, text: "Who wants coffee? Heading to the cart downstairs.", signal: false, keyword: "coffee"),
        Item(chatID: "c-launch", id: "l09", sender: "Liam Carter", ageHours: 50, text: "Attached the Kestrel load test report, p95 is up 18% since Friday.", signal: true, keyword: "kestrel"),
        Item(chatID: "c-launch", id: "l10", sender: "Owen Price", ageHours: 60, text: "Happy Friday everyone! 🎉", signal: false, keyword: "happy friday"),
        Item(chatID: "c-launch", id: "l11", sender: "Megan Harper", ageHours: 70, text: "Please review the rollback runbook draft before Monday.", signal: true, keyword: "runbook"),
        Item(chatID: "c-launch", id: "l12", sender: "Emma Walsh", ageHours: 100, text: "Great job on the demo yesterday team, kudos!", signal: false, keyword: "kudos"),
        Item(chatID: "c-launch", id: "l13", sender: "Chloe Bennett", ageHours: 150, text: "Taking lunch orders for the offsite, reply with your burrito pick by 11!", signal: false, keyword: "burrito"),
        Item(chatID: "c-launch", id: "l14", sender: "Tom Becker", ageHours: 152, text: "I'll have the veggie burrito please", signal: false, keyword: "veggie"),
        Item(chatID: "c-launch", id: "l15", sender: "Liam Carter", ageHours: 153, text: "Chicken burrito for me 🌯", signal: false, keyword: "chicken"),
        Item(chatID: "c-launch", id: "l16", sender: "Megan Harper", ageHours: 200, text: "Legal confirmed the Orion vendor contract, we can start onboarding next week.", signal: true, keyword: "orion"),
        Item(chatID: "c-launch", id: "l17", sender: "Owen Price", ageHours: 210, text: "How was your weekend? The weather was amazing", signal: false, keyword: "weather was"),
        Item(chatID: "c-launch", id: "l18", sender: "Tom Becker", ageHours: 300, text: "The Helios migration deadline is end of month, we are at 60%.", signal: true, keyword: "helios"),
        Item(chatID: "c-launch", id: "l19", sender: "Chloe Bennett", ageHours: 320, text: "Happy birthday Liam! 🎂", signal: false, keyword: "birthday liam"),
        Item(chatID: "c-launch", id: "l20", sender: "Megan Harper", ageHours: 400, text: "Budget freeze announced for the Zephyr project.", signal: true, keyword: "zephyr"),
        Item(chatID: "c-launch", id: "l21", sender: "Liam Carter", ageHours: 33, text: "Lunch and learn on Thursday covers the new security policy, attendance required.", signal: true, keyword: "security policy"),
        Item(chatID: "c-launch", id: "l22", sender: "Emma Walsh", ageHours: 34, text: "Sounds good, see you all there!", signal: false, keyword: "see you all"),
        // Design Review
        Item(chatID: "c-design", id: "d01", sender: "Ava Lindqvist", ageHours: 3, text: "@Jordan Fox could you pick between the two onboarding layouts? Figma link: https://example.com/figma/onboarding", signal: true, keyword: "layout", mention: ownerAt),
        Item(chatID: "c-design", id: "d02", sender: "Noah Fischer", ageHours: 4, text: "👍", signal: false, keyword: "👍"),
        Item(chatID: "c-design", id: "d03", sender: "Ava Lindqvist", ageHours: 10, text: "Final decision: we are keeping the teal accent and dropping the gradient header.", signal: true, keyword: "teal"),
        Item(chatID: "c-design", id: "d04", sender: "Emma Walsh", ageHours: 11, text: "love it", signal: false, keyword: "love it"),
        Item(chatID: "c-design", id: "d05", sender: "Noah Fischer", ageHours: 26, text: "The icon set is blocked on the licensing review from legal.", signal: true, keyword: "icon"),
        Item(chatID: "c-design", id: "d06", sender: "Ava Lindqvist", ageHours: 27, text: "hahaha", signal: false, keyword: "hahaha"),
        Item(chatID: "c-design", id: "d07", sender: "Emma Walsh", ageHours: 80, text: "Usability study moved to next Thursday, invites updated.", signal: true, keyword: "usability"),
        Item(chatID: "c-design", id: "d08", sender: "Noah Fischer", ageHours: 90, text: "Anyone around for a quick call?", signal: false, keyword: "quick call"),
        Item(chatID: "c-design", id: "d09", sender: "Ava Lindqvist", ageHours: 95, text: "Cake in the kitchen for Emma's anniversary!", signal: false, keyword: "cake"),
        Item(chatID: "c-design", id: "d10", sender: "Ava Lindqvist", ageHours: 130, text: "Spec for the settings redesign is in the shared drive: settings-v3.pdf", signal: true, keyword: "settings"),
        Item(chatID: "c-design", id: "d11", sender: "Emma Walsh", ageHours: 131, text: "thanks Ava", signal: false, keyword: "thanks ava"),
        Item(chatID: "c-design", id: "d12", sender: "Noah Fischer", ageHours: 250, text: "Accessibility audit found 12 contrast issues, tracking them in Jira.", signal: true, keyword: "contrast"),
        Item(chatID: "c-design", id: "d13", sender: "Emma Walsh", ageHours: 260, text: "good morning team", signal: false, keyword: "good morning"),
        // Platform On-Call
        Item(chatID: "c-oncall", id: "o01", sender: "Owen Price", ageHours: 1, text: "Incident: login latency spiking in EU, @everyone please hold deploys.", signal: true, keyword: "latency", mention: everyoneAt),
        Item(chatID: "c-oncall", id: "o02", sender: "Liam Carter", ageHours: 1.5, text: "Rolled back the cache change, graphs are recovering.", signal: true, keyword: "cache"),
        Item(chatID: "c-oncall", id: "o03", sender: "Noah Fischer", ageHours: 2.5, text: "on my way, 5 min", signal: false, keyword: "on my way"),
        Item(chatID: "c-oncall", id: "o04", sender: "Owen Price", ageHours: 8, text: "Postmortem for the EU incident is due Friday, @Jordan Fox you own the timeline section.", signal: true, keyword: "postmortem", mention: ownerAt),
        Item(chatID: "c-oncall", id: "o05", sender: "Liam Carter", ageHours: 9, text: "ok", signal: false, keyword: "ok"),
        Item(chatID: "c-oncall", id: "o06", sender: "Owen Price", ageHours: 30, text: "brb grabbing lunch", signal: false, keyword: "grabbing"),
        Item(chatID: "c-oncall", id: "o07", sender: "Liam Carter", ageHours: 45, text: "Disk usage on the queue cluster hit 85%, need approval to add two nodes.", signal: true, keyword: "nodes"),
        Item(chatID: "c-oncall", id: "o08", sender: "Noah Fischer", ageHours: 46, text: "running 10 minutes late to standup", signal: false, keyword: "late"),
        Item(chatID: "c-oncall", id: "o09", sender: "Owen Price", ageHours: 110, text: "Pager rotation changes next week: Noah covers Tuesday instead of Liam.", signal: true, keyword: "pager"),
        Item(chatID: "c-oncall", id: "o10", sender: "Liam Carter", ageHours: 111, text: "sounds good", signal: false, keyword: "sounds good"),
        Item(chatID: "c-oncall", id: "o11", sender: "Noah Fischer", ageHours: 170, text: "anyone in the office today?", signal: false, keyword: "in the office"),
        Item(chatID: "c-oncall", id: "o12", sender: "Liam Carter", ageHours: 220, text: "TLS certificates for the internal API expire on the 15th, renewal ticket filed.", signal: true, keyword: "tls"),
        Item(chatID: "c-oncall", id: "o13", sender: "Owen Price", ageHours: 12, text: "ok, merging the hotfix now", signal: true, keyword: "hotfix"),
        Item(chatID: "c-oncall", id: "o14", sender: "Noah Fischer", ageHours: 13, text: "Does anyone have a phone charger I can borrow?", signal: false, keyword: "charger"),
        // Ava Lindqvist (1:1)
        Item(chatID: "c-ava", id: "a01", sender: "Ava Lindqvist", ageHours: 4, text: "Can you send me the Q4 hiring plan before our 1:1 tomorrow?", signal: true, keyword: "hiring"),
        Item(chatID: "c-ava", id: "a02", sender: "Ava Lindqvist", ageHours: 5, text: "Also, coffee later? ☕", signal: false, keyword: "coffee later"),
        Item(chatID: "c-ava", id: "a03", sender: "Ava Lindqvist", ageHours: 7, text: "hope you had a nice weekend!", signal: false, keyword: "nice weekend"),
        Item(chatID: "c-ava", id: "a04", sender: "Ava Lindqvist", ageHours: 52, text: "Heads up: the budget review was cancelled, we will do it async instead.", signal: true, keyword: "budget review"),
        Item(chatID: "c-ava", id: "a05", sender: "Jordan Fox", ageHours: 53, text: "thanks!", signal: false, keyword: "thanks!", own: true),
        Item(chatID: "c-ava", id: "a06", sender: "Ava Lindqvist", ageHours: 140, text: "Could you share the interview scorecards for the Denver candidates?", signal: true, keyword: "scorecard"),
        Item(chatID: "c-ava", id: "a07", sender: "Ava Lindqvist", ageHours: 141, text: "lol that meme", signal: false, keyword: "meme"),
        Item(chatID: "c-ava", id: "a08", sender: "Ava Lindqvist", ageHours: 290, text: "Reminder that performance reviews are due by the 30th.", signal: true, keyword: "performance"),
        // Office Crew
        Item(chatID: "c-office", id: "f01", sender: "Emma Walsh", ageHours: 3, text: "Donuts in the break room!", signal: false, keyword: "donut"),
        Item(chatID: "c-office", id: "f02", sender: "Chloe Bennett", ageHours: 12, text: "Pizza Friday is back, who's in? 🍕", signal: false, keyword: "pizza"),
        Item(chatID: "c-office", id: "f03", sender: "Owen Price", ageHours: 20, text: "Office is closed Monday for electrical work, please work from home.", signal: true, keyword: "electrical"),
        Item(chatID: "c-office", id: "f04", sender: "Emma Walsh", ageHours: 60, text: "Happy birthday Chloe!!", signal: false, keyword: "birthday chloe"),
        Item(chatID: "c-office", id: "f05", sender: "Liam Carter", ageHours: 75, text: "Anyone want to order sushi for lunch?", signal: false, keyword: "sushi"),
        Item(chatID: "c-office", id: "f06", sender: "Chloe Bennett", ageHours: 120, text: "Welcome to the team, Emma! 🎉", signal: false, keyword: "welcome"),
        Item(chatID: "c-office", id: "f07", sender: "Owen Price", ageHours: 180, text: "Food truck is outside today", signal: false, keyword: "food truck"),
        Item(chatID: "c-office", id: "f08", sender: "Emma Walsh", ageHours: 230, text: "New badge readers go live next Wednesday; collect your new badge from reception.", signal: true, keyword: "badge"),
        Item(chatID: "c-office", id: "f09", sender: "Noah Fischer", ageHours: 240, text: "Weather looks great for the picnic", signal: false, keyword: "picnic"),
        Item(chatID: "c-office", id: "f10", sender: "Chloe Bennett", ageHours: 330, text: "Congrats on the promotion Noah!", signal: false, keyword: "promotion"),
        Item(chatID: "c-office", id: "f11", sender: "Emma Walsh", ageHours: 500, text: "Summer party photos are up", signal: false, keyword: "summer party"),
    ]
    // swiftlint:enable line_length

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func message(_ it: Item, now: Date) -> ChatMessage {
        let raw = it.mention.map { m in it.text.replacingOccurrences(of: m.contains("everyone") ? "@everyone" : "@Jordan Fox", with: m) }
        return ChatMessage(id: it.id, sender: it.sender,
                           timestamp: iso.string(from: now.addingTimeInterval(-it.ageHours * 3600)),
                           content: it.text, isOwn: it.own, raw: raw)
    }

    /// Conversations, oldest message first.
    static func threads(now: Date) -> [(chatID: String, chatName: String, messages: [ChatMessage])] {
        chats.map { c in
            let msgs = items.filter { $0.chatID == c.id }.sorted { $0.ageHours > $1.ageHours }.map { message($0, now: now) }
            return (c.id, c.name, msgs)
        }
    }

    static func inPeriod(_ it: Item, _ p: CatchUpPeriod) -> Bool { it.ageHours * 3600 <= p.interval }
}
