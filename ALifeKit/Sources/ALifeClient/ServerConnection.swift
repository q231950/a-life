import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A front end's connection to an a-life-server, and the sessions it hosts:
/// one per character.
///
/// The sessions live on the server and keep going whether or not a front end
/// is attached. This object follows each one's event stream and offers an
/// `AgentSession` per character to observe and talk to.
@MainActor
@Observable
public final class ServerConnection {
    public enum Phase: Equatable, Sendable {
        /// No server address stored yet.
        case needsServer
        case disconnected
        case connecting
        /// Up to date and following every session.
        case live
        /// The connection failed or dropped; trying again. Carries the reason.
        case reconnecting(String)
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var serverURL: URL?
    /// One per character, in the order the server lists them.
    public private(set) var sessions: [AgentSession] = []
    /// What the characters have built and planted on the lot. Empty until
    /// the server says, and for servers from before there was anything to
    /// build.
    public private(set) var lot = Lot()

    @ObservationIgnored private let serverURLStore: any ServerURLStoring
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var client: ALifeServerClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public init(serverURLStore: any ServerURLStoring = UserDefaultsServerURLStore(), urlSession: URLSession = .shared) {
        self.serverURLStore = serverURLStore
        self.urlSession = urlSession
        serverURL = serverURLStore.load()
    }

    /// Where the server offers the voice model the characters speak with,
    /// if there is a server. See `ALifeServerClient.voiceModelURL`.
    public var voiceModelURL: URL? {
        serverURL.map { ALifeServerClient(baseURL: $0).voiceModelURL }
    }

    /// The session with this id, if the server has one.
    public func session(_ id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    // MARK: Connecting

    /// Starts following the server's sessions, and keeps trying until
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
        for session in sessions {
            session.client = nil
        }
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
        disconnect()
        sessions = []
        lot = Lot()
        connect()
        return true
    }

    /// Starts every session over, for every front end.
    public func startEverySessionOver() async {
        for session in sessions {
            await session.startOver()
        }
    }

    // MARK: Following the sessions

    private func run(_ client: ALifeServerClient) async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            var reason = "The server closed the connection."
            var connectedAt: Date?
            do {
                // Who is on the lot. It is read again after every drop, in
                // case the server restarted with other characters.
                let listed = try await client.sessions()
                try Task.checkCancellation() // disconnected meanwhile
                adopt(listed)
                // The server replays what this front end missed of each
                // session, then goes live.
                var streams: [(AgentSession, AsyncThrowingStream<EventEnvelope, Error>)] = []
                for session in sessions {
                    let stream = try await client.events(
                        of: session.id,
                        conversationID: session.state.conversationID,
                        after: session.state.lastSeq
                    )
                    streams.append((session, stream))
                }
                let lotChanges = try await followLot(client)
                if streams.isEmpty {
                    reason = "The server has no sessions."
                } else {
                    phase = .live
                    connectedAt = Date()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (session, stream) in streams {
                            group.addTask { @MainActor in
                                for try await envelope in stream {
                                    session.apply(envelope)
                                }
                            }
                        }
                        if let lotChanges {
                            group.addTask { @MainActor [weak self] in
                                for try await lot in lotChanges where lot != self?.lot {
                                    self?.lot = lot
                                }
                            }
                        }
                        // When one stream ends, start over with all of them.
                        _ = try await group.next()
                        group.cancelAll()
                    }
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

    /// The lot's changes, starting with what is on it now, or `nil` if the
    /// server is from before there was anything to build.
    private func followLot(_ client: ALifeServerClient) async throws -> AsyncThrowingStream<Lot, Error>? {
        do {
            return try await client.lotChanges()
        } catch ALifeClientError.server(status: 404, reason: _) {
            return nil
        }
    }

    /// Makes `sessions` match the server's list, keeping what is already
    /// known about the sessions that are still there.
    private func adopt(_ listed: [SessionState]) {
        sessions = listed.map { entry in
            let kept = session(entry.id) ?? AgentSession(SessionState(id: entry.id, name: entry.name, color: entry.color))
            kept.update(from: entry)
            kept.client = client
            return kept
        }
    }
}
