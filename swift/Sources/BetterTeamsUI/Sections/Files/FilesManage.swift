// FilesManage.swift — Rename… / Move To… / Copy To… / Delete… (UI-SPEC
// §6.6 context menu). A command resolves its file to the store that
// listed it (the Files index, the channel library, or a conversation's
// Files tab) and acts there; demo acts on the in-memory rows only.
// Rename and the Move/Copy destination picker are section sheets
// (SheetPresenter, R17); Delete… confirms with the stock alert (§9.5).
// Delete / Move / Copy act on every selected item (Finder), one confirm
// naming the count; Rename is single-item. The menu-bar Delete (⌘⌫)
// acts only while the file table has keyboard focus, so ⌘⌫ in a text
// field deletes text.
import AppKit
import OstMacCore
import SwiftUI

extension FilesSection {
    /// The store behind a row: the Files index (Recent / My Files /
    /// Shared in Chats) or a folder listing (channel library, a
    /// conversation's Files tab).
    enum ManageTarget {
        case index(UnifiedFilesStore, UnifiedFileRow)
        case listing(SharedFilesStore, SharedFile)

        var file: SharedFile {
            switch self {
            case .index(_, let r): r.file
            case .listing(_, let f): f
            }
        }
    }

    static let manageCommands: Set<CommandID> = [
        FilesCommands.rename, FilesCommands.moveTo, FilesCommands.copyTo, FilesCommands.delete,
    ]

    func manageTarget(_ it: FileItem, arg: String?, _ m: WindowModel) -> ManageTarget? {
        guard let app = m.app, let row = it.row, row.file.drive_id != nil else { return nil }
        if arg?.hasPrefix(Self.conversationPrefix) == true {
            return .listing(app.shared, app.shared.files.first { $0.id == row.file.id } ?? row.file)
        }
        if case .channel = Self.source(m) {
            return .listing(library, library.files.first { $0.id == row.file.id } ?? row.file)
        }
        return .index(app.unifiedFiles, row)
    }

    /// Separator between the per-item args of a multi-item command.
    static let argSeparator: Character = "\n"

    /// One command arg naming several items (each a normal arg).
    static func multiArg(_ args: [String]) -> String {
        args.joined(separator: String(argSeparator))
    }

    /// A command's items: every part of a multi-item arg, or (menu bar,
    /// arg nil) every selected row of the shown source.
    func items(forArg arg: String?, _ m: WindowModel) -> [FileItem] {
        if let arg {
            return arg.split(separator: Self.argSeparator).compactMap { item(String($0), m) }
        }
        guard m.nav.section == .files, let app = m.app else { return [] }
        let ids = Set(Self.selectedIDs(m))
        return items(Self.source(m), app).filter { ids.contains($0.id) }
    }

    /// The manageable items (drive items) a command acts on.
    func manageTargets(arg: String?, _ m: WindowModel) -> [ManageTarget] {
        guard let arg else {
            return items(forArg: nil, m).compactMap { manageTarget($0, arg: nil, m) }
        }
        return arg.split(separator: Self.argSeparator).compactMap { part in
            let a = String(part)
            return item(a, m).flatMap { manageTarget($0, arg: a, m) }
        }
    }

    /// True while the Files table (the header-bearing table; the source
    /// list and inspector have none) is the window's first responder.
    static func fileTableHasFocus(_ m: WindowModel) -> Bool {
        guard let table = window(m)?.firstResponder as? NSTableView else { return false }
        return table.headerView != nil
    }

    /// Root name in the destination picker: a channel's SharePoint
    /// library, else the OneDrive the file lives in.
    static func rootName(_ t: ManageTarget) -> String {
        switch t {
        case .index(_, let row): row.source == .channel ? "Documents" : "OneDrive"
        case .listing(let store, _): ChannelTabsStore.isChannelID(store.chatID ?? "") ? "Documents" : "OneDrive"
        }
    }

    func validateManage(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        let targets = manageTargets(arg: arg, m)
        guard !targets.isEmpty else { return .disabled }
        switch c {
        case FilesCommands.rename:
            return CommandValidation(enabled: targets.count == 1)
        case FilesCommands.moveTo, FilesCommands.copyTo:
            // Graph moves and copies within one drive.
            return CommandValidation(enabled: Set(targets.compactMap(\.file.drive_id)).count == 1)
        case FilesCommands.delete:
            // The menu-bar item (⌘⌫) only while the table has focus.
            return CommandValidation(enabled: arg != nil || Self.fileTableHasFocus(m))
        default:
            return .enabled
        }
    }

