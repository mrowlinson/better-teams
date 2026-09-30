// PopOutWindows.swift — REGFIX-B R1: a meeting and a file in their own
// native windows (chat and channel already have theirs: ChatWindow,
// ChannelWindow). One window per key; the pop-out registries in core
// (MeetingPopOutStore, FilePopOutStore) keep the per-key stores, so a
// re-open focuses the window and a close keeps the state for the session.
import AppKit
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers

/// How a pop-out window reaches the screen. Tests replace it so no window
/// is ever ordered in (they still see the controller and its window).
@MainActor
enum PopOutPresenter {
    static var present: (NSWindowController) -> Void = { c in
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }
}

/// One titled, resizable window per key, hosted like every other pane.
@MainActor
class PopOutWindowController: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}

    init<V: View>(model m: WindowModel, root: V, title: String, size: NSSize, autosave: String) {
        let host = Hosting.controller(root, role: .pane, model: m)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 340, height: 300)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(autosave)
        super.init(window: window)
        window.delegate = self
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosave)") == nil { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) { onClose() }

    func bringForward() { PopOutPresenter.present(self) }
}

// MARK: meeting

@MainActor
final class MeetingWindowController: PopOutWindowController {
    private static var open: [String: MeetingWindowController] = [:]

    /// Open (or bring forward) the meeting's window.
    static func show(_ m: WindowModel, meeting: MeetingItem) {
        guard let app = m.app else { return }
        if let c = open[meeting.id] { c.bringForward(); return }
        guard app.popOutMeeting(key: meeting.id, subject: meeting.subject) != nil else { return }
        app.openMeetingPopout(key: meeting.id)
        let key = meeting.id
        let c = MeetingWindowController(
            model: m,
            root: MeetingPopoutView(key: key, subject: meeting.subject,
                                    roster: app.meetingPopouts.rosterStore(for: key),
                                    chat: app.meetingPopouts.chatStore(for: key), pops: app.meetingPopouts),
            title: app.meetingPopoutName(for: key), size: NSSize(width: 460, height: 560), autosave: "MeetingWindow")
        c.onClose = { [weak app] in
            app?.meetingPopouts.close(key: key)
            open[key] = nil
        }
        open[key] = c
        c.bringForward()
    }

    static func window(for key: String) -> NSWindow? { open[key]?.window }
}

/// People | Chat over the pop-out's own roster and thread stores.
struct MeetingPopoutView: View {
    let key: String
    let subject: String
    @ObservedObject var roster: MeetingRosterStore
    @ObservedObject var chat: MeetingChatStore
    let pops: MeetingPopOutStore
    @State private var segment = "chat"
    @State private var draft = ""
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $segment) {
                Text("Chat").tag("chat")
                Text("People").tag("people")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if segment == "people" { people } else { thread }
        }
        .onAppear { draft = pops.draft(for: key) }
    }

    @ViewBuilder
    private var people: some View {
        let here = roster.participants.filter(\.present)
        if here.isEmpty {
            EmptyPane("No One Here Yet", systemImage: "person.2", message: "People appear once the meeting starts.")
        } else {
            List(here) { p in
                HStack(spacing: 8) {
                    Avatar(name: p.name)
                    Text(p.name).font(AppFont.body(scale)).lineLimit(1)
                    Spacer(minLength: 4)
                    if p.speaking { Image(systemName: "waveform").foregroundStyle(.tint).accessibilityLabel("Speaking") }
                    if p.muted { Image(systemName: "mic.slash.fill").foregroundStyle(.secondary).accessibilityLabel("Muted") }
                }
            }
        }
    }

    @ViewBuilder
    private var thread: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                EmptyPane("No Messages", systemImage: "bubble.left.and.bubble.right",
                          message: "The meeting chat shows here.")
            } else {
                List(chat.messages) { msg in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(msg.isOwn ? "You" : msg.sender).font(AppFont.bodyEmphasized(scale))
                        Text(msg.content).font(AppFont.body(scale)).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onChange(of: draft) { _, new in pops.saveDraft(new, for: key) }
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    chat.send(text: t)
                    draft = ""
                }
        }
    }
}

// MARK: file

@MainActor
final class FileWindowController: PopOutWindowController {
    private static var open: [String: FileWindowController] = [:]

    /// Open (or bring forward) the file's window. `chatID` = the
    /// conversation it was shared in ("" for drive files).
    static func show(_ m: WindowModel, chatID: String, file: SharedFile) {
        guard let app = m.app else { return }
        let key = FilePopOutStore.key(chatID: chatID.trimmingCharacters(in: .whitespacesAndNewlines),
                                      fileID: file.id.trimmingCharacters(in: .whitespacesAndNewlines))
        if let c = open[key] { c.bringForward(); return }
        _ = app.popOutFile(chatID: chatID, file: file)
        guard app.filePopouts.entry(for: key) != nil else { return }
        let c = FileWindowController(
            model: m, root: FilePopoutView(pops: app.filePopouts, key: key), title: file.name,
            size: NSSize(width: 420, height: 460), autosave: "FileWindow")
        c.onClose = { [weak app] in
            app?.filePopouts.close(key: key)
            open[key] = nil
        }
        open[key] = c
        c.bringForward()
    }

    static func window(forFile chatID: String, fileID: String) -> NSWindow? {
        open[FilePopOutStore.key(chatID: chatID, fileID: fileID)]?.window
    }
}

/// The file's snapshot (live-updated in place by the registry): name,
/// kind, size, dates, sender, location; Open in Browser and Copy Link.
struct FilePopoutView: View {
    @ObservedObject var pops: FilePopOutStore
    let key: String
    @Environment(\.windowModel) private var model

    var body: some View {
        if let file = pops.entry(for: key)?.file {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(nsImage: Self.icon(file)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                        Text(file.name).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Section("Info") {
                    LabeledContent("Kind", value: Self.kind(file))
                    if !file.isFolder { LabeledContent("Size", value: FilesFormat.size(file.size)) }
                    if let m = file.modified ?? file.created { LabeledContent("Modified", value: FilesFormat.date(iso: m)) }
                    if let s = file.sender, !s.isEmpty { LabeledContent("Modified By", value: s) }
                    if let loc = file.source_name, !loc.isEmpty { LabeledContent("Location", value: loc) }
                }
                Section {
                    HStack {
                        Button("Open in Browser") { open(file) }
                            .disabled(Self.url(file) == nil || model?.options.demo == true)
                        Button("Copy Link") { copy(file) }.disabled(Self.url(file) == nil)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyPane("File Not Available", systemImage: "doc", message: "This file is no longer available.")
        }
    }

    static func url(_ f: SharedFile) -> URL? { (f.share_url ?? f.web_url).flatMap(URL.init(string:)) }

    static func icon(_ f: SharedFile) -> NSImage {
        let type: UTType = f.isFolder ? .folder : (UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    static func kind(_ f: SharedFile) -> String {
        if f.isFolder { return "Folder" }
        return UTType(filenameExtension: (f.name as NSString).pathExtension)?.localizedDescription ?? "Document"
    }

    private func open(_ f: SharedFile) { if let u = Self.url(f) { TeamsLinkRouter.open(u) } }

    private func copy(_ f: SharedFile) {
        guard let u = Self.url(f) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }
}
