import Foundation

/// Whether a session's character is working.
public enum RunStatus: String, Codable, Sendable {
    case idle, running, terminated
    /// A value this version doesn't know.
    case unknown

    public init(from decoder: Decoder) throws {
        self = RunStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Why a session last stopped working.
public enum StopReason: String, Codable, Sendable {
    /// The character finished what it was asked to do.
    case endTurn = "end_turn"
    /// A tool call is waiting for a yes or no.
    case requiresAction = "requires_action"
    /// Someone stopped the character.
    case interrupted
    case unknown

    public init(from decoder: Decoder) throws {
        self = StopReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One line of the conversation in a session.
public struct Message: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Something someone said to the character.
        case user
        /// The character's reply.
        case agent
        case error
    }

    public let id: String
    public let kind: Kind
    public let speaker: String
    public let text: String

    public init(id: String = UUID().uuidString, kind: Kind, speaker: String, text: String) {
        self.id = id
        self.kind = kind
        self.speaker = speaker
        self.text = text
    }
}

/// A tool call that is waiting for a yes or no.
public struct Approval: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    /// The call's input, as text to show.
    public let input: String

    public init(id: String = UUID().uuidString, toolName: String, input: String) {
        self.id = id
        self.toolName = toolName
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case id, input
        case toolName = "tool_name"
    }
}

/// A helper a character sent off to do part of its work, like a subagent of
/// a Claude Code session. It works on its own until it reports back to the
/// character that sent it.
public struct Subagent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    /// What it was sent to do.
    public let task: String

    public init(id: String = UUID().uuidString, task: String) {
        self.id = id
        self.task = task
    }
}

// MARK: Request bodies

/// `POST /v1/sessions/{id}/messages`
public struct SendMessageRequest: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) { self.text = text }
}

/// `POST /v1/sessions/{id}/approvals/{approval id}`
public struct ApprovalDecision: Codable, Equatable, Sendable {
    public var allow: Bool

    public init(allow: Bool) { self.allow = allow }
}
