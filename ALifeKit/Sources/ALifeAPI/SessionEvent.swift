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
    /// The character used a tool. Tools that ask first are followed by an
    /// `approvalRequested` for the same call.
    case toolUsed(ToolUse)
    case approvalRequested(Approval)
    /// The approval was answered or is no longer needed. `outcome` says
    /// which; servers from before it did leave it out.
    case approvalResolved(approvalID: String, outcome: ApprovalOutcome? = nil)
    /// The character sent a helper off to do part of its work.
    case subagentStarted(Subagent)
    /// The helper reported back to the character, or was stopped.
    case subagentFinished(subagentID: String)
    /// Auto approve was turned on or off in the session. While it is on,
    /// every tool call that asks is allowed straight away, and settled as
    /// `autoApproved`.
    case autoApproveChanged(Bool)
    /// An event type this version doesn't know. It is skipped.
    case unknown(type: String)

    /// The name the event travels under.
    public var type: String {
        switch self {
        case .conversationStarted: return "conversation.started"
        case .statusChanged: return "session.status"
        case .activityChanged: return "session.activity"
        case .message: return "message"
        case .toolUsed: return "tool.used"
        case .approvalRequested: return "approval.requested"
        case .approvalResolved: return "approval.resolved"
        case .subagentStarted: return "subagent.started"
        case .subagentFinished: return "subagent.finished"
        case .autoApproveChanged: return "session.auto_approve"
        case .unknown(let type): return type
        }
    }
}

