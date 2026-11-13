import Foundation

/// Whether an agent, or the session as a whole, is working.
public enum RunStatus: String, Codable, Sendable {
    case idle, running, terminated
    /// A value this version doesn't know.
    case unknown

    public init(from decoder: Decoder) throws {
        self = RunStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Why the session last stopped working.
public enum StopReason: String, Codable, Sendable {
    /// The team finished what it was asked to do.
    case endTurn = "end_turn"
    /// A tool call is waiting for a yes or no.
    case requiresAction = "requires_action"
    /// Someone stopped the team.
    case interrupted
    case unknown

    public init(from decoder: Decoder) throws {
        self = StopReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One member of the team.
public struct Agent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var status: RunStatus
    /// The coordinator. Instructions go to this agent.
    public var isCoordinator: Bool
    /// What the agent is doing right now, such as the name of a tool.
    public var activity: String?

    public init(id: String, name: String, status: RunStatus = .idle, isCoordinator: Bool = false, activity: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.isCoordinator = isCoordinator
        self.activity = activity
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, activity
        case isCoordinator = "is_coordinator"
    }
}

/// One line of the conversation with the team.
public struct Message: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// An instruction someone sent.
        case user
        /// The coordinator's reply.
        case agent
        /// A task handed to a teammate, or a teammate's report back.
        case handoff
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
    public let agentID: String
    public let agentName: String
    public let toolName: String
    /// The call's input, as text to show.
    public let input: String

    public init(id: String = UUID().uuidString, agentID: String, agentName: String, toolName: String, input: String) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.toolName = toolName
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case id, input
        case agentID = "agent_id"
        case agentName = "agent_name"
        case toolName = "tool_name"
    }
}

// MARK: Request bodies

/// `POST /v1/session/messages`
public struct SendMessageRequest: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) { self.text = text }
}

/// `POST /v1/session/interrupt`
public struct InterruptRequest: Codable, Equatable, Sendable {
    /// The agent to stop. `nil` stops the whole team.
    public var agentID: String?

    public init(agentID: String? = nil) { self.agentID = agentID }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
    }
}

/// `POST /v1/session/approvals/{id}`
public struct ApprovalDecision: Codable, Equatable, Sendable {
    public var allow: Bool

    public init(allow: Bool) { self.allow = allow }
}
