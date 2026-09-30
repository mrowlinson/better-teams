// CalendarAttendeeChips.swift — the Duplicate sheet's people editor: one
// row per attendee (display name, never a raw address; a Required /
// Optional pop-up; remove) and an "Add people" field + Add taking typed
// addresses.
import OstMacCore
import SwiftUI

struct AttendeeChipsEditor: View {
    @Binding var people: [EventAttendee]
    @Binding var typed: String
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attendees (\(people.count))")
                .font(AppFont.caption(scale).weight(.semibold))
                .foregroundStyle(.secondary)
            if people.isEmpty {
                Text("None").font(AppFont.caption(scale)).foregroundStyle(.secondary)
            } else {
                ForEach(people) { row($0) }
            }
            HStack(spacing: 6) {
                TextField("Attendees", text: $typed,
                          prompt: Text("Add people: name@example.com; \u{2026}").foregroundStyle(Color(nsColor: .placeholderTextColor)))
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(CalendarWeekStore.recipients(typed).isEmpty)
            }
        }
    }

    /// One attendee: avatar, name, Required/Optional pop-up, remove.
    private func row(_ p: EventAttendee) -> some View {
        HStack(spacing: 8) {
            Avatar(name: p.displayName, diameter: 18, person: ContactRef(name: p.displayName, email: p.email))
            Text(CalendarNames.display(p.name, email: p.email)).lineLimit(1).truncationMode(.tail)
                .help(p.email)
            Spacer(minLength: 8)
            Picker("Role", selection: Binding(get: { p.type == "optional" },
                                              set: { setRole(p, optional: $0) })) {
                Text("Required").tag(false)
                Text("Optional").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Role for \(p.displayName)")
            Button { people.removeAll { $0.id == p.id } } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(p.displayName)")
            .accessibilityLabel("Remove \(p.displayName)")
        }
        .contextMenu {
            Button("Remove", role: .destructive) { people.removeAll { $0.id == p.id } }
        }
    }

    private func setRole(_ p: EventAttendee, optional: Bool) {
        guard let i = people.firstIndex(where: { $0.id == p.id }) else { return }
        people[i] = EventAttendee(name: p.name, email: p.email, type: optional ? "optional" : "required",
                                  response: p.response, isMe: p.isMe)
    }

    func addTyped() {
        for address in CalendarWeekStore.recipients(typed)
        where !people.contains(where: { $0.email.lowercased() == address.lowercased() }) {
            people.append(EventAttendee(name: address, email: address))
        }
        typed = ""
    }
}
