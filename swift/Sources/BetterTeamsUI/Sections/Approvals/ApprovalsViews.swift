// ApprovalsViews.swift — approvals list, detail and pane states
// (UI-SPEC §6.7, §6 row conventions, R18 pane states).
import OstMacCore
import SwiftUI

// MARK: states

/// What the requests pane shows. Titles state the condition (R18).
enum ApprovalsListState: Equatable {
    case loading
    case error(title: String, message: String)
    case empty
    case requests

    static let emptyTitle = "No Requests"
    static let emptyMessage = "Your approval requests appear here."
    static let errorTitle = "Couldn\u{2019}t Load Requests"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "Your requests appear when you\u{2019}re back online."

    /// R12: requests on screen are never replaced by a spinner or error.
    static func resolve(_ state: ApprovalsState, requestCount: Int, forced: ForcedPaneState?,
                        offline: Bool) -> ApprovalsListState {
        func failed(_ m: String) -> ApprovalsListState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        if requestCount > 0 { return .requests }
        switch state {
        case .loading: return .loading
        case .error(let m): return failed(m)
        case .empty, .loaded: return .empty
        }
    }

    /// A failed refresh behind the requests on screen (quiet notice).
    static func failure(_ state: ApprovalsState) -> String? {
        if case .error(let m) = state { m } else { nil }
    }
}

/// What the detail pane shows.
enum ApprovalsDetailState: Equatable {
    case noSelection
    case loading
    case error(title: String, message: String)
    case detail

    static let noSelectionTitle = "No Request Selected"
    static let errorTitle = "Couldn\u{2019}t Load Request"

    static func resolve(itemSelected: Bool, showing: Bool, loading: Bool, error: String?,
                        offline: Bool) -> ApprovalsDetailState {
        guard itemSelected else { return .noSelection }
        guard showing, !loading else { return .loading }
        if error != nil {
            return offline
                ? .error(title: ApprovalsListState.offlineTitle, message: ApprovalsListState.offlineMessage)
                : .error(title: errorTitle, message: error ?? "Something went wrong.")
        }
        return .detail
    }
}

enum ApprovalsFormat {
    /// State badge symbol + label.
    static func stateLabel(_ state: ApprovalState) -> (symbol: String, text: String) {
        switch state {
        case .pending: ("clock", "Pending")
        case .created: ("circle.dotted", "Not started")
        case .completed: ("checkmark.circle", "Completed")
        case .canceled: ("xmark.circle", "Canceled")
        case .unknown: ("questionmark.circle", "Unknown")
        }
    }
}

// MARK: list

struct ApprovalsListPane: View {
    @ObservedObject var approvals: ApprovalStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let state = ApprovalsListState.resolve(
                approvals.state, requestCount: approvals.items.count,
                forced: model.forced(.native(.approvals)), offline: model.connection == .offline)
            switch state {
            case .loading: LoadingPane("Loading Requests\u{2026}")
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { approvals.refresh() }
            case .empty:
                EmptyPane(ApprovalsListState.emptyTitle, systemImage: NativeAppID.approvals.symbol,
                          message: ApprovalsListState.emptyMessage)
            case .requests:
                // R12: a refresh runs behind the requests on screen.
                list(model)
                    .refreshStatus(approvals.state == .loading, failure: ApprovalsListState.failure(approvals.state),
                                   label: "Updating Requests", retry: { approvals.refresh() })
            }
        }
    }

    private func list(_ m: WindowModel) -> some View {
        let selection = Binding<String?>(
            get: { ApprovalsSection.itemID(m) },
            set: { ApprovalsSection.selectItem($0, m) })
        return List(approvals.items, selection: selection) { item in
            let badge = ApprovalsFormat.stateLabel(item.state)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).lineLimit(1)
                    Text(ApprovalsSection.subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: badge.symbol).foregroundStyle(.secondary)
            }
            .tag(item.id)
        }
        .listStyle(.inset)
    }
}

// MARK: detail

/// The selected request (§6.7): title, state, description, flow status
/// (one row per approver), approve/reject with an optional comment,
// cancel when the service allows it.
struct ApprovalsDetailPane: View {
    @ObservedObject var approvals: ApprovalStore
    @Environment(\.windowModel) private var model
    @State private var comment = ""

    var body: some View {
        if let model {
            let itemID = model.forced(.native(.approvals)) == nil ? ApprovalsSection.itemID(model) : nil
            let showing = itemID != nil && approvals.selected?.id == itemID
            let state = ApprovalsDetailState.resolve(
                itemSelected: itemID != nil, showing: showing,
                loading: approvals.state == .loading && approvals.selected == nil,
                error: approvals.actionError, offline: model.connection == .offline)
            switch state {
            case .noSelection: NoSelectionPane(ApprovalsDetailState.noSelectionTitle)
            case .loading: LoadingPane("Loading Request\u{2026}")
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { approvals.refresh() }
            case .detail:
                if let item = approvals.selected {
                    detail(item)
                } else {
                    NoSelectionPane(ApprovalsDetailState.noSelectionTitle)
                }
            }
        }
    }

    private func detail(_ item: ApprovalItem) -> some View {
        let status = approvals.flowStatus(for: item.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(item)
                if let description = item.itemDescription, !description.isEmpty {
                    Text(description)
                        .font(.body)
                }
                flowStatus(item, status: status)
                if !item.isDecided {
                    decision(item)
                }
                if let error = approvals.actionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ item: ApprovalItem) -> some View {
        let badge = ApprovalsFormat.stateLabel(item.state)
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.displayName)
                .font(.title2)
                .fontWeight(.semibold)
            HStack(spacing: 6) {
                Label(badge.text, systemImage: badge.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let result = item.result, item.state == .completed {
                    Text("· \(result)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let owner = item.owner?.displayName {
                Text("Requested by \(owner)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func flowStatus(_ item: ApprovalItem, status: ApprovalFlowStatus?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flow status")
                .font(.headline)
            Text(status?.headline ?? "Loading status\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(status?.rows ?? [], id: \.person.displayName) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.response == nil ? "clock"
                        : (row.isPositive ? "checkmark.circle" : "xmark.circle"))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.person.displayName)
                            .font(.callout)
                        if let response = row.response {
                            Text(response + (row.comments.map { " — \($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if item.canCancel {
                Button("Cancel Request") { approvals.cancel(id: item.id) }
                    .disabled(approvals.acting)
            }
        }
    }

    private func decision(_ item: ApprovalItem) -> some View {
        let prompts = item.responsePrompts
        let approveTitle = prompts.first ?? "Approve"
        let rejectTitle = prompts.dropFirst().first ?? "Reject"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your decision")
                .font(.headline)
            TextField("Add a comment (optional)", text: $comment)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button(approveTitle) {
                    approvals.respond(id: item.id, response: approveTitle, comments: comment)
                    comment = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(approvals.acting)
                Button(rejectTitle) {
                    approvals.respond(id: item.id, response: rejectTitle, comments: comment)
                    comment = ""
                }
                .disabled(approvals.acting)
            }
        }
    }
}
