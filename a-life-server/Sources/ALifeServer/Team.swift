import ALifeAPI
import Foundation
import Vapor

/// Who is on the lot while the server runs: a session per character, which
/// changes as agents join and leave, and the clients following who is there.
///
/// The built-in agents and the person's own, from the agents file, are
/// there from the start and stay. The added agents file (see `Cast`) is
/// watched, since `add-agent` and `remove-agent` run as processes of their
/// own and only write to it: when it changes, the team makes a session for
/// each agent that has joined, ends the session of each that has left, and
/// sends the new `Roster` to the clients following it. A file that is wrong
/// is reported and ignored, and the team stays as it was.
actor Team {
    /// The sessions, in the order the characters are on the lot.
    private(set) var sessions: [HostedSession]
    /// Who is on the lot now, and a revision that goes up whenever that
    /// changes.
    private(set) var roster: Roster

    private var characters: [String: Character]
    private var streams: [UUID: AsyncStream<Roster>.Continuation] = [:]
    private var watching: Task<Void, Never>?
    private var lastText: String?

    private let builtIn: [Character]
    private let own: [Character]
    private let ownSource: String
    private let addedFile: URL?
    private let make: @Sendable (Character) async -> HostedSession
    private let joined: @Sendable (HostedSession) async -> Void
    private let left: @Sendable (HostedSession) async -> Void
    private let logger: Logger

    /// A team of `sessions`, made for `cast`, whose added agents are in
    /// `addedFile` (if there is one to watch). `make` makes the session of
    /// an agent that joins, and `joined` and `left` hear about each that
    /// joins or leaves, once its session is there or is gone.
    init(
        sessions: [HostedSession], cast: Cast.Layers, ownSource: String = "the agents file", addedFile: URL?,
        make: @escaping @Sendable (Character) async -> HostedSession,
        joined: @escaping @Sendable (HostedSession) async -> Void = { _ in },
        left: @escaping @Sendable (HostedSession) async -> Void = { _ in },
        logger: Logger = Logger(label: "a-life.team")
    ) {
        self.sessions = sessions
        characters = Dictionary(uniqueKeysWithValues: cast.all.map { ($0.id, $0) })
        roster = Roster(revision: 1, sessions: sessions.map(\.id))
        builtIn = cast.builtIn
        own = cast.own
        self.ownSource = ownSource
        self.addedFile = addedFile
        self.make = make
        self.joined = joined
        self.left = left
        self.logger = logger
        lastText = addedFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The session with this id, if the character is on the lot.
    func session(_ id: String) -> HostedSession? {
        sessions.first { $0.id == id }
    }

    // MARK: Following the added agents

    /// Looks at the added agents file every `interval` until `stop()`.
    func watch(every interval: Duration) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.refresh()
            }
        }
    }

    /// Reads the added agents file again, and lets the agents that have
    /// joined join, and the ones that have left leave, if it changed. A file
    /// that is wrong, or that clashes with the agents file, is reported, and
    /// nobody joins or leaves until it is put right.
    func refresh() async {
        guard let addedFile else { return }
        let text = try? String(contentsOf: addedFile, encoding: .utf8)
        guard text != lastText else { return }
        lastText = text
        do {
            let added = try text.map { try Cast.decode($0, from: addedFile.path) } ?? []
            let layers = try Cast.layers(
                builtIn: builtIn, own: own, from: ownSource, added: added, from: addedFile.path,
                warn: { logger.warning("\($0)") }
            )
            await reconcile(to: layers.all)
        } catch {
            logger.error("\(error) The agents on the lot stay as they are until the file is put right.")
        }
    }

    /// Makes the team `cast`: an end to the session of each character that
    /// has gone (or is there as another, so it is made again), and a session
    /// for each that isn't there yet. The clients are told, as soon as who is
    /// there has changed, before a leaving session's streams close, so that a
    /// front end sees the roster change rather than a stream end.
    func reconcile(to cast: [Character]) async {
        let wanted = Dictionary(uniqueKeysWithValues: cast.map { ($0.id, $0) })
        let leaving = sessions.filter { wanted[$0.id] != characters[$0.id] }
        if !leaving.isEmpty {
            sessions.removeAll { session in leaving.contains { $0.id == session.id } }
            for session in leaving { characters[session.id] = nil }
            publish()
            for session in leaving {
                logger.notice("\(session.id) leaves the lot")
                await session.hub.closeStreams()
                await session.backend.shutdown()
                await left(session)
            }
        }
        var next: [HostedSession] = []
        for character in cast {
            if let there = sessions.first(where: { $0.id == character.id }) {
                next.append(there)
                continue
            }
            let session = await make(character)
            characters[character.id] = character
            logger.notice("\(character.name) (\(character.id)) joins the lot")
            await joined(session)
            next.append(session)
        }
        let changed = next.map(\.id) != sessions.map(\.id)
        sessions = next
        if changed { publish() }
    }

    // MARK: Following who is there

    /// A stream of who is on the lot now, then after each change.
    func subscribe() -> AsyncStream<Roster> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Roster>.makeStream()
        continuation.yield(roster)
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    /// Stops watching and ends the open streams.
    func stop() {
        watching?.cancel()
        watching = nil
        for stream in streams.values {
            stream.finish()
        }
        streams = [:]
    }

    private func publish() {
        roster = Roster(revision: roster.revision + 1, sessions: sessions.map(\.id))
        for stream in streams.values {
            stream.yield(roster)
        }
    }

    private func forget(_ id: UUID) {
        streams[id] = nil
    }
}
