// CallEvidence.swift — demo/evidence routes for Settings and the call
// hosts (UI-SPEC §11.3, §11.4, DL1). Demo only; deterministic fixtures
// (roster with speaking and muted people, placeholder camera feed,
// fixed duration), never real devices or user data.
//
//   settings/<pane>[?presentation=main|window]  Settings ▸ General,
//       Accounts, Notifications, Chats, Calls, Apps, AI, Advanced
//   call?state=incoming[&accept=1][&presentation=main|window]
//       an incoming ring (no system banner in demo: the geometry line
//       reports the CALL notification it would carry); accept=1 accepts
//       through the core slot and the DL1 host shows the call
//   call?state=prejoin|active|muted|sharing|ended|meetingvideo|presenting&presentation=main|window
//       [&inspector=1|people|chat][&popover=devices]
//       (meetingvideo: the meeting joined with video, the tile grid;
//       presenting: the same meeting with a colleague sharing a slide,
//       everyone camera-off)
//   <any route>?call=prejoin|active&presentation=main|window
//       a demo call behind the route (rail + toolbar call items)
//
// `state=ended` starts the active call, then ends it from the core
// side (remote end): the capture shows where the person lands.
//
// Settings and the separate call window are their own windows: in
// evidence mode the main window is ordered out so the capture's
// largest window of the app is the route's primary window, and
// `EvidenceHarness.primaryWindow` reports it in the READY line.
import AppKit
import OstMacCore

@MainActor
enum CallEvidence {
    /// Demo: Settings and the Show calls preference live in memory, so
    /// demo and evidence runs never read or write the person's settings.
    static func prepare(_ o: LaunchOptions) {
        guard o.demo else { return }
        CallSettings.useDemoStorage()
        SettingsWindowController.persists = false
    }

    static func presentation(_ raw: String?) -> CallPresentation? {
        switch raw {
        case "main": .mainWindow
        case "window": .separateWindow
        default: nil
        }
    }

