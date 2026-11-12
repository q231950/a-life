import ALifeAPI
import Foundation

/// The session's event log and the clients listening to it.
///
/// Whatever drives the team appends events here. Every event gets the next
/// sequence number, updates the snapshot, and goes out to each open stream.
/// The log is kept for the current session, so a client that reconnects can
/// be sent what it missed. Nothing is written to disk: restarting the server
/// starts a new session.
actor SessionHub {
    private(set) var state = SessionState()
    private var log: [EventEnvelope] = []
    private var nextSeq = 1
    private var streams: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]

    /// Ends the current session and begins an empty one.
    func startSession() {
        log = [] // older events belong to a session nobody can ask for any more
        emit(.sessionStarted(sessionID: UUID().uuidString))
    }

    func emit(_ event: SessionEvent) {
        let envelope = EventEnvelope(seq: nextSeq, event: event)
        nextSeq += 1
        log.append(envelope)
        state.apply(envelope)
        for stream in streams.values {
            stream.yield(envelope)
        }
    }

    /// A stream of the events after `seq`, then live ones as they happen.
    ///
    /// A client that names another session than the current one (it saw an
    /// earlier session, or the server restarted), or names none, gets the
    /// current session from its start. That replay begins with
    /// `session.started`, which tells the client to drop what it knew.
    func subscribe(sessionID: String?, after seq: Int) -> AsyncStream<EventEnvelope> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EventEnvelope>.makeStream()
        let isCurrent = sessionID == state.sessionID
        for envelope in log where !isCurrent || envelope.seq > seq {
            continuation.yield(envelope)
        }
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    func closeStreams() {
        for stream in streams.values {
            stream.finish()
        }
        streams = [:]
    }

    private func forget(_ id: UUID) {
        streams[id] = nil
    }
}
