import Foundation

/// Something that happened in the session. The server keeps these in order
/// and sends them to every client; applying them in order to a
/// `SessionState` reproduces what the server knows.
public enum SessionEvent: Equatable, Sendable {
    /// A new session began. Everything known about the previous one is void.
    case sessionStarted(sessionID: String)
    case statusChanged(RunStatus, stopReason: StopReason?)
    /// An agent joined the team or changed.
    case agentUpdated(Agent)
    case agentRemoved(agentID: String)
    case message(Message)
    case approvalRequested(Approval)
    /// The approval was answered or is no longer needed.
    case approvalResolved(approvalID: String)
    /// An event type this version doesn't know. It is skipped.
    case unknown(type: String)

    /// The name the event travels under.
    public var type: String {
        switch self {
        case .sessionStarted: return "session.started"
        case .statusChanged: return "session.status"
        case .agentUpdated: return "agent.updated"
        case .agentRemoved: return "agent.removed"
        case .message: return "message"
        case .approvalRequested: return "approval.requested"
        case .approvalResolved: return "approval.resolved"
        case .unknown(let type): return type
        }
    }
}

extension SessionEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, status, agent, message, approval
        case sessionID = "session_id"
        case stopReason = "stop_reason"
        case agentID = "agent_id"
        case approvalID = "approval_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session.started":
            self = .sessionStarted(sessionID: try container.decode(String.self, forKey: .sessionID))
        case "session.status":
            self = .statusChanged(
                try container.decode(RunStatus.self, forKey: .status),
                stopReason: try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
            )
        case "agent.updated":
            self = .agentUpdated(try container.decode(Agent.self, forKey: .agent))
        case "agent.removed":
            self = .agentRemoved(agentID: try container.decode(String.self, forKey: .agentID))
        case "message":
            self = .message(try container.decode(Message.self, forKey: .message))
        case "approval.requested":
            self = .approvalRequested(try container.decode(Approval.self, forKey: .approval))
        case "approval.resolved":
            self = .approvalResolved(approvalID: try container.decode(String.self, forKey: .approvalID))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .sessionStarted(let sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case .statusChanged(let status, let stopReason):
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
        case .agentUpdated(let agent):
            try container.encode(agent, forKey: .agent)
        case .agentRemoved(let agentID):
            try container.encode(agentID, forKey: .agentID)
        case .message(let message):
            try container.encode(message, forKey: .message)
        case .approvalRequested(let approval):
            try container.encode(approval, forKey: .approval)
        case .approvalResolved(let approvalID):
            try container.encode(approvalID, forKey: .approvalID)
        case .unknown:
            break
        }
    }
}

/// An event with its place in the server's log. Sequence numbers only go up,
/// so a client that remembers the last one it saw can ask for what it missed.
public struct EventEnvelope: Codable, Equatable, Sendable {
    public let seq: Int
    public let event: SessionEvent

    public init(seq: Int, event: SessionEvent) {
        self.seq = seq
        self.event = event
    }
}

/// Everything a front end shows about the session. Built by applying events
/// in order; the server and the clients use the same code to do it.
public struct SessionState: Codable, Equatable, Sendable {
    public var sessionID: String?
    /// Running while any agent is.
    public var status: RunStatus = .unknown
    public var stopReason: StopReason?
    public var agents: [Agent] = []
    public var messages: [Message] = []
    public var approvals: [Approval] = []
    /// Sequence number of the last event applied.
    public var lastSeq = 0

    public init() {}

    public mutating func apply(_ envelope: EventEnvelope) {
        switch envelope.event {
        case .sessionStarted(let sessionID):
            self = SessionState()
            self.sessionID = sessionID
            status = .idle
        case .statusChanged(let status, let stopReason):
            self.status = status
            self.stopReason = stopReason
        case .agentUpdated(let agent):
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = agent
            } else {
                agents.append(agent)
            }
        case .agentRemoved(let agentID):
            agents.removeAll { $0.id == agentID }
        case .message(let message):
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        case .approvalRequested(let approval):
            if !approvals.contains(where: { $0.id == approval.id }) {
                approvals.append(approval)
            }
        case .approvalResolved(let approvalID):
            approvals.removeAll { $0.id == approvalID }
        case .unknown:
            break
        }
        lastSeq = envelope.seq
    }

    enum CodingKeys: String, CodingKey {
        case status, agents, messages, approvals
        case sessionID = "session_id"
        case stopReason = "stop_reason"
        case lastSeq = "last_seq"
    }
}
