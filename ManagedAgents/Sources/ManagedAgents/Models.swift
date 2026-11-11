import Foundation

/// Status of a session or of one thread inside it.
public enum RunStatus: String, Sendable {
    case idle, running, rescheduling, terminated
    /// Not known yet, or a value this package doesn't recognise.
    case unknown

    init(_ json: JSONValue?) {
        self = json?.stringValue.flatMap(RunStatus.init(rawValue:)) ?? .unknown
    }
}

/// A running agent instance. It lives on Anthropic's side; the app only keeps its ID.
public struct Session: Equatable, Sendable {
    public let id: String
    public let status: RunStatus
    public let title: String?
    public let isArchived: Bool

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        status = RunStatus(json["status"])
        title = json["title"]?.stringValue
        isArchived = json["archived_at"]?.stringValue != nil
    }
}

/// One agent's thread inside a multiagent session. The coordinator's thread is
/// the primary one (`parentThreadID == nil`).
public struct SessionThread: Equatable, Sendable {
    public let id: String
    public let agentName: String
    public let status: RunStatus
    public let parentThreadID: String?
    public let isArchived: Bool
    /// Set when a workflow run created the thread.
    public let workflowRunID: String?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        let agent = json["agent"]
        // Advisor threads have no name, only `{type: "advisor", model}`.
        agentName = agent?["name"]?.stringValue ?? (agent?["type"]?.stringValue == "advisor" ? "Advisor" : "Agent")
        status = RunStatus(json["status"])
        parentThreadID = json["parent_thread_id"]?.stringValue
        isArchived = json["archived_at"]?.stringValue != nil
        workflowRunID = json["workflow_run_id"]?.stringValue
    }
}

/// One event from a session's history or live stream.
public struct SessionEvent: Equatable, Sendable {
    /// Empty for the few events the API sends without one (some interrupts).
    public let id: String
    /// Dot-notation type such as `agent.message` or `session.status_idle`.
    public let type: String
    /// `nil` while an event you sent is still queued.
    public let processedAt: String?
    /// The whole event object.
    public let payload: JSONValue

    public init(payload: JSONValue, fallbackType: String? = nil) {
        self.payload = payload
        id = payload["id"]?.stringValue ?? ""
        type = payload["type"]?.stringValue ?? fallbackType ?? ""
        processedAt = payload["processed_at"]?.stringValue
    }

    public subscript(key: String) -> JSONValue? { payload[key] }

    /// Text of the event's `content`, if it has any.
    public var text: String? { payload["content"]?.joinedText }

    /// The thread the event is about, for thread events and cross-posted tool calls.
    public var threadID: String? { payload["session_thread_id"]?.stringValue }

    /// `end_turn`, `requires_action`, `budget_reached`, ... on idle events.
    public var stopReason: String? { payload["stop_reason"]?["type"]?.stringValue }
}

/// An event the client sends to a session.
public enum OutgoingEvent: Equatable, Sendable {
    /// An instruction for the coordinator.
    case userMessage(String)
    /// Stops one thread, or every thread when `threadID` is `nil`.
    case interrupt(threadID: String?)
    /// Answers a tool call that is waiting for approval.
    case toolConfirmation(toolUseID: String, allow: Bool, denyMessage: String?)

    var json: JSONValue {
        switch self {
        case .userMessage(let text):
            return ["type": "user.message", "content": [["type": "text", "text": .string(text)]]]
        case .interrupt(let threadID):
            var fields: [String: JSONValue] = ["type": "user.interrupt"]
            if let threadID { fields["session_thread_id"] = .string(threadID) }
            return .object(fields)
        case .toolConfirmation(let toolUseID, let allow, let denyMessage):
            var fields: [String: JSONValue] = [
                "type": "user.tool_confirmation",
                "tool_use_id": .string(toolUseID),
                "result": allow ? "allow" : "deny",
            ]
            if !allow, let denyMessage { fields["deny_message"] = .string(denyMessage) }
            return .object(fields)
        }
    }
}

public enum ManagedAgentsError: Error, Equatable, LocalizedError {
    /// The API answered with a non-2xx status.
    case api(status: Int, type: String?, message: String)
    /// The API answered 2xx but not in the expected shape.
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .api(let status, _, let message): return "\(message) (HTTP \(status))"
        case .unexpectedResponse(let detail): return "Unexpected response: \(detail)"
        }
    }

    var status: Int? {
        if case .api(let status, _, _) = self { return status }
        return nil
    }
}
