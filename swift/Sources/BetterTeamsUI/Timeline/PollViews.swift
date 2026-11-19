// PollViews.swift — polls lane: vote + results card in the timeline,
// and the create sheet in the composer. Native controls only
// (buttons, text fields, toggles, progress bars); no web-look.
import OstMacCore
import SwiftUI

/// Ballot state for one poll bubble: the resolved poll, this device's
/// vote, and the current tally. Refreshes from the registry after
/// every vote (votes are device-local until server sync lands).
@MainActor
final class PollBallotModel: ObservableObject {
    let messageID: String
    let poll: Poll?
    @Published var myVote: Set<String> = []
    @Published var tally: [(option: PollOption, votes: Int)] = []
    @Published var voters = 0
    @Published var error: String?

    init(messageID: String, content: String, raw: String?) {
        self.messageID = messageID
        self.poll = PollRegistry.resolve(messageID: messageID, content: content, raw: raw)
        refresh()
    }

    func refresh() {
        guard let poll else { return }
        myVote = PollRegistry.myVote(messageID: messageID)
        tally = PollRegistry.tally(messageID: messageID) ?? poll.options.map { ($0, 0) }
        voters = PollRegistry.ballotCount(messageID: messageID)
    }

    /// Toggle one option: single-choice replaces, multi-choice flips
    /// membership. Guard failures surface as `error` text.
    func tap(_ optionID: String) {
        guard let poll else { return }
        error = nil
        if poll.closed {
            error = PollVoteError.closed.rawValue
            return
        }
        let next: Set<String>
        if poll.allowMultiple {
            next = myVote.contains(optionID) ? myVote.subtracting([optionID]) : myVote.union([optionID])
        } else {
            next = [optionID]
        }
        do {
            try PollRegistry.vote(messageID: messageID, optionIDs: next)
        } catch let e as PollVoteError {
            error = e.rawValue
            return
        } catch {
            self.error = "Couldn't record that vote."
            return
        }
        refresh()
    }
}

/// Vote + results card for one poll bubble. No poll renders nothing.
struct PollCardBlock: View {
    let messageID: String
    let content: String
    let raw: String?
    @StateObject private var model: PollBallotModel

    init(messageID: String, content: String, raw: String?) {
        self.messageID = messageID
        self.content = content
        self.raw = raw
        _model = StateObject(wrappedValue: PollBallotModel(
            messageID: messageID, content: content, raw: raw))
    }

    var body: some View {
        if let poll = model.poll {
            PollCardView(model: model, poll: poll)
                .padding(10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Poll: \(poll.question)")
        }
    }
}

private struct PollCardView: View {
    @ObservedObject var model: PollBallotModel
    let poll: Poll

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(poll.options) { opt in
                PollOptionRow(
                    option: opt,
                    votes: model.tally.first(where: { $0.option.id == opt.id })?.votes ?? 0,
                    total: max(model.voters, 1),
                    selected: model.myVote.contains(opt.id),
                    closed: poll.closed,
                    tap: { model.tap(opt.id) })
            }
            footer
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if poll.closed {
                Label("Closed", systemImage: "lock.fill")
            } else if model.voters == 0 {
                Text("Be the first to vote.")
            } else {
                Text("\(model.voters) vote\(model.voters == 1 ? "" : "s")")
            }
            if poll.allowMultiple, !poll.closed {
                Text("· Multiple choices allowed")
            }
            Spacer(minLength: 0)
            Text("Local votes only")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PollOptionRow: View {
    let option: PollOption
    let votes: Int
    let total: Int
    let selected: Bool
    let closed: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(option.text)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(votes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.tint.opacity(0.25))
                        .frame(width: proxy.size.width * share)
                        .frame(height: 4, alignment: .leading)
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(closed)
        .help(closed ? "This poll is closed." : selected ? "Voted — tap to change." : "Vote for \(option.text).")
        .accessibilityLabel("\(option.text), \(votes) votes\(selected ? ", your vote" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private var share: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(votes) / Double(total))
    }
}

// MARK: - Create sheet

/// New-poll sheet: question field, option rows (add/remove), a
/// multiple-choice toggle, and inline validation. Create posts through
/// `ConversationStore.sendPoll` and dismisses.
struct PollComposerSheet: View {
    @ObservedObject var conv: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var allowMultiple = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Poll")
                .font(.headline)
            TextField("Question", text: $question)
                .textFieldStyle(.roundedBorder)
            ForEach(options.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("Option \(i + 1)", text: $options[i])
                        .textFieldStyle(.roundedBorder)
                    if options.count > 2 {
                        Button {
                            options.remove(at: i)
                            error = nil
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove option \(i + 1).")
                        .accessibilityLabel("Remove option \(i + 1).")
                    }
                }
            }
            if options.count < PollValidation.maxOptions {
                Button {
                    options.append("")
                } label: {
                    Label("Add Option", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
            }
            Toggle("Allow multiple choices", isOn: $allowMultiple)
                .toggleStyle(.switch)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Post Poll") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(conv.chatID == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New poll")
    }

    private func create() {
        if let failure = PollValidation.validate(question: question, options: options) {
            error = failure
            return
        }
        guard conv.sendPoll(question: question, options: options, allowMultiple: allowMultiple) != nil
        else {
            error = "Couldn't post that poll."
            return
        }
        dismiss()
    }
}
