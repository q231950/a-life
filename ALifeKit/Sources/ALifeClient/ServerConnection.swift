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
    /// Whether the lot's latest change happened while this front end was
    /// following it, rather than being what it was sent on connecting, so
    /// what went up while it was away doesn't all pop up at once.
    public private(set) var lotIsNews = false
    /// How much of Claude's 5-hour usage window is used, as the server last
    /// heard. No window until the server has read one, and for servers from
    /// before it told.
    public private(set) var usage = Usage()
    /// The models a character can be switched to, strongest first, for the
    /// model picker. Empty until the server says, and for servers from before
    /// characters had models.
    public private(set) var models: [ModelOption] = []
    /// What the characters have been up to, to look back on, including what
    /// they did while you were away.
    public let log: EventLog

    @ObservationIgnored private let serverURLStore: any ServerURLStoring
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var client: ALifeServerClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public init(
        serverURLStore: any ServerURLStoring = UserDefaultsServerURLStore(),
        urlSession: URLSession = .shared,
        logSeenStore: any LogSeenStoring = UserDefaultsLogSeenStore()
    ) {
        self.serverURLStore = serverURLStore
        self.urlSession = urlSession
        log = EventLog(seenStore: logSeenStore)
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
        lotIsNews = false
        usage = Usage()
        models = []
        log.clear()
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
                // Everything as it is now, taken on in one go. It is read
                // again after every drop, in case the server restarted with
                // other characters.
                let initial = try await initialState(client)
                try Task.checkCancellation() // disconnected meanwhile
                adopt(initial)
                // The models, which the server may take a few seconds to
                // learn when it has just started, so they don't hold up the
                // rest.
                Task { [weak self] in
                    guard let models = try? await client.models(), !models.isEmpty else { return }
                    if self?.models != models { self?.models = models }
                }
                // Each session is followed from where this front end had
                // got to before: what it missed, which the snapshot has
                // already, only goes to the log, and what comes after the
                // snapshot is live.
                var streams: [(AgentSession, AsyncThrowingStream<EventEnvelope, Error>)] = []
                for session in sessions {
                    let stream = try await client.events(
                        of: session.id,
                        conversationID: session.followsFrom.conversationID,
                        after: session.followsFrom.after
                    )
                    streams.append((session, stream))
                }
                let lotChanges = try await followLot(client)
                let usageChanges = try await followUsage(client)
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
                                    self?.lotIsNews = true
                                    self?.lot = lot
                                }
                            }
                        }
                        if let usageChanges {
                            group.addTask { @MainActor [weak self] in
                                for try await usage in usageChanges where usage != self?.usage {
                                    self?.usage = usage
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

    /// The usage's changes, starting with what it is now, or `nil` if the
    /// server is from before it told.
    private func followUsage(_ client: ALifeServerClient) async throws -> AsyncThrowingStream<Usage, Error>? {
        do {
            return try await client.usageChanges()
        } catch ALifeClientError.server(status: 404, reason: _) {
            return nil
        }
    }

    /// Everything on the server as it is now: from its init call, or, from
    /// servers from before there was one, its list of sessions, which has
    /// every session in full too, with the lot and the usage left as they
    /// are for their streams to bring.
    private func initialState(_ client: ALifeServerClient) async throws -> InitialState {
        do {
            return try await client.initialState()
        } catch ALifeClientError.server(status: 404, reason: _) {
            return InitialState(sessions: try await client.sessions(), lot: lot, usage: usage)
        }
    }

    /// Takes on everything in `initial` at once: `sessions` match the
    /// server's, each as it is now, keeping the same `AgentSession` for the
    /// ones that are still there, and the lot and the usage are as it says.
    private func adopt(_ initial: InitialState) {
        sessions = initial.sessions.map { snapshot in
            let kept = session(snapshot.id) ?? AgentSession(SessionState(id: snapshot.id, name: snapshot.name, color: snapshot.color))
            kept.log = log
            kept.catchUp(to: snapshot)
            kept.client = client
            return kept
        }
        if lot != initial.lot {
            lotIsNews = false
            lot = initial.lot
        }
        if usage != initial.usage { usage = initial.usage }
    }
}
