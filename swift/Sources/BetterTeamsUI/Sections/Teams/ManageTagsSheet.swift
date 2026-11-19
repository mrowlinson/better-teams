// ManageTagsSheet.swift — team tag manager (TAGS lane, UI-SPEC §6.3).
//
// Owners create/rename/delete team tags and assign members. HIG:
// one native grouped form; explanations in (i) popovers only; every
// control works or is absent, nothing is faked. Live is scope-blocked
// (TeamworkTag.* not granted — live 403 proven 11-19), so the sheet
// shows the unavailable pane with the reason and no tag controls.
import OstMacCore
import SwiftUI

struct ManageTagsSheet: View {
    @ObservedObject var store: TeamTagsStore
    @ObservedObject var roster: TeamRosterViewModel
    let team: TeamItem
    /// Evidence/demo route forces the live-unavailable pane.
    let forceUnsupported: Bool
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if forceUnsupported || !store.canEdit {
                unavailable
            } else {
                form
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model?.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Manage Tags").font(.headline)
            Text(team.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Tag Management Unavailable",
            systemImage: "tag.slash",
            description: Text(TeamTags.unavailableReason)
        )
        .frame(maxHeight: .infinity)
    }

    private var form: some View {
        Form {
            Section("New Tag") {
                NewTagRow(store: store)
            }
            if store.tags.isEmpty {
                Section("Tags") {
                    Text("No tags yet").foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.tags) { tag in
                    Section {
                        TagEditor(store: store, roster: roster, tag: tag)
                    } header: {
                        Text(tag.displayName)
                    }
                }
            }
            if let err = store.error {
                Section {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// New-tag row: name field + Create (disabled on blank).
private struct NewTagRow: View {
    @ObservedObject var store: TeamTagsStore
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Tag name", text: $name, prompt: Text("e.g. Designers"))
            Button("Create") {
                if store.create(name: name, description: nil, memberIDs: []) { name = "" }
            }
            .disabled(TeamTags.validName(name) == nil)
        }
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            InfoButton(subject: "Team tags",
                       text: "Tags mention a group at once: @Designers notifies everyone assigned to it.")
        }
    }
}

/// One tag's editor: rename-on-commit, member checkmarks, delete.
private struct TagEditor: View {
    @ObservedObject var store: TeamTagsStore
    @ObservedObject var roster: TeamRosterViewModel
    let tag: TeamTag
    @State private var name: String
    @State private var selected: Set<String>
    @State private var confirmDelete = false
    @Environment(\.windowModel) private var model

    init(store: TeamTagsStore, roster: TeamRosterViewModel, tag: TeamTag) {
        self.store = store
        self.roster = roster
        self.tag = tag
        _name = State(initialValue: tag.displayName)
        _selected = State(initialValue: Set(tag.memberIDs))
    }

    var body: some View {
        TextField("Tag name", text: $name, onCommit: { _ = store.rename(id: tag.id, name: name) })
        if roster.members.isEmpty {
            Text("No members to assign").foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(sortedMembers, id: \.key) { m in
                Toggle(isOn: Binding(
                    get: { selected.contains(m.key) },
                    set: { on in
                        if on { selected.insert(m.key) } else { selected.remove(m.key) }
                        _ = store.setMembers(id: tag.id, memberIDs: Array(selected))
                    }
                )) {
                    Text(m.label).lineLimit(1)
                }
            }
        }
        Button("Delete Tag", role: .destructive) { confirmDelete = true }
            .confirmationDialog("Delete “\(tag.displayName)”?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Tag", role: .destructive) { _ = store.remove(id: tag.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mentioning it will no longer notify anyone.")
            }
    }

    private var sortedMembers: [(key: String, label: String)] {
        roster.members.map { m in
            let key = (m.userId?.isEmpty == false ? m.userId! : m.id)
            let label = TeamRosterViewModel.displayName(for: m, names: roster.names)
            let you = model?.isOwnID(m.userId) == true || model?.isOwnID(m.id) == true
            return (key, you ? "You" : label)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
