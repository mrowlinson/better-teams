// PhoneViews.swift — PHONEUI lane: the Phone sheet (dial pad, voicemail,
// forwarding, delegates). Native controls only: TabView, Form, Picker,
// Toggle, List, LabeledContent (HIG; Teams is behavior reference, never
// visual). Live controls are disabled-with-reason until PSTN-TRIAL proves
// a Teams Phone licence (PhoneStore.liveReason on every one).
import OstMacCore
import SwiftUI

// MARK: sheet

/// Phone sheet tabs (evidence route `calls?phone=<rawValue>`, demo only).
enum PhoneTab: String, CaseIterable, Identifiable {
    case dial
    case voicemail
    case forwarding
    case delegates

    var id: String { rawValue }
}

struct PhoneSheet: View {
    @ObservedObject var phone: PhoneStore
    @State private var selection: PhoneTab
    @Environment(\.windowModel) private var model
    /// Evidence (demo route `calls?phone=<tab>`): open on that tab at once.
    static var evidenceTab: PhoneTab?

    init(phone: PhoneStore, initialTab: PhoneTab? = nil) {
        self.phone = phone
        _selection = State(initialValue: initialTab ?? Self.evidenceTab ?? .dial)
        Self.evidenceTab = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Phone").font(.headline)
                Spacer()
                Button("Done") { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            TabView(selection: $selection) {
                DialPadView(phone: phone)
                    .tabItem { Label("Dial Pad", systemImage: "circle.grid.3x3") }
                    .tag(PhoneTab.dial)
                VoicemailView(phone: phone)
                    .tabItem { Label("Voicemail", systemImage: "recordingtape") }
                    .tag(PhoneTab.voicemail)
                ForwardingView(phone: phone)
                    .tabItem { Label("Forwarding", systemImage: "phone.arrow.up.right") }
                    .tag(PhoneTab.forwarding)
                DelegatesView(phone: phone)
                    .tabItem { Label("Delegates", systemImage: "person.2") }
                    .tag(PhoneTab.delegates)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { phone.refresh() }
    }
}

/// Every live surface that cannot work without a licence shows this, not
/// a bare disabled control: what is missing and where a working copy lives.
struct PhoneUnavailablePane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "phone.badge.waveform")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(PhoneStore.liveReason)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("The demo workspace includes a working preview.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: dial pad

/// Dial pad (§R1): native button grid + number field. Demo Call runs a
/// local simulated call (no wire, no core slot); live Call is disabled
/// with the licence reason.
struct DialPadView: View {
    @ObservedObject var phone: PhoneStore
    @State private var entry = ""
    @State private var dialing: String?
    @State private var dialStart = Date()
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            if let number = dialing {
                demoCallPane(number)
            } else {
                entryField
                keyGrid
                callRow
            }
            if !phone.isDemo {
                Text(PhoneStore.liveReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { now = $0 }
    }

    private var entryField: some View {
        HStack {
            TextField("Phone number", text: $entry)
                .textFieldStyle(.roundedBorder)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .onChange(of: entry) { _, v in entry = DialPad.normalize(v) }
            if !entry.isEmpty {
                Button { entry = "" } label: {
                    Label("Clear", systemImage: "delete.left")
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private var keyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
            ForEach(DialPad.keys, id: \.self) { key in
                Button(key) { entry = DialPad.normalize(entry + key) }
                    .font(.title)
                    .monospacedDigit()
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: 280)
    }

    private var callRow: some View {
        HStack(spacing: 8) {
            if phone.isDemo {
                Button("Call") {
                    dialing = DialPad.normalize(entry)
                    dialStart = Date()
                    now = Date()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!DialPad.isDialable(entry))
            } else {
                Button("Call") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .help(PhoneStore.liveReason)
            }
        }
    }

    private func demoCallPane(_ number: String) -> some View {
        let elapsed = max(0, Int(now.timeIntervalSince(dialStart)))
        return VStack(spacing: 12) {
            Image(systemName: "phone.connection.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Calling \(number) (demo)…")
                .font(.headline)
            Text(Self.elapsedLabel(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("End") { dialing = nil }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func elapsedLabel(_ secs: Int) -> String {
        String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

// MARK: voicemail

/// Demo mailbox: seeded messages, simulated playback, mark-heard. Live
/// shows the licence reason (no delegated Graph voicemail read exists).
struct VoicemailView: View {
    @ObservedObject var phone: PhoneStore
    @State private var playingID: String?
    @State private var progress: Double = 0
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        if phone.isDemo {
            demoMailbox
        } else {
            PhoneUnavailablePane()
        }
    }

    private var demoMailbox: some View {
        Group {
            if phone.messages.isEmpty {
                ContentUnavailableView("No Voicemail", systemImage: "recordingtape")
            } else {
                List(phone.messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.callerName)
                                .fontWeight(m.isRead ? .regular : .semibold)
                            Spacer()
                            Text(Self.dateLabel(m.at))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button(playingID == m.id ? "Pause" : "Play") { togglePlay(m) }
                                .buttonStyle(.link)
                            if playingID == m.id {
                                ProgressView(value: progress)
                                    .frame(width: 120)
                            } else {
                                Text(Self.durationLabel(m.durationSecs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !m.isRead {
                                Button("Mark Heard") { phone.markHeard(id: m.id) }
                                    .buttonStyle(.link)
                            }
                        }
                        if let t = m.transcript {
                            Text(t)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { stopPlayback() }
    }

    private func togglePlay(_ m: VoicemailMessage) {
        if playingID == m.id {
            stopPlayback()
            return
        }
        stopPlayback()
        playingID = m.id
        progress = 0
        let total = max(1, m.durationSecs)
        playTask = Task { @MainActor in
            while progress < 1 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                progress = min(1, progress + 0.25 / Double(total))
            }
            phone.markHeard(id: m.id)
            playingID = nil
            progress = 0
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        playingID = nil
        progress = 0
    }

    static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func durationLabel(_ secs: Int) -> String {
        String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

// MARK: forwarding

/// Forwarding editor (Form + Picker + Toggle). Demo saves to the fake;
/// live is disabled with the licence reason (no delegated Graph shape).
struct ForwardingView: View {
    @ObservedObject var phone: PhoneStore
    @State private var mode: CallForwardingMode = .off
    @State private var target = ""
    @State private var simultaneousRing = false
    @State private var problem: String?

    var body: some View {
        if phone.isDemo {
            demoEditor
                .onAppear { adopt(phone.forwarding) }
                .onChange(of: phone.forwarding) { _, f in adopt(f) }
        } else {
            PhoneUnavailablePane()
        }
    }

    private var demoEditor: some View {
        Form {
            Section("Forward my calls") {
                Picker("Forward my calls:", selection: $mode) {
                    ForEach(CallForwardingMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { _, _ in problem = nil }
            }
            if mode.needsTarget {
                Section("Target") {
                    TextField("Phone number", text: $target)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: target) { _, v in target = DialPad.normalize(v) }
                }
            }
            Section {
                Toggle("Also ring me at the same time", isOn: $simultaneousRing)
                    .disabled(mode == .off)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
            if let problem {
                Section {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private func adopt(_ f: CallForwardingSettings) {
        mode = f.mode
        target = f.target
        simultaneousRing = f.simultaneousRing
    }

    private var canSave: Bool {
        CallForwardingSettings(mode: mode, target: target,
                               simultaneousRing: simultaneousRing).validate() == nil
    }

    private func save() {
        let s = CallForwardingSettings(mode: mode, target: target, simultaneousRing: simultaneousRing)
        guard let issue = s.validate() else {
            problem = nil
            phone.saveForwarding(s)
            return
        }
        problem = issue
    }
}

// MARK: delegates

/// Delegates list (List + add/remove). Demo edits the fake; live is
/// disabled with the licence reason (beta Graph needs CallDelegation
/// scope + licence — PSTN-TRIAL owns first proof).
struct DelegatesView: View {
    @ObservedObject var phone: PhoneStore
    @State private var email = ""
    @State private var problem: String?

    var body: some View {
        if phone.isDemo {
            demoList
        } else {
            PhoneUnavailablePane()
        }
    }

    private var demoList: some View {
        VStack(spacing: 0) {
            if phone.people.isEmpty {
                ContentUnavailableView("No Delegates", systemImage: "person.2",
                                       description: Text("Delegates can answer your calls when you cannot."))
            } else {
                List {
                    ForEach(phone.people) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.displayName)
                                if let e = d.email {
                                    Text(e).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove") { phone.removeDelegate(id: d.id) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                TextField("Add delegate by email", text: $email)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { add() }
                    .disabled(!Self.isEmail(email))
            }
            .padding(12)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.bottom, 8)
            }
            Text("Delegates need a Teams Phone licence and your admin's delegation policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
    }

    private func add() {
        guard Self.isEmail(email) else {
            problem = "Enter an email address."
            return
        }
        problem = nil
        phone.addDelegate(email: email)
        email = ""
    }

    /// Address shape only (the fake accepts any well-formed address).
    static func isEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex, at != t.index(before: t.endIndex) else { return false }
        return t[t.index(after: at)...].contains(".")
    }
}
