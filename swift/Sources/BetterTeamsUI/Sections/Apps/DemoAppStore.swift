// DemoAppStore.swift — the demo Apps store catalog (APPHOST-B2):
// Microsoft first-party names plus made-up third-party apps from
// fictional publishers (Northwind, Fabrikam, Tailspin, Woodgrove,
// Contoso). No network: installed apps host the local sample page.
import Foundation
import OstMacCore

enum DemoAppStore {
    static let plannerID = "demo-app-planner"
    static let sprintBoardID = DemoTeams.demoAppTabAppID

    private static func app(_ id: String, _ name: String, _ developer: String, _ short: String, _ full: String,
                            categories: [String], personal: Bool = true, channel: Bool = false,
                            bot: Bool = false, extensionToo: Bool = false, permissions: [String] = [],
                            domains: [String], accent: String) -> TeamsAppManifest {
        let host = domains.first ?? "apps.example"
        var m = TeamsAppManifest(
            id: id, name: name, shortDescription: short, developer: developer,
            staticTabs: personal
                ? [TeamsAppStaticTab(entityId: "home", name: name, contentUrl: "https://\(host)/tab?theme={theme}")]
                : [],
            configurableTabs: channel
                ? [TeamsAppConfigurableTab(configurationUrl: "https://\(host)/config", canUpdateConfiguration: true,
                                           scopes: ["team", "groupChat"])]
                : [],
            webApplicationInfo: TeamsAppWebInfo(id: "00000000-0000-0000-0000-\(String(id.hashValueStable, radix: 16))",
                                                resource: "api://\(host)"),
            validDomains: domains, fullDescription: full, hasBot: bot, hasMessagingExtension: extensionToo,
            permissions: permissions, categories: categories, websiteUrl: "https://\(host)",
            privacyUrl: "https://\(host)/privacy", termsOfUseUrl: "https://\(host)/terms")
        m.accentColor = accent
        return m
    }

    static let apps: [TeamsAppManifest] = [
        app(plannerID, "Planner", "Microsoft Corporation", "Plan and track your team's work.",
            "Create plans, assign tasks and see everything that's due across your team plans and To Do, in one place.",
            categories: ["Productivity", "Project Management"], channel: true, bot: true,
            permissions: ["identity", "messageTeamMembers"], domains: ["tasks.office.example"], accent: "#31752F"),
        app("demo-app-forms", "Forms", "Microsoft Corporation", "Create surveys, quizzes and polls.",
            "Build a form in minutes, share it in a channel and watch results arrive in real time.",
            categories: ["Productivity", "Surveys"], channel: true, extensionToo: true,
            permissions: ["identity"], domains: ["forms.office.example"], accent: "#077568"),
        app("demo-app-onenote", "OneNote", "Microsoft Corporation", "Capture notes in shared notebooks.",
            "Keep meeting notes, research and plans in notebooks your whole team can edit together.",
            categories: ["Productivity"], channel: true, permissions: ["identity"],
            domains: ["onenote.office.example"], accent: "#7719AA"),
        app("demo-app-whiteboard", "Whiteboard", "Microsoft Corporation", "Sketch and brainstorm together.",
            "An infinite canvas for ideas, diagrams and sticky notes, live during meetings or any time after.",
            categories: ["Productivity", "Design"], channel: true, domains: ["whiteboard.office.example"],
            accent: "#0078D4"),
        app("demo-app-approvals", "Approvals", "Microsoft Corporation", "Request and track sign-offs.",
            "Send approval requests to one person or a group, and keep every decision in one history.",
            categories: ["Workflow"], bot: true, permissions: ["identity", "messageTeamMembers"],
            domains: ["approvals.office.example"], accent: "#0F6CBD"),
        app("demo-app-lists", "Lists", "Microsoft Corporation", "Track information with smart lists.",
            "Start from a template to track issues, assets or onboarding, with views, rules and reminders.",
            categories: ["Productivity", "Workflow"], channel: true, domains: ["lists.office.example"],
            accent: "#C239B3"),
        app(sprintBoardID, "Sprint Board", "Northwind Labs", "Plan sprints on a shared board.",
            "Drag stories across columns, track burndown and review each sprint without leaving your channel.",
            categories: ["Project Management", "Developer Tools"], channel: true,
            permissions: ["identity", "ChannelSettings.Read.Group"], domains: ["sprintboard.northwind.example"],
            accent: "#D83B01"),
        app("demo-app-standup", "Standup Buddy", "Fabrikam Tools", "Async daily standups in chat.",
            "Collects everyone's update on a schedule, then posts a digest to the channel. Nobody waits on a call.",
            categories: ["Communication", "Project Management"], personal: false, bot: true, extensionToo: true,
            permissions: ["identity", "messageTeamMembers", "ChannelMessage.Send.Group"],
            domains: ["standup.fabrikam.example"], accent: "#5C2D91"),
        app("demo-app-polls", "Quick Polls", "Tailspin Apps", "Ask a question, get answers fast.",
            "Post a poll from the compose box and see results update in the conversation as people vote.",
            categories: ["Utilities", "Surveys"], personal: false, bot: true, extensionToo: true,
            permissions: ["identity"], domains: ["polls.tailspin.example"], accent: "#107C10"),
        app("demo-app-expenses", "Expense Desk", "Woodgrove Software", "Submit and approve expenses.",
            "Snap a receipt, file the claim and route it for approval. Finance sees it the moment it's signed off.",
            categories: ["Finance", "Workflow"], permissions: ["identity"],
            domains: ["expenses.woodgrove.example"], accent: "#986F0B"),
        app(DemoTeamsJSApp.appID, "Team Pulse", "Contoso", "Team check-ins, running natively.",
            "Shows the host handshake, context and sign-in token paths of the native Teams app host.",
            categories: ["Developer Tools"], domains: ["sample.contoso.example"], accent: "#0078D4"),
    ]