    func performManage(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard validateManage(c, arg: arg, m).enabled else { return false }
        let targets = manageTargets(arg: arg, m)
        // Sheets re-resolve their items from this arg.
        let key = arg ?? Self.multiArg(items(forArg: nil, m).map(\.id))
        switch c {
        case FilesCommands.rename:
            m.presentSheet(SheetRequest(FilesCommands.renameSheet, in: .files, arg: key))
        case FilesCommands.moveTo:
            m.presentSheet(SheetRequest(FilesCommands.destinationSheet, in: .files, arg: "move|" + key))
        case FilesCommands.copyTo:
            m.presentSheet(SheetRequest(FilesCommands.destinationSheet, in: .files, arg: "copy|" + key))
        case FilesCommands.delete:
            let title: String
            let what: String
            if targets.count == 1, let t = targets.first {
                title = "Delete \u{201C}\(t.file.name)\u{201D}?"
                what = t.file.isFolder ? "The folder and everything in it" : "The file"
            } else {
                title = "Delete \(targets.count) items?"
                what = "The items"
            }
            m.confirm(title: title, message: "\(what) moves to the OneDrive or SharePoint recycle bin.",
                      action: "Delete") {
                for t in targets {
                    switch t {
                    case .index(let store, let row): store.delete(row)
                    case .listing(let store, let file): store.delete(file)
                    }
                }
            }
        default:
            return false
        }
        return true
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        switch r.name {
        case FilesCommands.renameSheet:
            guard let arg = r.arg, let it = item(arg, m), let t = manageTarget(it, arg: arg, m) else { return nil }
            return AnyView(RenameFileSheet(name: it.name) { name in
                switch t {
                case .index(let store, let row): store.rename(row, to: name)
                case .listing(let store, let file): store.rename(file, to: name)
                }
            })
        case FilesCommands.destinationSheet:
            guard let raw = r.arg, let bar = raw.firstIndex(of: "|") else { return nil }
            let copy = raw[..<bar] == "copy"
            let targets = manageTargets(arg: String(raw[raw.index(after: bar)...]), m)
            guard let first = targets.first, let drive = first.file.drive_id else { return nil }
            let picker = FolderPickerStore(driveID: drive, rootName: Self.rootName(first),
                                           excluding: Set(targets.map(\.file.id)), demo: m.options.demo)
            let title = targets.count == 1 ? "\u{201C}\(first.file.name)\u{201D}" : "\(targets.count) Items"
            return AnyView(FileDestinationSheet(copy: copy, title: title, picker: picker) { [weak self] dest in
                for t in targets { self?.place(t, in: dest, copy: copy, m) }
            })
        default:
            return nil
        }
    }

    /// One Move/Copy. Demo mirrors a folder listing's move or copy into
    /// the Files index (same file) so Recent and My Files follow.
    private func place(_ t: ManageTarget, in dest: SharedFolderCrumb, copy: Bool, _ m: WindowModel) {
        switch t {
        case .index(let store, let row):
            if copy {
                store.copy(row, toFolder: dest.itemID, folderName: dest.name)
            } else {
                store.move(row, toFolder: dest.itemID, folderName: dest.name)
            }
        case .listing(let store, let file):
            if copy { store.copy(file, toFolder: dest.itemID) } else { store.move(file, toFolder: dest.itemID) }
            guard m.options.demo, let index = m.app?.unifiedFiles,
                  let row = index.rows.first(where: { $0.id == UnifiedFileRow.key(for: file) }) else { return }
            place(.index(index, row), in: dest, copy: copy, m)
        }
    }
}

/// Rename… sheet: one name field; Rename is the default button and
/// stays off while the name is blank or unchanged.
struct RenameFileSheet: View {
    let name: String
    let commit: (String) -> Void
    @State private var text: String
    @Environment(\.windowModel) private var model

    init(name: String, commit: @escaping (String) -> Void) {
        self.name = name
        self.commit = commit
        _text = State(initialValue: name)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \u{201C}\(name)\u{201D}").font(.headline).lineLimit(1).truncationMode(.middle)
            Form {
                TextField("Name", text: $text)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    commit(trimmed)
                    model?.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || trimmed == name)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Move To… / Copy To… destination picker, browser style: Back + the
/// path pop-up over the open folder's subfolders (double-click or
/// Return opens one). The action goes to the selected subfolder, else
/// to the open folder (the drive root included).
struct FileDestinationSheet: View {
    let copy: Bool
    /// "“Name”" or "3 Items".
    let title: String
    @ObservedObject var picker: FolderPickerStore
    let commit: (SharedFolderCrumb) -> Void
    @State private var picked: String?
    @Environment(\.windowModel) private var model

    private var action: String { copy ? "Copy" : "Move" }
    private var target: SharedFolderCrumb { picker.folders.first { $0.itemID == picked } ?? picker.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(action) \(title) To").font(.headline).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Button {
                    go(to: picker.path.count - 2)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(picker.path.count < 2)
                .help("Back")
                .accessibilityLabel("Back")
                Picker("Folder", selection: pathSelection) {
                    ForEach(Indexed.wrap(picker.path)) { p in
                        Label(p.value.name, systemImage: p.id == 0 ? "externaldrive" : "folder").tag(p.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            List(picker.folders, id: \.itemID, selection: $picked) { f in
                HStack(spacing: 6) {
                    Label(f.name, systemImage: "folder").lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                guard let id = ids.first, let f = picker.folders.first(where: { $0.itemID == id }) else { return }
                picked = nil
                picker.enter(f)
            }
            .listStyle(.bordered)
            .frame(height: 200)
            .overlay { placeholder }
            HStack(spacing: 8) {
                Text("To: \(target.name)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(action) {
                    commit(target)
                    model?.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var pathSelection: Binding<Int> {
        Binding(get: { picker.path.count - 1 }, set: { go(to: $0) })
    }

    private func go(to index: Int) {
        picked = nil
        picker.goTo(index: index)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch picker.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .empty:
            Text("No Folders").foregroundStyle(.secondary)
        case .error(let message):
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        case .loaded:
            EmptyView()
        }
    }
}
