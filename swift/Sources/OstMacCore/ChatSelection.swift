// ChatSelection.swift — sidebar selection contract (consumed by conversation lane).
import Foundation

/// Source of truth for the chat selected in the sidebar.
///
/// The app owns one store (normally ``ChatListViewModel``) and hands it to
/// both the sidebar and the conversation pane:
/// - sidebar writes `selectedChatID` (via `List(selection:)` binding)
/// - conversation lane reads `selectedChatID` / `selectedChat`, or observes
///   the view model's `$selectedChatID` publisher, and loads messages for it
///
/// `selectedChatID` is `nil` when nothing is selected (empty list, selection
/// cleared by reload, user deselected). IDs are stable Teams conversation IDs.
///
/// UI state: isolated to the main actor. Background consumers must hop with
/// `await MainActor.run`.
@MainActor
public protocol ChatSelection: AnyObject {
    /// Selected chat ID, or `nil` for no selection.
    var selectedChatID: String? { get set }
    /// Full item for the selection, or `nil` when unselected/unknown.
    var selectedChat: ChatItem? { get }
}
