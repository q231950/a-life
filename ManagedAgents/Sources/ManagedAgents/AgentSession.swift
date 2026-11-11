import Foundation
import Observation

/// One agent in the session, as the UI should show it.
public struct AgentThread: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var status: RunStatus
    /// The coordinator. Instructions you send go to this agent.
    public var isCoordinator: Bool
    /// The tool the agent used most recently, while it is running.
    public var activity: String?
}

public struct TranscriptEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Something you sent.
        case user
        /// The coordinator's reply.
        case agent
        /// A task the coordinator handed to a teammate, or a teammate's report back.
        case handoff
        case error
    }

    public let id: String
    public let kind: Kind
    public let speaker: String
    public let text: String
}

/// A tool call that is waiting for a yes or no.
public struct ToolApproval: Identifiable, Equatable, Sendable {
    public let id: String
    public let agentName: String
    public let toolName: String
    /// The call's input as compact JSON.
    public let input: String
}

/// The app's handle on one multiagent session.
///
/// The session itself runs on Anthropic's side and survives the app quitting.
/// This object remembers its ID, replays its history on launch, follows its
/// live event stream, and turns both into state a UI can observe: the agents
/// and what each is doing, a transcript, and tool calls waiting for approval.
@MainActor
@Observable
public final class AgentSession {
    public enum Phase: Equatable, Sendable {
        /// No API key stored yet.
        case needsAPIKey
        case disconnected
        /// Creating the agent, environment or session.
        case settingUp
        /// Loading history and opening the stream.
        case connecting
        /// Up to date and following the stream.
        case live
        /// The stream dropped; trying again.
        case reconnecting
        case failed(String)
    }

    public private(set) var phase: Phase = .disconnected
    /// Status of the session as a whole: running while any agent is.
    public private(set) var status: RunStatus = .unknown
    /// Why the session last went idle: `end_turn`, `requires_action`, `budget_reached`, ...
    public private(set) var stopReason: String?
    public private(set) var agents: [AgentThread] = []
    public private(set) var transcript: [TranscriptEntry] = []
    public private(set) var pendingApprovals: [ToolApproval] = []
    /// The most recent thing that went wrong when sending.
    public private(set) var lastError: String?
    public private(set) var reference: SessionReference

    public var hasAPIKey: Bool { !(apiKeyStore.load() ?? "").isEmpty }

    @ObservationIgnored private let apiKeyStore: any APIKeyStoring
    @ObservationIgnored private let referenceStore: any SessionReferenceStoring
    @ObservationIgnored private let blueprint: TeamBlueprint
    @ObservationIgnored private let makeClient: @Sendable (String) -> ManagedAgentsClient
    @ObservationIgnored private var client: ManagedAgentsClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var seenEventIDs: Set<String> = []
    @ObservationIgnored private var threadsNeedRefresh = false

    public init(
        apiKeyStore: any APIKeyStoring,
        referenceStore: any SessionReferenceStoring = UserDefaultsSessionReferenceStore(),
        blueprint: TeamBlueprint = .default,
        makeClient: @escaping @Sendable (String) -> ManagedAgentsClient = { ManagedAgentsClient(apiKey: $0) }
    ) {
        self.apiKeyStore = apiKeyStore
        self.referenceStore = referenceStore
        self.blueprint = blueprint
        self.makeClient = makeClient
        reference = referenceStore.load()
    }

    // MARK: Connecting

    /// Attaches to the stored session, creating the agent, environment and
    /// session first if this is the first run. Safe to call again at any time.
    public func connect() {
        disconnect()
        guard let key = apiKeyStore.load(), !key.isEmpty else {
            phase = .needsAPIKey
            return
        }
        let client = makeClient(key)
        self.client = client
        runTask = Task { [weak self] in await self?.run(client) }
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        client = nil
        phase = .disconnected
    }

    /// Stores a new API key and reconnects. Passing `nil` or an empty string
    /// removes the key. The stored IDs belong to the workspace of the key that
    /// created them, so a different key starts from scratch.
    public func setAPIKey(_ key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = apiKeyStore.load()
        apiKeyStore.save(key)
        if let previous, !previous.isEmpty, previous != key {
            update(SessionReference())
        }
        connect()
    }

    /// Leaves the current session as it is on the server and starts a fresh
    /// one with the same agent and environment.
    public func startNewSession() {
        var next = reference
        next.sessionID = nil
        update(next)
        connect()
    }

