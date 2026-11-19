// WebinarConfig.swift — WEBINARS lane: configure (PATCH) + registration
// list over Graph virtual events (`/solutions/virtualEvents/webinars`).
// Delegated `VirtualEvent.ReadWrite`; the organizer needs a Teams
// webinar license (M365 E1/E3/E5 or Edu A3/A5). Live calls run off the
// main thread (same contract as `CalendarGraph`).
import Foundation

/// Graph webinar audience (`audience` on virtualEventWebinar).
public enum WebinarAudience: String, Sendable, CaseIterable {
    case organization
    case everyone

    public var label: String {
        switch self {
        case .organization: "Organization"
        case .everyone: "Everyone"
        }
    }
}

/// Inputs for a draft webinar create.
public struct WebinarDraft: Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var description: String?
    public var audience: WebinarAudience

    public init(title: String, start: Date, end: Date, description: String? = nil,
                audience: WebinarAudience = .organization) {
        self.title = title
        self.start = start
        self.end = end
        self.description = description
        self.audience = audience
    }
}

/// Fields PATCHed onto a draft webinar. Nil fields are omitted.
public struct WebinarPatch: Sendable {
    public var title: String?
    public var description: String?
    public var audience: WebinarAudience?

    public init(title: String?, description: String?, audience: WebinarAudience?) {
        self.title = title
        self.description = description
        self.audience = audience
    }

    public var isEmpty: Bool {
        title == nil && description == nil && audience == nil
    }

    public var body: [String: Any] {
        var b: [String: Any] = [:]
        if let title { b["displayName"] = title }
        if let description { b["description"] = description }
        if let audience { b["audience"] = audience.rawValue }
        return b
    }

    /// Guard message for a webinar configure/save, nil when valid.
    public static func error(title: String, start: Date, end: Date,
                             description: String? = nil) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required"
        }
        if end <= start {
            return "End must be after start"
        }
        if let description, description.count > 2000 {
            return "Description is too long"
        }
        return nil
    }
}

/// One webinar registrant (Graph virtualEventRegistration).
public struct WebinarRegistrant: Sendable, Equatable {
    public var id: String
    public var firstName: String?
    public var lastName: String?
    public var email: String
    public var status: String?
    public var registeredAt: String?

    public var displayName: String {
        let full = [firstName, lastName].compactMap { CalendarEvents.nonEmpty($0) }.joined(separator: " ")
        return full.isEmpty ? email : full
    }
}

/// Demo registrations for evidence captures (never live data).
public enum WebinarDemo {
    public static let registrations = [
        WebinarRegistrant(id: "R1", firstName: "Amy", lastName: "Wu",
                           email: "amy@contoso.example", status: "registered",
                           registeredAt: "2026-10-01T12:00:00Z"),
        WebinarRegistrant(id: "R2", firstName: "Bo", lastName: "Li",
                           email: "bo@contoso.example", status: "registered",
                           registeredAt: "2026-10-02T12:00:00Z"),
        WebinarRegistrant(id: "R3", firstName: "Cy", lastName: "Dee",
                           email: "cy@contoso.example", status: "waitlisted",
                           registeredAt: "2026-10-03T12:00:00Z"),
    ]
}

/// A registrations page → rows (blank-email rows dropped).
public enum WebinarRegistrations {
    public static func page(_ data: Data) throws -> (rows: [WebinarRegistrant], next: String?) {
        struct R: Decodable {
            let id: String?
            let firstName: String?
            let lastName: String?
            let email: String?
            let status: String?
            let registrationDateTime: String?
        }
        struct Page: Decodable {
            let value: [R]
            let next: String?
            enum CodingKeys: String, CodingKey {
                case value
                case next = "@odata.nextLink"
            }
        }
        let p = try JSONDecoder().decode(Page.self, from: data)
        let rows = p.value.compactMap { r -> WebinarRegistrant? in
            guard let email = CalendarEvents.nonEmpty(r.email) else { return nil }
            return WebinarRegistrant(
                id: r.id ?? email,
                firstName: CalendarEvents.nonEmpty(r.firstName),
                lastName: CalendarEvents.nonEmpty(r.lastName),
                email: email,
                status: CalendarEvents.nonEmpty(r.status),
                registeredAt: CalendarEvents.nonEmpty(r.registrationDateTime))
        }
        return (rows, p.next)
    }
}
