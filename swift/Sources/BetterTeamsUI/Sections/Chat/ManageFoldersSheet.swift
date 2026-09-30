// ManageFoldersSheet.swift — Manage Folders (UI-SPEC §6.2 Filter menu,
// §9.5): add, rename and remove chat folders. Edits stay in the sheet
// until Save (Cancel discards them); removing a folder returns its chats
// to Recent (FolderStore drops its rules and assignments). REGFIX-C R2: the
// Rules tab creates, edits, reorders and removes the automatic rules that
// file chats into folders by chat name, sender domain or chat type (first
// matching rule wins, a manual move always beats a rule). Rules apply at
// once: the list and folder filter resolve them while rendering.
import OstMacCore
import SwiftUI

struct ManageFoldersSheet: View {
    @ObservedObject var folders: FolderStore
    @State private var rows: [Row]
    @State private var picked: UUID?
    @State private var tab = Tab.folders
    @State private var ruleDrafts: [FolderRule]
    @State private var pickedRule: String?

    enum Tab: String, CaseIterable { case folders = "Folders", rules = "Rules" }
    @Environment(\.windowModel) private var model

    /// One folder in the sheet: an existing one (`folderID`) or a new one.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        let folderID: String?
        var name: String
    }

    init(folders: FolderStore, startOnRules: Bool = false) {
        self.folders = folders
        _tab = State(initialValue: startOnRules ? .rules : .folders)
        _rows = State(initialValue: folders.folders.map { Row(folderID: $0.id, name: $0.name) })
        _ruleDrafts = State(initialValue: folders.rules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Folders").font(.headline)
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == .folders { foldersTab } else { rulesTab }
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
        .frame(width: 420)
    }

    @ViewBuilder
    private var foldersTab: some View {
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
    }

    // MARK: Rules

    /// Folders a rule can file into: the saved ones, named as edited here.
    private var ruleFolders: [(id: String, name: String)] {
        rows.compactMap { r in r.folderID.map { ($0, r.name) } }
    }

    @ViewBuilder
    private var rulesTab: some View {
        InfoLabel(title: "Rules", subject: "folder rules",
                  text: "A chat goes to the folder of the first rule that matches it. Moving a chat by hand always wins.")
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $pickedRule) {
                ForEach($ruleDrafts) { $rule in
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.summary(rule))
                            Text("Folder: \(folderName(rule.folderID))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(rule.id)
                }
                .onMove { ruleDrafts.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 130)
            .overlay {
                if ruleDrafts.isEmpty {
                    ContentUnavailableView("No Rules", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text(ruleFolders.isEmpty
                                               ? "Save a folder first, then add rules for it."
                                               : "Add a rule to file chats automatically."))
                }
            }
            HStack(spacing: 0) {
                Button { addRule() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help("Add Rule")
                    .accessibilityLabel("Add Rule")
                    .disabled(ruleFolders.isEmpty)
                Button { removeRule() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .help("Remove Rule")
                    .accessibilityLabel("Remove Rule")
                    .disabled(pickedRule == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        if let i = ruleDrafts.firstIndex(where: { $0.id == pickedRule }) {
            ruleEditor($ruleDrafts[i])
        }
    }

    private func ruleEditor(_ rule: Binding<FolderRule>) -> some View {
        Form {
            Picker("Move to", selection: rule.folderID) {
                ForEach(ruleFolders, id: \.id) { Text($0.name).tag($0.id) }
            }
            TextField("Chat name contains", text: Binding(
                get: { rule.wrappedValue.namePattern ?? "" },
                set: { rule.wrappedValue.namePattern = $0 }))
            TextField("Sender domain", text: Binding(
                get: { rule.wrappedValue.senderDomain ?? "" },
                set: { rule.wrappedValue.senderDomain = $0 }), prompt: Text("contoso.com"))
            Picker("Chat type", selection: rule.kind) {
                Text("Any").tag(FolderKind?.none)
                Text("Group chats").tag(FolderKind?.some(.group))
                Text("1:1 chats").tag(FolderKind?.some(.direct))
            }
            if !rule.wrappedValue.hasMatchers {
                Text("Set at least one condition; a rule without one matches nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func folderName(_ id: String) -> String {
        rows.first { $0.folderID == id }?.name ?? "Unknown"
    }

    private func addRule() {
        guard let first = ruleFolders.first else { return }
        let rule = FolderRule(folderID: first.id)
        ruleDrafts.append(rule)
        pickedRule = rule.id
    }

    private func removeRule() {
        guard let id = pickedRule, let i = ruleDrafts.firstIndex(where: { $0.id == id }) else { return }
        ruleDrafts.remove(at: i)
        pickedRule = ruleDrafts.indices.contains(i) ? ruleDrafts[i].id : ruleDrafts.last?.id
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// One-line description of a rule's conditions.
    static func summary(_ r: FolderRule) -> String {
        var parts: [String] = []
        if let p = clean(r.namePattern) { parts.append("name contains \u{201C}\(p)\u{201D}") }
        if let d = clean(r.senderDomain) { parts.append("sender \(d)") }
        switch r.kind {
        case .group: parts.append("group chats")
        case .direct: parts.append("1:1 chats")
        case nil: break
        }
        return parts.isEmpty ? "New Rule" : parts.joined(separator: " or ")
    }

    /// Write the edited rules through the store (after the folders are
    /// saved, so a new folder exists). Rules of removed folders are gone
    /// with the folder; the rest replace the store's list in order.
    private func saveRules() { Self.commitRules(ruleDrafts, to: folders) }

    /// The save step as a pure function of the drafts (tests drive edit and
    /// reorder through it without a view).
    static func commitRules(_ drafts: [FolderRule], to folders: FolderStore) {
        let live = Set(folders.folders.map(\.id))
        let drafts = drafts.filter { live.contains($0.folderID) }
        guard drafts != folders.rules else { return }
        for r in folders.rules { folders.removeRule(id: r.id) }
        for r in drafts { _ = folders.addRule(r) }
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
        saveRules()
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
