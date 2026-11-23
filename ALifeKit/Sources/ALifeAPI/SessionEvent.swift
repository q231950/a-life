import Foundation

/// Something that happened in a session. The server keeps a session's events
/// in order and sends them to every client following it; applying them in
/// order to a `SessionState` reproduces what the server knows.
public enum SessionEvent: Equatable, Sendable {
    /// A new conversation began in the session. Everything known about the
    /// previous one is void.
    case conversationStarted(conversationID: String)
    /// Whether the character is working, and why it last stopped.
    /// `resumesAt` is when a character that stopped on the usage limit
    /// carries on by itself; `nil` otherwise.
    case statusChanged(RunStatus, stopReason: StopReason?, resumesAt: Date? = nil)
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
    /// How full the character's Claude Code session is, or the model playing
    /// it, changed.
    case contextChanged(SessionContext)
    /// The model the character runs on, and the one the agents file gives
    /// it, said at the start of each conversation and whenever it is
    /// changed, such as in a front end's model picker. `nil` is Claude
    /// Code's own default.
    case modelChanged(ClaudeModel?, fileModel: ClaudeModel?)
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
        case .contextChanged: return "session.context"
        case .modelChanged: return "session.model"
        case .unknown(let type): return type
        }
    }
}

extension SessionEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, status, activity, message, approval, subagent, outcome, context, model
        case toolUse = "tool_use"
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case approvalID = "approval_id"
        case subagentID = "subagent_id"
        case autoApprove = "auto_approve"
        case resumesAt = "resumes_at"
        case fileModel = "file_model"
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
                stopReason: try container.decodeIfPresent(StopReason.self, forKey: .stopReason),
                // In seconds since 1970, whatever the decoder's own date strategy.
                resumesAt: try container.decodeIfPresent(Double.self, forKey: .resumesAt).map(Date.init(timeIntervalSince1970:))
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
        case "session.context":
            self = .contextChanged(try container.decode(SessionContext.self, forKey: .context))
        case "session.model":
            // A model this version doesn't know is as good as none.
            self = .modelChanged(
                (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? nil,
                fileModel: (try? container.decodeIfPresent(ClaudeModel.self, forKey: .fileModel)) ?? nil
            )
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
        case .statusChanged(let status, let stopReason, let resumesAt):
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
            try container.encodeIfPresent(resumesAt?.timeIntervalSince1970, forKey: .resumesAt)
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
        case .contextChanged(let context):
            try container.encode(context, forKey: .context)
        case .modelChanged(let model, let fileModel):
            try container.encode(model, forKey: .model)
            try container.encode(fileModel, forKey: .fileModel)
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
    /// When it happened, by the server's clock, so a front end that catches
    /// up later can tell when. `nil` from servers from before they said.
    public let time: Date?

    public init(seq: Int, event: SessionEvent, time: Date? = nil) {
        self.seq = seq
        self.event = event
        self.time = time
    }

    enum CodingKeys: String, CodingKey {
        case seq, event, time
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        event = try container.decode(SessionEvent.self, forKey: .event)
        // In seconds since 1970, whatever the decoder's own date strategy.
        time = try container.decodeIfPresent(Double.self, forKey: .time).map(Date.init(timeIntervalSince1970:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(time?.timeIntervalSince1970, forKey: .time)
    }
}

/// One character's session: who the character is, what it is doing, the
/// conversation with it, and any tool calls waiting for a yes or no.
///
/// Built by applying the session's events in order; the server and the
/// clients use the same code to do it.
public struct SessionState: Codable, Equatable, Identifiable, Sendable {
    /// The session's id, which is also its character's, such as `builder`.
    /// It never changes; it is what the session's URLs use.
    public let id: String
    /// The character's name, such as `Builder`.
    public var name: String
    /// The character's colour, as `#RRGGBB`: the shirt it wears on the lot,
    /// which its helpers wear too. `nil` leaves it to the front end.
    public var color: String?
    /// The conversation going on in the session. Starting the session over
    /// begins a new one.
    public var conversationID: String?
    public var status: RunStatus = .unknown
    public var stopReason: StopReason?
    /// When a character that stopped on the usage limit carries on by
    /// itself, a minute or so after the limit resets. `nil` otherwise.
    public var resumesAt: Date?
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
    /// How full the character's Claude Code session is, and the model
    /// playing it. `nil` until the session has started and said, and from
    /// servers from before it did.
    public var context: SessionContext?
    /// The model the character runs on: the agents file's, unless it was
    /// changed in a front end. `nil` is Claude Code's own default, and from
    /// servers from before characters had models.
    public var model: ClaudeModel?
    /// The model the agents file gives the character, which the model
    /// picker can go back to. `nil` if it gives none.
    public var fileModel: ClaudeModel?
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
            // new conversation says so again straight after. The model is
            // the character's, not the conversation's, so it stays.
            let (model, fileModel) = (model, fileModel)
            self = SessionState(id: id, name: name, color: color)
            self.conversationID = conversationID
            self.model = model
            self.fileModel = fileModel
            status = .idle
        case .statusChanged(let status, let stopReason, let resumesAt):
            self.status = status
            self.stopReason = stopReason
            self.resumesAt = resumesAt
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
        case .contextChanged(let context):
            self.context = context
        case .modelChanged(let model, let fileModel):
            self.model = model
            self.fileModel = fileModel
        case .unknown:
            break
        }
        lastSeq = envelope.seq
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, status, activity, messages, approvals, conversation, subagents, context, model
        case fileModel = "file_model"
        case autoApprove = "auto_approve"
        case conversationID = "conversation_id"
        case stopReason = "stop_reason"
        case resumesAt = "resumes_at"
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
        resumesAt = try container.decodeIfPresent(Double.self, forKey: .resumesAt).map(Date.init(timeIntervalSince1970:))
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
        // Nor from before they said how full the session is.
        context = (try? container.decodeIfPresent(SessionContext.self, forKey: .context)) ?? nil
        // Nor from before characters had models; and a model this version
        // doesn't know is as good as none.
        model = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? nil
        fileModel = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .fileModel)) ?? nil
        lastSeq = try container.decode(Int.self, forKey: .lastSeq)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(stopReason, forKey: .stopReason)
        // In seconds since 1970, as events say when they happened.
        try container.encodeIfPresent(resumesAt?.timeIntervalSince1970, forKey: .resumesAt)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encode(messages, forKey: .messages)
        try container.encode(approvals, forKey: .approvals)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(subagents, forKey: .subagents)
        try container.encode(autoApprove, forKey: .autoApprove)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(fileModel, forKey: .fileModel)
        try container.encode(lastSeq, forKey: .lastSeq)
    }
}

/// Anything at all, decoded only to move past it.
private struct Skipped: Decodable {
    init(from decoder: Decoder) throws {}
}
