// ManageFoldersSheet.swift — Manage Folders (UI-SPEC §6.2 Filter menu,
// §9.5): add, rename and remove chat folders. Edits stay in the sheet
// until Save (Cancel discards them); removing a folder returns its chats
// to Recent (FolderStore drops its rules and assignments).
import OstMacCore
import SwiftUI

struct ManageFoldersSheet: View {
    @ObservedObject var folders: FolderStore
    @State private var rows: [Row]
    @State private var picked: UUID?
    @Environment(\.windowModel) private var model

    /// One folder in the sheet: an existing one (`folderID`) or a new one.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        let folderID: String?
        var name: String
    }

    init(folders: FolderStore) {
        self.folders = folders
        _rows = State(initialValue: folders.folders.map { Row(folderID: $0.id, name: $0.name) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Folders").font(.headline)
            Text("Folders appear in the Filter menu.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $picked) {
                    ForEach($rows) { $row in
                        TextField("Folder Name", text: $row.name)
                            .textFieldStyle(.plain)
                            .tag(row.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 180)
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("No Folders", systemImage: "folder",
                                               description: Text("Add a folder to group chats."))
                    }
                }
                // Stock add/remove pair under the list (the macOS idiom).
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add Folder")
                        .accessibilityLabel("Add Folder")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .help("Remove Folder")
                        .accessibilityLabel("Remove Folder")
                        .disabled(picked == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.isValid(rows.map(\.name)))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        let row = Row(folderID: nil, name: Self.newName(existing: rows.map(\.name)))
        rows.append(row)
        picked = row.id
    }

    private func remove() {
        guard let id = picked, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: i)
        picked = rows.indices.contains(i) ? rows[i].id : rows.last?.id
    }

    private func save() {
        let kept = Set(rows.compactMap(\.folderID))
        for f in folders.folders where !kept.contains(f.id) { folders.deleteFolder(id: f.id) }
        for row in rows {
            if let id = row.folderID {
                if folders.name(for: id) != row.name { folders.renameFolder(id: id, name: row.name) }
            } else {
                folders.createFolder(name: row.name)
            }
        }
        model?.dismissSheet()
    }

    /// Names must be non-blank and unique (case-insensitive), as the
    /// store requires; Save stays disabled otherwise.
    static func isValid(_ names: [String]) -> Bool {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return !clean.contains("") && Set(clean).count == clean.count
    }

    /// "New Folder", then "New Folder 2", … (unique among `existing`).
    static func newName(existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var n = 1
        while true {
            let name = n == 1 ? "New Folder" : "New Folder \(n)"
            if !taken.contains(name.lowercased()) { return name }
            n += 1
        }
    }
}
