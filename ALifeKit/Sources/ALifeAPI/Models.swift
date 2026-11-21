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
    /// The id of the tool call it asks about. If that call is in the
    /// conversation as a `ToolUse`, the approval takes its place, so the two
    /// are shown as one. `nil` from servers from before tool uses were shown.
    public let toolUseID: String?

    public init(id: String = UUID().uuidString, toolName: String, input: String, toolUseID: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.input = input
        self.toolUseID = toolUseID
    }

    enum CodingKeys: String, CodingKey {
        case id, input
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
    }
}

/// How a tool call that waited for a yes or no was settled.
public enum ApprovalOutcome: String, Codable, Sendable {
    /// You said yes.
    case allowed
    /// You said no.
    case denied
    /// Said yes for you, because auto approve was on in the session.
    case autoApproved = "auto_approved"
    /// Nobody answered: the character was stopped or started over, or no
    /// longer needed it.
    case withdrawn
    /// Settled, but the server didn't say how (servers from before it did),
    /// or said something this version doesn't know.
    case unknown

    public init(from decoder: Decoder) throws {
        self = ApprovalOutcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A tool the character used, such as reading a file or running a command,
/// so you can follow along with what it does between its messages.
public struct ToolUse: Codable, Identifiable, Equatable, Sendable {
    /// The tool call's id, which an `Approval` for it carries as its
    /// `toolUseID`.
    public let id: String
    public let toolName: String
    /// What the call does, as short text to show, such as a command or a
    /// file's path.
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

/// One thing in a session's conversation, in the order it happened: a
/// message, a tool the character used, or a tool call that asked for a yes
/// or no, with how it was settled once it was.
public enum ConversationEntry: Equatable, Identifiable, Sendable {
    case message(Message)
    case toolUse(ToolUse)
    /// `outcome` is `nil` while the approval is waiting for an answer.
    case approval(Approval, outcome: ApprovalOutcome?)

    public var id: String {
        switch self {
        case .message(let message): return "message-" + message.id
        case .toolUse(let toolUse): return "tool-" + toolUse.id
        case .approval(let approval, _): return "approval-" + approval.id
        }
    }
}

extension ConversationEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case type, message, approval, outcome
        case toolUse = "tool_use"
    }

    /// Thrown for an entry this version doesn't know, which is skipped.
    struct UnknownEntry: Error {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "message":
            self = .message(try container.decode(Message.self, forKey: .message))
        case "tool_use":
            self = .toolUse(try container.decode(ToolUse.self, forKey: .toolUse))
        case "approval":
            self = .approval(
                try container.decode(Approval.self, forKey: .approval),
                outcome: try container.decodeIfPresent(ApprovalOutcome.self, forKey: .outcome)
            )
        default:
            throw UnknownEntry()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let message):
            try container.encode("message", forKey: .type)
            try container.encode(message, forKey: .message)
        case .toolUse(let toolUse):
            try container.encode("tool_use", forKey: .type)
            try container.encode(toolUse, forKey: .toolUse)
        case .approval(let approval, let outcome):
            try container.encode("approval", forKey: .type)
            try container.encode(approval, forKey: .approval)
            try container.encodeIfPresent(outcome, forKey: .outcome)
        }
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

/// `PUT /v1/sessions/{id}/auto-approve`
public struct AutoApproveRequest: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }
}
