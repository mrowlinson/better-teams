// DemoTeams.swift — P2c: canned Teams data for `--demo` (UI-SPEC §6.3,
// §11.3 demo mode). Everything here is in memory: demo joins and
// creates land in a process-local ledger, never in core or on disk.
import Foundation

public enum DemoTeams {
    /// Channel with threaded posts (roots + `reply_to` replies).
    public static let threadedChannelID = "demo-chan-shipping"
    /// Root post with the longest thread (evidence alias `demo-thread`).
    public static let threadRootID = "ship-p1"

    /// Extra joined teams shown beside `DemoData.teams` in the app.
    public static let extraTeams: [TeamItem] = [
        TeamItem(teamId: "demo-team-mkt", name: "Marketing", channels: [
            TeamChannel(channelId: "demo-chan-mkt-general", name: "General",
                        description: "Campaigns, launches and brand."),
            TeamChannel(channelId: "demo-chan-mkt-launch", name: "Launch Plan"),
        ]),
    ]

    /// Public teams the Join a Team sheet lists in demo.
    public static let joinable: [TeamItem] = [
        TeamItem(teamId: "demo-team-support", name: "Customer Support", channels: [
            TeamChannel(channelId: "demo-chan-support-general", name: "General"),
        ]),
        TeamItem(teamId: "demo-team-research", name: "Research", channels: [
            TeamChannel(channelId: "demo-chan-research-general", name: "General"),
        ]),
        TeamItem(teamId: "demo-team-social", name: "Social Club", channels: [
            TeamChannel(channelId: "demo-chan-social-general", name: "General"),
        ]),
    ]

    /// Process-local ledger for demo joins and creates (thread-safe:
    /// the view model's fetchers run on detached tasks).
    public final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var added: [TeamItem] = []

        public init() {}

        public func add(_ team: TeamItem) {
            lock.lock()
            defer { lock.unlock() }
            guard !added.contains(where: { $0.teamId == team.teamId }) else { return }
            added.append(team)
        }