    /// Applies a Settings or call route after the main window is shown.
    static func apply(_ route: Route, _ wc: ShellWindowController) {
        let m = wc.model
        guard m.options.demo else { return }
        if route.head == "calls", route.query["confirm"] == "clear" {
            // Evidence: the Clear Call History confirmation alert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { CallsSection.clearHistory(m) }
        }
        switch route.head {
        case "settings":
            CallsSettingsPane.evidenceOpenTest = route.query["test"] == "1"
            if let p = presentation(route.query["presentation"]) { CallSettings.shared.presentation = p }
            SettingsWindowController.shared.show(pane: route.tail.first, evidence: m.options.evidence)
            focus(SettingsWindowController.shared.window, over: wc)
            // ?seed=windows: two quiet-hours windows + a presence schedule (demo stores are empty).
            if route.query["seed"] == "windows", let app = m.app {
                app.quietHours.windows[0] = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
                app.quietHours.addWindow(QuietHoursWindow(enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60,
                                                          days: [7, 1]))
                _ = app.presenceSchedule.addEntry(PresenceScheduleEntry(
                    window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60, days: [2, 3, 4, 5, 6]),
                    status: .busy))
            }
            // ?scroll=0…1 scrolls the pane (tall panes; Notifications is ~2.5 screens).
            if let f = route.query["scroll"].flatMap(Double.init), let w = SettingsWindowController.shared.window {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scrollPane(in: w.contentView, to: f) }
            }
        case "call" where route.query["state"] == "incoming":
            if let p = presentation(route.query["presentation"]) { CallSettings.shared.presentation = p }
            m.app?.call.seedDemo(state: "incoming")
            if route.query["accept"] == "1" { m.app?.call.accept() }
        case "call":
            let p = presentation(route.query["presentation"]) ?? .current
            let session = begin(route.query["state"] ?? "prejoin", presentation: p, show: true, wc)
            if route.query["popover"] == CallCommands.devicesPopover { session?.showDevices() }
            if p == .separateWindow, let w = session?.window?.window, session?.ended == false { focus(w, over: wc) }
        case _ where route.query["call"] != nil:
            let p = presentation(route.query["presentation"]) ?? .current
            begin(route.query["call"] ?? "active", presentation: p, show: false, wc)
        default:
            break
        }
    }

    private static func scrollPane(in view: NSView?, to fraction: Double) {
        guard let view else { return }
        if let sv = view as? NSScrollView, let doc = sv.documentView {
            let room = max(0, doc.frame.height - sv.contentView.bounds.height)
            var y = room * min(max(fraction, 0), 1)
            if !doc.isFlipped { y = room - y }
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            return
        }
        for sub in view.subviews { scrollPane(in: sub, to: fraction) }
    }

    /// Demo meeting roster: one speaking, two muted (deterministic).
    static let roster = [
        MeetingParticipant(id: "8:orgid:ava", name: "Ava Lindqvist", speaking: true),
        MeetingParticipant(id: "8:orgid:hannah", name: "Hannah Clarke", muted: true),
        MeetingParticipant(id: "8:orgid:tom", name: "Tom Becker"),
        MeetingParticipant(id: "8:orgid:megan", name: "Megan Harper", muted: true),
    ]

    static let standup = MeetingItem(
        meetingId: CalendarSelection.demoMeetingID, subject: "Engineering standup",
        joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_standup@thread.v2/0",
        organizer: "Doe, Jane", isOnline: true)

    /// Starts the demo call for `state` (prejoin, active, muted,
    /// sharing, ended; video: 1:1 video call).
    @discardableResult
    private static func begin(_ state: String, presentation p: CallPresentation, show: Bool,
                              _ wc: ShellWindowController) -> CallSession? {
        let m = wc.model
        guard let app = m.app else { return nil }
        if state == "video" {
            // 1:1 video call (VIDEO1): demo remote video fills the
            // stage, placeholder self view picture-in-picture.
            app.call.seedDemo(state: "active")
            return m.beginCall(.person(name: "Ava Lindqvist", thread: "19:demo@thread.v2"),
                               presentation: p, show: show, video: true)
        }
        let kind = CallKind.meeting(id: standup.id, subject: standup.subject)
        guard state != "prejoin" else {
            let s = m.beginCall(kind, presentation: p, show: show)
            app.meetings.joinMeeting(standup)
            return s
        }
        app.call.seedDemo(state: "active")
        app.meeting.adopt(roster, meetingID: "19:demo_standup@thread.v2")
        app.meetingChat.showDemo(threadID: "19:demo_standup@thread.v2", chatName: standup.subject,
                                 messages: MeetingDemo.messages)
        let s = m.beginCall(kind, presentation: p, show: show)
        s?.joinForDemo(video: state == "meetingvideo" || state == "presenting")
        switch state {
        case "presenting":
            s?.meetingVideo?.startDemoPresentation()
            app.call.setCameraOn(false)
        case "muted": app.call.setMuted(true)
        case "sharing": s?.toggleShare()
        case "ended": app.call.seedDemo(state: "ended")
        default: break
        }
        return s
    }

    /// Geometry suffix (§11.4, numbers not pixels): the call's host, the
    /// stage size and tile grid, the rail/toolbar indicator text, the
    /// Devices popover, and the call window's toolbar item frames.
    static func geometry(_ m: WindowModel) -> String {
        var extra = " dockBadge=\(DockBadge.count(m))"
        if let store = m.app?.call { extra += IncomingCallHost.preview(store) }
        if let w = SettingsWindowController.loaded?.window, w.isVisible {
            extra += " settings[title=\(w.title) window=\(Int(w.frame.width))x\(Int(w.frame.height))]"
        }
        return extra + callGeometry(m)
    }

    private static func callGeometry(_ m: WindowModel) -> String {
        guard let s = m.call else { return " call[none]" }
        let stage = s.stage.isViewLoaded ? s.stage.view.frame.size : .zero
        let own = m.ownDisplayName
        let tiles = CallTiles.make(
            roster: s.isMeeting ? (m.app?.meeting.participants ?? []) : [], peer: s.peerName, ownName: own,
            isOwn: { p in m.isOwnID(p.id) || p.name == own || p.name == "Me" },
            muted: s.controls.muted, cameraOn: s.controls.cameraOn, sharing: s.sharing)
        // Meeting video: remote tiles + self view (+ share).
        let count = s.meetingVideo.map { $0.tiles.count + 1 + (s.sharing ? 1 : 0) } ?? tiles.count
        let g = TileGridLayout.grid(count: count, in: CGSize(width: max(0, stage.width - 32),
                                                                  height: max(0, stage.height - 32)),
                                    spacing: 8, aspect: 16.0 / 9.0)
        var out = " call[presentation=\(s.presentation.rawValue) joined=\(s.joined) connected=\(s.connected)"
            + " attached=\(s.stage.parent.map { String(describing: type(of: $0)) } ?? "none")"
            + " stage=\(Int(stage.width))x\(Int(stage.height)) tiles=\(count) grid=\(g.columns)x\(g.rows)"
            + " tile=\(Int(g.tile.width))x\(Int(g.tile.height)) indicator=\(s.indicatorText)"
            + " subtitle=\(s.statusLine) muted=\(s.controls.muted) sharing=\(s.sharing)"
            + " popover=\(s.devices.isShown)"
        if let w = s.window?.window {
            let c = w.contentLayoutRect.size
            out += " window=\(Int(w.frame.width))x\(Int(w.frame.height)) content=\(Int(c.width))x\(Int(c.height))"
            if let root = w.contentView?.superview {
                out += " items[" + itemViewers(root).joined(separator: " ") + "]"
            }
        }
        return out + "]"
    }

    private static func itemViewers(_ v: NSView) -> [String] {
        var found: [(String, CGRect)] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("ItemViewer"), v.responds(to: NSSelectorFromString("item")),
               let item = v.value(forKey: "item") as? NSToolbarItem, !item.isHidden {
                let r = v.convert(v.bounds, to: nil)
                if r.width > 0 { found.append((item.itemIdentifier.rawValue, r)) }
            }
            v.subviews.forEach(walk)
        }
        walk(v)
        return found.sorted { $0.1.minX < $1.1.minX }.map { "\($0.0)@\(Int($0.1.minX))+\(Int($0.1.width))" }
    }

    static func focus(_ w: NSWindow?, over wc: ShellWindowController) {
        guard let w, wc.model.options.evidence else { return }
        wc.window?.orderOut(nil)
        EvidenceHarness.primaryWindow = w
        let c = w.contentLayoutRect.size
        print("EVIDENCE WINDOW title=\(w.title) frame=\(Int(w.frame.width))x\(Int(w.frame.height)) "
            + "content=\(Int(c.width))x\(Int(c.height)) toolbar=\(w.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        fflush(stdout)
    }
}
