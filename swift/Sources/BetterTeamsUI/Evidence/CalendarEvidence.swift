// CalendarEvidence.swift — CAL-REMNANT evidence routes (demo only):
// `calendar?sheet=editEvent&contact=<id>` etc. open through the generic
// `?sheet=` path; `calendar?overlay=all|<calendar id>` turns the
// read-only overlay on for week-grid captures.

enum CalendarEvidence {
    static func apply(_ route: Route, _ wc: ShellWindowController) {
        let m = wc.model
        guard m.options.demo, route.head == "calendar" else { return }
        // Webinar evidence: `calendar?sheet=newWebinar&contact=<id>`
        // seeds demo registrations for the draft (capture only).
        if route.query["sheet"] == "newWebinar", let id = route.query["contact"] {
            Task { @MainActor in
                guard let app = m.app else { return }
                app.calWeek.seedDemoRegistrations(id: id)
            }
        }
        guard let overlay = route.query["overlay"] else { return }
        // Main-actor store calls, once the main window is up (CallEvidence pattern).
        Task { @MainActor in
            guard let app = m.app else { return }
            let week = app.calWeek
            week.loadCalendars()
            if overlay == "all" {
                for cal in week.overlayCalendars { week.setOverlay(id: cal.id, on: true) }
            } else {
                week.setOverlay(id: overlay, on: true)
            }
        }
    }
}