        public var teams: [TeamItem] {
            lock.lock()
            defer { lock.unlock() }
            return added
        }
    }

    /// The demo teams list: canned teams, extras, then this session's
    /// joins and creates.
    public static func response(ledger: Ledger) -> TeamsResponse {
        TeamsResponse(ok: true, teams: (DemoData.teams + extraTeams).map(describe) + ledger.teams)
    }

    /// Channel descriptions for the canned channels (the header's
    /// second line, §6.3); kept here so `DemoData` stays untouched.
    static let descriptions: [String: String] = [
        "demo-chan-general": "Team-wide announcements and questions.",
        threadedChannelID: "Release coordination: builds, rollouts and sign-offs.",
        "demo-chan-long": "Weekly release review notes.",
        "demo-chan-crit": "Design critique, Tuesdays and Thursdays.",
    ]

    static func describe(_ team: TeamItem) -> TeamItem {
        TeamItem(teamId: team.teamId, name: team.name, channels: team.channels.map { ch in
            guard ch.description?.isEmpty ?? true, let d = descriptions[ch.channelId] else { return ch }
            return TeamChannel(channelId: ch.channelId, name: ch.name, description: d,
                               membershipType: ch.membershipType, webUrl: ch.webUrl)
        })
    }

    /// Demo join: joinable ids land in the ledger; unknown ids fail like
    /// a server 404 would.
    public static func join(_ id: String, ledger: Ledger) throws -> TeamJoinResponse {
        guard let team = joinable.first(where: { $0.teamId == id }) else {
            throw CoreCallError.failed("No team found with that code or ID.")
        }
        ledger.add(team)
        return TeamJoinResponse(ok: true, team_id: id)
    }

    /// Demo public-team search: joinable + joined demo teams whose name
    /// contains the query (case-insensitive). In memory, never core.
    public static func search(_ query: String, ledger: Ledger) -> PublicTeamsResponse {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        let pool = joinable + response(ledger: ledger).teams
        let hits = pool.filter { !q.isEmpty && $0.name.lowercased().contains(q) && seen.insert($0.teamId).inserted }
        return PublicTeamsResponse(
            ok: true, query: query, source: "demo",
            teams: hits.map { PublicTeam(id: $0.teamId, name: $0.name, description: $0.channels.first?.description) })
    }

    /// Demo create: a team with a General channel, recorded in the ledger.
    public static func create(_ name: String, ledger: Ledger) -> TeamCreateResponse {
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let team = TeamItem(teamId: "demo-team-new-\(slug)", name: name, channels: [
            TeamChannel(channelId: "demo-chan-new-\(slug)-general", name: "General"),
        ])
        ledger.add(team)
        return TeamCreateResponse(ok: true, team: team)
    }

    /// Channel tabs (Posts, Files, Notes, then web tabs).
    public static func tabs(for channelID: String) -> [ChannelTab] {
        var out = [
            ChannelTab(id: "\(channelID)-posts", name: "Posts"),
            ChannelTab(id: "\(channelID)-files", name: "Files", appID: ChannelTab.filesAppID),
            ChannelTab(id: "\(channelID)-notes", name: "Notes", appID: ChannelTab.notesAppID),
        ]
        guard channelID == threadedChannelID else { return out }
        out += [
            ChannelTab(id: "demo-tab-roadmap", name: "Roadmap", websiteURL: "https://example.com/roadmap"),
            ChannelTab(id: "demo-tab-board", name: "Release Board", contentURL: "https://example.com/board"),
            ChannelTab(id: "demo-tab-wiki", name: "Wiki", websiteURL: "https://example.com/wiki"),
            ChannelTab(id: "demo-tab-status", name: "Status Page", websiteURL: "https://example.com/status"),
        ]
        return out
    }

    /// Team roster (owners flagged).
    public static func roster(teamID: String) -> TeamMembersResponse {
        let people: [(String, String, Bool)] = [
            ("demo-u-megan", "Megan Harper", true),
            ("demo-u-me", "Me", true),
            ("demo-u-tom", "Tom Becker", false),
            ("demo-u-ava", "Ava Lindqvist", false),
            ("demo-u-paula", "Paula Norris", false),
            ("demo-u-luis", "Luis Ortega", false),
            ("demo-u-olivia", "Olivia Grant", false),
            ("demo-u-ethan", "Ethan Cole", false),
            ("demo-u-hannah", "Hannah Moore", false),
            ("demo-u-ryan", "Ryan Mitchell", false),
            ("demo-u-chloe", "Chloe Bennett", false),
            ("demo-u-nathan", "Nathan Price", false),
        ]
        let members = people.map { id, name, owner in
            TeamMember(id: "\(teamID)-\(id)", displayName: name, userId: id,
                       email: "\(name.split(separator: " ").first?.lowercased() ?? "user")@example.com",
                       roles: owner ? ["owner"] : [], isOwner: owner)
        }
        return TeamMembersResponse(ok: true, teamId: teamID, members: members)
    }

    /// Threaded posts for `threadedChannelID`: root posts, replies carry
    /// `reply_to` = root id (the wire-parent shape core mines for
    /// channel threads, `ost` chat.rs `message_parent_id`).
    public static let threadedPosts: [ChatMessage] = {
        func m(_ id: String, _ sender: String, _ time: String, _ text: String,
               own: Bool = false, parent: String? = nil) -> ChatMessage {
            ChatMessage(id: id, sender: sender, timestamp: time, content: text, isOwn: own, reply_to: parent)
        }
        return [
            m("ship-q1", "Luis Ortega", "2026-09-17T14:05:00Z",
              "Crash rate for 3.1.4 is down to 0.08% after the hotfix. Thanks everyone who jumped on it."),
            m("ship-q1-r1", "Megan Harper", "2026-09-17T14:21:00Z", "Great result. Let's keep the watch through Monday.",
              parent: "ship-q1"),
            m("ship-q2", "Paula Norris", "2026-09-18T18:40:00Z",
              "Heads-up: the certificate for the update server renews on October 3. "
                  + "@Jordan Fox can you confirm the change window works for the release?"),
            m("ship-q3", "Ava Lindqvist", "2026-09-19T15:12:00Z",
              "Updated the release checklist template: accessibility audit and localization sign-off are now required steps."),
            m("ship-q3-r1", "Tom Becker", "2026-09-19T15:30:00Z", "Good call. @Jordan Fox can you add the VoiceOver pass to RC testing?",
              parent: "ship-q3"),
            m("ship-q3-r2", "Luis Ortega", "2026-09-19T15:48:00Z", "Localization vendor confirmed a two-day turnaround.",
              parent: "ship-q3"),
            m("ship-p0", "Tom Becker", "2026-09-21T19:02:00Z",
              "Packaging checklist for 3.2 is in the Release Board tab. Please claim your rows by Friday."),
            m("ship-p0-r1", "Paula Norris", "2026-09-21T19:20:00Z", "Took notarization and the DMG layout.",
              parent: "ship-p0"),
            m("ship-p1", "Megan Harper", "2026-09-22T13:04:00Z",
              "Release candidate 3.2 RC1 is cut. Smoke tests are green on macOS 26 and 27. "
                  + "Remaining risks: the sign-in sheet on first launch and the notarization queue. "
                  + "Reply here with anything that blocks shipping on Thursday."),
            m("ship-p1-r1", "Tom Becker", "2026-09-22T13:11:00Z",
              "Sign-in sheet is fixed on main, it will be in RC2.", parent: "ship-p1"),
            m("ship-p1-r2", "Ava Lindqvist", "2026-09-22T13:26:00Z",
              "Empty states look right in both appearances now.", parent: "ship-p1"),
            m("ship-p1-r3", "Me", "2026-09-22T13:40:00Z",
              "I'll take the notarization queue and report back by noon.", own: true, parent: "ship-p1"),
            m("ship-p1-r4", "Luis Ortega", "2026-09-22T14:02:00Z",
              "Release notes draft is in the Wiki tab.", parent: "ship-p1"),
            m("ship-p2", "Ava Lindqvist", "2026-09-22T15:15:00Z",
              "New screenshots for the App Store listing are ready for review."),
            m("ship-p3", "Me", "2026-09-22T17:30:00Z",
              "Notarization passed for RC1. Uploading RC2 after the sign-in fix lands.", own: true),
            m("ship-p3-r1", "Megan Harper", "2026-09-22T17:34:00Z", "Great, thanks!", parent: "ship-p3"),
        ]
    }()
}