    // MARK: Talking to the session

    /// Sends an instruction to the coordinator. Messages queue on the server,
    /// so this works while agents are busy.
    public func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await post(.userMessage(text))
    }

    /// Stops one agent, or all of them when `agent` is `nil`.
    public func interrupt(_ agent: AgentThread? = nil) async {
        await post(.interrupt(threadID: agent?.id))
    }

    /// Answers a tool call that is waiting for approval.
    public func respond(to approval: ToolApproval, allow: Bool) async {
        await post(.toolConfirmation(toolUseID: approval.id, allow: allow, denyMessage: nil))
    }

    private func post(_ event: OutgoingEvent) async {
        guard let client, let sessionID = reference.sessionID else {
            lastError = "Not connected to a session."
            return
        }
        do {
            try await client.sendEvents([event], sessionID: sessionID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Run loop

    private func run(_ client: ManagedAgentsClient) async {
        resetSessionState()
        let sessionID: String
        do {
            phase = .settingUp
            sessionID = try await ensureSession(client)
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            return
        }

        var delay: UInt64 = 1
        var connectedAt: Date?
        phase = .connecting
        while !Task.isCancelled {
            do {
                // Stream first, then history: the stream has no replay, so
                // this order plus de-duplication by event ID leaves no gap.
                let stream = try await client.streamEvents(sessionID: sessionID)
                await refreshThreads(client, sessionID: sessionID)
                for event in try await client.listEvents(sessionID: sessionID) {
                    ingest(event)
                }
                if threadsNeedRefresh { await refreshThreads(client, sessionID: sessionID) }
                phase = .live
                connectedAt = Date()
                for try await event in stream {
                    ingest(event)
                    if threadsNeedRefresh { await refreshThreads(client, sessionID: sessionID) }
                }
            } catch {
                if Task.isCancelled { return }
                // Wrong key or a session that is gone: retrying won't help.
                if let status = (error as? ManagedAgentsError)?.status, [401, 403, 404].contains(status) {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            if Task.isCancelled { return }
            if status == .terminated {
                phase = .disconnected // nothing more will happen in this session
                return
            }
            phase = .reconnecting
            // Back off unless the last connection held for a while.
            if let connectedAt, Date().timeIntervalSince(connectedAt) > 10 { delay = 1 }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    /// Returns the ID of the session to attach to, creating whatever is
    /// missing. Each ID is stored as soon as it exists, so a failure halfway
    /// through doesn't create duplicates on the next launch.
    private func ensureSession(_ client: ManagedAgentsClient) async throws -> String {
        var next = referenceStore.load()
        if let sessionID = next.sessionID {
            do {
                let session = try await client.retrieveSession(sessionID)
                status = session.status
                return sessionID
            } catch let error as ManagedAgentsError where error.status == 404 {
                next.sessionID = nil // deleted on the server; make a new one
            }
        }
        if next.environmentID == nil {
            next.environmentID = try await client.createEnvironment(blueprint)
            update(next)
        }
        if next.agentID == nil {
            next.agentID = try await client.createAgent(blueprint)
            update(next)
        }
        let session = try await client.createSession(
            agentID: next.agentID!,
            environmentID: next.environmentID!,
            title: "a*life",
            budgetCents: blueprint.sessionBudgetCents
        )
        next.sessionID = session.id
        update(next)
        status = session.status
        return session.id
    }

    private func update(_ next: SessionReference) {
        reference = next
        referenceStore.save(next)
    }

    private func resetSessionState() {
        status = .unknown
        stopReason = nil
        agents = []
        transcript = []
        pendingApprovals = []
        lastError = nil
        seenEventIDs = []
        threadsNeedRefresh = false
    }

    // MARK: Threads

    /// Replaces the agent list with the server's. Archived threads are left out.
    private func refreshThreads(_ client: ManagedAgentsClient, sessionID: String) async {
        threadsNeedRefresh = false
        guard let threads = try? await client.listThreads(sessionID: sessionID) else { return }
        let previous = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        agents = threads.filter { !$0.isArchived }.map { thread in
            AgentThread(
                id: thread.id,
                name: thread.agentName,
                status: thread.status,
                isCoordinator: thread.parentThreadID == nil,
                activity: previous[thread.id]?.activity
            )
        }
    }

    private func updateAgent(_ id: String?, named name: String? = nil, _ change: (inout AgentThread) -> Void) {
        guard let id else { return }
        if let index = agents.firstIndex(where: { $0.id == id }) {
            change(&agents[index])
        } else {
            // Not in the list yet: show it now, and ask the server for the details.
            var agent = AgentThread(id: id, name: name ?? "Agent", status: .unknown, isCoordinator: false, activity: nil)
            change(&agent)
            agents.append(agent)
            threadsNeedRefresh = true
        }
    }

    private var coordinatorID: String? { agents.first(where: \.isCoordinator)?.id }
    private var coordinatorName: String { agents.first(where: \.isCoordinator)?.name ?? blueprint.agentName }

    // MARK: Events

    /// Applies one event to the observable state. History and live events go
    /// through here alike; an event seen twice is applied once.
    func ingest(_ event: SessionEvent) {
        if !event.id.isEmpty {
            guard seenEventIDs.insert(event.id).inserted else { return }
        }
        let entryID = event.id.isEmpty ? UUID().uuidString : event.id

        switch event.type {
        case "session.status_running":
            status = .running
            stopReason = nil
            // The coordinator has no thread events of its own on this stream;
            // the session status stands in for it.
            updateAgent(coordinatorID) { $0.status = .running }
        case "session.status_idle":
            status = .idle
            stopReason = event.stopReason
            updateAgent(coordinatorID) { $0.status = .idle; $0.activity = nil }
            // Only calls the session is still blocked on can be waiting for an answer.
            let blocking = event["stop_reason"]?["event_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            pendingApprovals.removeAll { !blocking.contains($0.id) }
        case "session.status_rescheduled":
            status = .rescheduling
        case "session.status_terminated":
            status = .terminated
            for index in agents.indices { agents[index].status = .terminated }
            pendingApprovals = []

        case "session.thread_created":
            updateAgent(event.threadID, named: event["agent_name"]?.stringValue) { _ in }
            threadsNeedRefresh = true
        case "session.thread_status_running":
            updateAgent(event.threadID, named: event["agent_name"]?.stringValue) { $0.status = .running }
        case "session.thread_status_idle":
            updateAgent(event.threadID, named: event["agent_name"]?.stringValue) { $0.status = .idle; $0.activity = nil }
        case "session.thread_status_rescheduled":
            updateAgent(event.threadID, named: event["agent_name"]?.stringValue) { $0.status = .rescheduling }
        case "session.thread_status_terminated":
            updateAgent(event.threadID, named: event["agent_name"]?.stringValue) { $0.status = .terminated }
            threadsNeedRefresh = true // it may have been archived

        case "user.message":
            if let text = event.text {
                transcript.append(TranscriptEntry(id: entryID, kind: .user, speaker: "You", text: text))
            }
        case "agent.message":
            if let text = event.text {
                transcript.append(TranscriptEntry(id: entryID, kind: .agent, speaker: coordinatorName, text: text))
            }
        case "agent.thread_message_sent":
            if let text = event.text {
                let to = event["to_agent_name"]?.stringValue ?? "teammate"
                transcript.append(TranscriptEntry(id: entryID, kind: .handoff, speaker: "\(coordinatorName) → \(to)", text: text))
            }
        case "agent.thread_message_received":
            if let text = event.text {
                let from = event["from_agent_name"]?.stringValue ?? "teammate"
                transcript.append(TranscriptEntry(id: entryID, kind: .handoff, speaker: "\(from) → \(coordinatorName)", text: text))
            }

        case "agent.tool_use", "agent.mcp_tool_use":
            let threadID = event.threadID ?? coordinatorID
            let toolName = event["name"]?.stringValue ?? "tool"
            updateAgent(threadID) { $0.activity = toolName }
            if event["evaluated_permission"]?.stringValue == "ask" {
                pendingApprovals.append(ToolApproval(
                    id: event.id,
                    agentName: agents.first(where: { $0.id == threadID })?.name ?? coordinatorName,
                    toolName: toolName,
                    input: Self.compactJSON(event["input"])
                ))
            }
        case "user.tool_confirmation":
            let answered = event["tool_use_id"]?.stringValue
            pendingApprovals.removeAll { $0.id == answered }

        case "session.error":
            let message = event["error"]?["message"]?.stringValue ?? "The session reported an error."
            transcript.append(TranscriptEntry(id: entryID, kind: .error, speaker: "Session", text: message))

        default:
            break
        }
    }

    private static func compactJSON(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
