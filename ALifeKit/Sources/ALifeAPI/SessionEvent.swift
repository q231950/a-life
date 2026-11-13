import Foundation

/// Something that happened in a session. The server keeps a session's events
/// in order and sends them to every client following it; applying them in
/// order to a `SessionState` reproduces what the server knows.
public enum SessionEvent: Equatable, Sendable {
    /// A new conversation began in the session. Everything known about the
    /// previous one is void.
    case conversationStarted(conversationID: String)
    case statusChanged(RunStatus, stopReason: StopReason?)
    /// What the character is doing changed, such as the tool it is using.
    /// `nil` when it isn't doing anything in particular.
    case activityChanged(String?)
    case message(Message)
    case approvalRequested(Approval)
    /// The approval was answered or is no longer needed.
    case approvalResolved(approvalID: String)
    /// An event type this version doesn't know. It is skipped.
    case unknown(type: String)

    /// The name the event travels under.
    public var type: String {
        switch self {
        case .conversationStarted: return "conversation.started"
        case .statusChanged: return "session.status"
        case .activityChanged: return "session.activity"
        case .message: return "message"
        case .approvalRequested: return "approval.requested"
        case .approvalResolved: return "approval.resolved"
        case .unknown(let type): return type
        }
    }
}

extension SessionEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, status, activity, message, approval
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case approvalID = "approval_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "conversation.started":
            self = .conversationStarted(conversationID: try container.decode(String.self, forKey: .conversationID))
        case "session.status":
            self = .statusChanged(
                try container.decode(RunStatus.self, forKey: .status),
                stopReason: try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
            )
        case "session.activity":
            self = .activityChanged(try container.decodeIfPresent(String.self, forKey: .activity))
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
        case .conversationStarted(let conversationID):
            try container.encode(conversationID, forKey: .conversationID)
        case .statusChanged(let status, let stopReason):
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
        case .activityChanged(let activity):
            try container.encodeIfPresent(activity, forKey: .activity)
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

/// An event with its place in its session's log. Sequence numbers only go
/// up, so a client that remembers the last one it saw can ask for what it
/// missed.
public struct EventEnvelope: Codable, Equatable, Sendable {
    public let seq: Int
    public let event: SessionEvent

    public init(seq: Int, event: SessionEvent) {
        self.seq = seq
        self.event = event
    }
}

/// One character's session: who the character is, what it is doing, the
/// conversation with it, and any tool calls waiting for a yes or no.
///
/// Built by applying the session's events in order; the server and the
/// clients use the same code to do it.
public struct SessionState: Codable, Equatable, Identifiable, Sendable {
    /// The session's id, which is also its character's, such as `gardener`.
    /// It never changes; it is what the session's URLs use.
    public let id: String
    /// The character's name, such as `Gardener`.
    public var name: String
    /// The conversation going on in the session. Starting the session over
    /// begins a new one.
    public var conversationID: String?
    public var status: RunStatus = .unknown
    public var stopReason: StopReason?
    /// What the character is doing right now, such as the name of a tool.
    public var activity: String?
    public var messages: [Message] = []
    public var approvals: [Approval] = []
    /// Sequence number of the last event applied.
    public var lastSeq = 0

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public mutating func apply(_ envelope: EventEnvelope) {
        switch envelope.event {
        case .conversationStarted(let conversationID):
            self = SessionState(id: id, name: name)
            self.conversationID = conversationID
            status = .idle
        case .statusChanged(let status, let stopReason):
            self.status = status
            self.stopReason = stopReason
        case .activityChanged(let activity):
            self.activity = activity
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
        case id, name, status, activity, messages, approvals
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case lastSeq = "last_seq"
    }
}
