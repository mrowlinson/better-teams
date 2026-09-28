// CreateChatCall.swift — core-c: create-chat-then-call. New Call can pick
// people who have no chat thread yet: resolve (or create) the 1:1 / group
// chat for them, then dial it (`AppState.startCall(with:)`). The resolver
// is pure over injected creators so tests need no FFI or network.
import Foundation

/// The chat a call is placed on, plus its display name for the call UI.
public struct CallTarget: Equatable, Sendable {
    public let threadID: String
    public let name: String

    public init(threadID: String, name: String) {
        self.threadID = threadID
        self.name = name
    }
}

public enum CallTargetResolver {
    /// Sync creators (run off-main). 1:1 = Graph `POST /chats` oneOnOne,
    /// which returns the existing chat when there is one; group = Graph
    /// `POST /chats` group (Graph has no find-existing-group lookup, so a
    /// group call always starts a new group chat, as Teams does for an
    /// untitled multi-person call from New Call).
    public typealias OneToOneCreator = @Sendable (String) throws -> ChatCreateResponse
    public typealias GroupCreator = @Sendable ([String]) throws -> ChatCreateResponse

    public enum Failure: Error, Equatable {
        /// None of the people has a usable user ref (AAD id / email).
        case noOne
        /// The chat create failed; the core detail.
        case create(String)
    }

    /// Resolve the call target for `people`: one ref → the 1:1, two or
    /// more → a group chat. Demo resolves the in-memory ids the chat
    /// paths use (`PersonChat` / `GroupChat.demoChatID`), no creators.
    public static func resolve(
        people: [TeamMember], demo: Bool,
        oneToOne: @escaping OneToOneCreator = { try RustCore.chatCreateOneToOne(user: $0) },
        group: @escaping GroupCreator = { try RustCore.chatCreateGroup(users: $0, topic: nil) }
    ) async throws -> CallTarget {
        let refs = GroupChat.userRefs(for: people)
        guard !refs.isEmpty else { throw Failure.noOne }
        let named = people.filter { PersonChat.userRef(for: $0) != nil }
        if refs.count == 1, let person = named.first {
            let name = person.displayName
            if demo { return CallTarget(threadID: PersonChat.demoChatID(for: person), name: name) }
            let ref = refs[0]
            do {
                let created = try await Task.detached { try oneToOne(ref) }.value
                return CallTarget(threadID: created.chat.chatId, name: name)
            } catch {
                throw Failure.create(String(describing: error))
            }
        }
        let name = GroupChat.defaultName(for: named)
        if demo { return CallTarget(threadID: GroupChat.demoChatID(refs: refs, topic: nil), name: name) }
        do {
            let created = try await Task.detached { try group(refs) }.value
            let chatName = created.chat.name.isEmpty ? name : created.chat.name
            return CallTarget(threadID: created.chat.chatId, name: chatName)
        } catch {
            throw Failure.create(String(describing: error))
        }
    }
}
