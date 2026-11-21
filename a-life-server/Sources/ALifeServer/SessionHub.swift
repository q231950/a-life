import ALifeAPI
import Foundation

/// One session's event log and the clients following it.
///
/// Whatever drives the session appends events here. Every event gets the
/// next sequence number, updates the snapshot, and goes out to each open
/// stream. The log is kept for the current conversation, so a client that
/// reconnects can be sent what it missed. Nothing is written to disk:
/// restarting the server starts every session afresh.
actor SessionHub {
    private(set) var state: SessionState
    private var log: [EventEnvelope] = []
    private var nextSeq = 1
    private var streams: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]

    init(id: String, name: String, color: String? = nil) {
        state = SessionState(id: id, name: name, color: color)
    }

    /// Ends the current conversation and begins an empty one. Auto approve
    /// stays as it was: it is the session's, not the conversation's.
    func startConversation() {
        let autoApprove = state.autoApprove
        log = [] // older events belong to a conversation nobody can ask for any more
        emit(.conversationStarted(conversationID: UUID().uuidString))
        if autoApprove {
            emit(.autoApproveChanged(true))
        }
    }

    /// Turns auto approve on or off, saying so only if that changes it.
    func setAutoApprove(_ enabled: Bool) {
        guard state.autoApprove != enabled else { return }
        emit(.autoApproveChanged(enabled))
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
    /// A client that names another conversation than the current one (it saw
    /// an earlier one, or the server restarted), or names none, gets the
    /// current conversation from its start. That replay begins with
    /// `conversation.started`, which tells the client to drop what it knew.
    func subscribe(conversationID: String?, after seq: Int) -> AsyncStream<EventEnvelope> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EventEnvelope>.makeStream()
        let isCurrent = conversationID == state.conversationID
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