    /// Installed in the demo tenant (Team Pulse is hosted by its own launch).
    static let installedIDs: [String] = [plannerID, "demo-app-onenote", sprintBoardID]

    static let sections: [TeamsAppStoreSection] = [
        TeamsAppStoreSection(title: "Built by Microsoft",
                             appIds: [plannerID, "demo-app-forms", "demo-app-onenote", "demo-app-whiteboard",
                                      "demo-app-approvals", "demo-app-lists"]),
        TeamsAppStoreSection(title: "Popular with Your Team",
                             appIds: [sprintBoardID, "demo-app-standup", "demo-app-polls", "demo-app-expenses"]),
    ]

    /// SF Symbol per demo app (live apps show their manifest icon).
    static let symbols: [String: String] = [
        plannerID: "checklist", "demo-app-forms": "list.bullet.clipboard", "demo-app-onenote": "book.closed",
        "demo-app-whiteboard": "scribble.variable", "demo-app-approvals": "checkmark.seal",
        "demo-app-lists": "list.bullet.rectangle", sprintBoardID: "rectangle.split.3x1",
        "demo-app-standup": "person.3.sequence", "demo-app-polls": "chart.bar.xaxis",
        "demo-app-expenses": "creditcard", DemoTeamsJSApp.appID: "square.grid.2x2",
    ]

    /// Installed demo apps as hosted library apps (local sample page).
    @MainActor static func hosted(_ m: TeamsAppManifest) -> FrameApp? {
        guard var l = TeamsAppLaunch(manifest: m) else { return nil }
        l.demoHTML = DemoTeamsJSApp.html(title: m.name)
        return FrameApp(id: AppsLibrary.appID(forCatalogApp: m.id), label: m.name,
                        symbol: symbols[m.id] ?? "square.grid.2x2", source: .personal, launch: .teamsApp(l))
    }
}

private extension String {
    /// Deterministic 12-hex-digit suffix (demo ids only).
    var hashValueStable: UInt64 {
        utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 } & 0xFFFF_FFFF_FFFF
    }
}