extension SessionEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, status, activity, message, approval, subagent, outcome
        case toolUse = "tool_use"
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case approvalID = "approval_id"
        case subagentID = "subagent_id"
        case autoApprove = "auto_approve"
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
        case "tool.used":
            self = .toolUsed(try container.decode(ToolUse.self, forKey: .toolUse))
        case "approval.requested":
            self = .approvalRequested(try container.decode(Approval.self, forKey: .approval))
        case "approval.resolved":
            self = .approvalResolved(
                approvalID: try container.decode(String.self, forKey: .approvalID),
                outcome: try container.decodeIfPresent(ApprovalOutcome.self, forKey: .outcome)
            )
        case "subagent.started":
            self = .subagentStarted(try container.decode(Subagent.self, forKey: .subagent))
        case "subagent.finished":
            self = .subagentFinished(subagentID: try container.decode(String.self, forKey: .subagentID))
        case "session.auto_approve":
            self = .autoApproveChanged(try container.decode(Bool.self, forKey: .autoApprove))
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
        case .toolUsed(let toolUse):
            try container.encode(toolUse, forKey: .toolUse)
        case .approvalRequested(let approval):
            try container.encode(approval, forKey: .approval)
        case .approvalResolved(let approvalID, let outcome):
            try container.encode(approvalID, forKey: .approvalID)
            try container.encodeIfPresent(outcome, forKey: .outcome)
        case .subagentStarted(let subagent):
            try container.encode(subagent, forKey: .subagent)
        case .subagentFinished(let subagentID):
            try container.encode(subagentID, forKey: .subagentID)
        case .autoApproveChanged(let autoApprove):
            try container.encode(autoApprove, forKey: .autoApprove)
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
    /// The character's colour, as `#RRGGBB`: the shirt it wears on the lot,
    /// which its helpers wear too. `nil` leaves it to the front end.
    public var color: String?
    /// The conversation going on in the session. Starting the session over
    /// begins a new one.
    public var conversationID: String?
    public var status: RunStatus = .unknown
    public var stopReason: StopReason?
    /// What the character is doing right now, such as the name of a tool.
    public var activity: String?
    /// What was said in the conversation, by you and the character.
    public var messages: [Message] = []
    /// The tool calls waiting for a yes or no right now. One that has been
    /// settled is no longer listed here, but stays in `conversation`.
    public var approvals: [Approval] = []
    /// The whole conversation in the order it happened: the messages, the
    /// tools the character used, and every tool call that asked for a yes or
    /// no, with how it was settled.
    public var conversation: [ConversationEntry] = []
    /// The helpers out working for the character right now. One that has
    /// reported back is no longer listed.
    public var subagents: [Subagent] = []
    /// Whether tool calls that ask are allowed without asking you. Each
    /// session has its own; it is off until someone turns it on.
    public var autoApprove = false
    /// Sequence number of the last event applied.
    public var lastSeq = 0

    public init(id: String, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }

    public mutating func apply(_ envelope: EventEnvelope) {
        switch envelope.event {
        case .conversationStarted(let conversationID):
            // Auto approve goes too. A server that keeps it on across the
            // new conversation says so again straight after.
            self = SessionState(id: id, name: name, color: color)
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
                conversation.append(.message(message))
            }
        case .toolUsed(let toolUse):
            let entry = ConversationEntry.toolUse(toolUse)
            if !conversation.contains(where: { $0.id == entry.id }) {
                conversation.append(entry)
            }
        case .approvalRequested(let approval):
            let entry = ConversationEntry.approval(approval, outcome: nil)
            guard !conversation.contains(where: { $0.id == entry.id }) else { break }
            approvals.append(approval)
            // It asks about a tool use that's shown already, so it takes
            // that one's place rather than saying the same thing twice.
            let asksAbout = conversation.firstIndex { entry in
                guard case .toolUse(let toolUse) = entry else { return false }
                return toolUse.id == approval.toolUseID
            }
            if let index = asksAbout {
                conversation[index] = entry
            } else {
                conversation.append(entry)
            }
        case .approvalResolved(let approvalID, let outcome):
            approvals.removeAll { $0.id == approvalID }
            let settled = conversation.firstIndex { entry in
                guard case .approval(let approval, nil) = entry else { return false }
                return approval.id == approvalID
            }
            if let index = settled, case .approval(let approval, _) = conversation[index] {
                conversation[index] = .approval(approval, outcome: outcome ?? .unknown)
            }
        case .subagentStarted(let subagent):
            if !subagents.contains(where: { $0.id == subagent.id }) {
                subagents.append(subagent)
            }
        case .subagentFinished(let subagentID):
            subagents.removeAll { $0.id == subagentID }
        case .autoApproveChanged(let autoApprove):
            self.autoApprove = autoApprove
        case .unknown:
            break
        }
        lastSeq = envelope.seq
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, status, activity, messages, approvals, conversation, subagents
        case autoApprove = "auto_approve"
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case lastSeq = "last_seq"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Servers from before characters had colours don't send one.
        color = try container.decodeIfPresent(String.self, forKey: .color)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        status = try container.decode(RunStatus.self, forKey: .status)
        stopReason = try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        messages = try container.decode([Message].self, forKey: .messages)
        approvals = try container.decode([Approval].self, forKey: .approvals)
        // Servers from before the whole conversation was kept send only the
        // messages and the approvals waiting.
        if container.contains(.conversation) {
            var entries = try container.nestedUnkeyedContainer(forKey: .conversation)
            while !entries.isAtEnd {
                if let entry = try? entries.decode(ConversationEntry.self) {
                    conversation.append(entry)
                } else {
                    _ = try entries.decode(Skipped.self) // one this version doesn't know
                }
            }
        } else {
            conversation = messages.map { .message($0) } + approvals.map { .approval($0, outcome: nil) }
        }
        // Servers from before there were helpers don't send any.
        subagents = try container.decodeIfPresent([Subagent].self, forKey: .subagents) ?? []
        // Nor from before there was auto approve.
        autoApprove = try container.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
        lastSeq = try container.decode(Int.self, forKey: .lastSeq)
    }
}

/// Anything at all, decoded only to move past it.
private struct Skipped: Decodable {
    init(from decoder: Decoder) throws {}
}
