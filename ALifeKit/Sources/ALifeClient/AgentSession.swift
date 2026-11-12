import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A front end's handle on the team's session.
///
/// The session lives on the a-life-server and keeps going whether or not a
/// front end is attached. This object follows the server's event stream,
/// turns it into state a UI can observe, and sends the user's instructions
/// and answers back.
@MainActor
@Observable
public final class AgentSession {
    public enum Phase: Equatable, Sendable {
        /// No server address stored yet.
        case needsServer
        case disconnected
        case connecting
        /// Up to date and following the stream.
        case live
        /// The connection failed or dropped; trying again. Carries the reason.
        case reconnecting(String)
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var serverURL: URL?
    /// The most recent thing that went wrong when sending.
    public private(set) var lastError: String?
    private var state = SessionState()

    /// Running while any agent is.
    public var status: RunStatus { state.status }
    public var stopReason: StopReason? { state.stopReason }
    public var agents: [Agent] { state.agents }
    public var transcript: [Message] { state.messages }
    public var pendingApprovals: [Approval] { state.approvals }

    @ObservationIgnored private let serverURLStore: any ServerURLStoring
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var client: ALifeServerClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public init(serverURLStore: any ServerURLStoring = UserDefaultsServerURLStore(), urlSession: URLSession = .shared) {
        self.serverURLStore = serverURLStore
        self.urlSession = urlSession
        serverURL = serverURLStore.load()
    }

    // MARK: Connecting

    /// Starts following the server's session, and keeps trying until
    /// `disconnect()` is called. Safe to call again at any time.
    public func connect() {
        disconnect()
        guard let serverURL else {
            phase = .needsServer
            return
        }
        let client = ALifeServerClient(baseURL: serverURL, urlSession: urlSession)
        self.client = client
        phase = .connecting
        runTask = Task { [weak self] in await self?.run(client) }
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        client = nil
        phase = .disconnected
    }

    /// Stores the server's address and connects to it. Returns `false`, and
    /// changes nothing, if `text` isn't an http or https URL. An empty string
    /// forgets the stored address.
    @discardableResult
    public func setServerURL(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var url: URL?
        if !text.isEmpty {
            guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), parsed.host != nil else { return false }
            url = parsed
        }
        serverURLStore.save(url)
        serverURL = url
        state = SessionState()
        lastError = nil
        connect()
        return true
    }

    // MARK: Talking to the team

    /// Sends an instruction to the coordinator.
    public func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await perform { try await $0.sendMessage(text) }
    }

    /// Stops one agent, or the whole team when `agent` is `nil`.
    public func interrupt(_ agent: Agent? = nil) async {
        await perform { try await $0.interrupt(agentID: agent?.id) }
    }

    /// Answers a tool call that is waiting for approval.
    public func respond(to approval: Approval, allow: Bool) async {
        await perform { try await $0.decide(approvalID: approval.id, allow: allow) }
    }

    /// Ends the current session and starts an empty one, for every front end.
    public func startNewSession() async {
        await perform { try await $0.resetSession() }
    }

    private func perform(_ call: (ALifeServerClient) async throws -> Void) async {
        guard let client else {
            lastError = "Not connected to a server."
            return
        }
        do {
            try await call(client)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Following the stream

    private func run(_ client: ALifeServerClient) async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            var reason = "The server closed the connection."
            var connectedAt: Date?
            do {
                // The server replays what this front end missed, then goes live.
                let stream = try await client.events(sessionID: state.sessionID, after: state.lastSeq)
                phase = .live
                connectedAt = Date()
                for try await envelope in stream {
                    state.apply(envelope)
                }
            } catch {
                reason = error.localizedDescription
            }
            if Task.isCancelled { return }
            phase = .reconnecting(reason)
            // Back off, unless the connection that just ended had held for a while.
            if let connectedAt, Date().timeIntervalSince(connectedAt) > 10 { delay = 1 }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 10)
        }
    }
}
