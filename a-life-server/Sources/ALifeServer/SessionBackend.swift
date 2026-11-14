import ALifeAPI

/// What does the work in one session, when a front end asks for it. It
/// reports what happens by emitting events to the session's `SessionHub`.
///
/// `DummyCharacter` is the only implementation for now. A real one would run
/// an agent here, such as a Claude Code session, and translate what it does
/// into the same events.
protocol SessionBackend: Sendable {
    /// Something said to the character. Must not wait for the work to
    /// finish. Throws if the session can't take a message right now, such as
    /// while it waits for an approval.
    func handleMessage(_ text: String) async throws
    /// Stops whatever the character is doing.
    func interrupt() async
    /// Answers a tool call that is waiting for approval. Throws if there is
    /// no such approval.
    func decide(approvalID: String, allow: Bool) async throws
    /// Drops the conversation and begins an empty one.
    func reset() async
}

/// One session the server hosts: a character's event log, and what does
/// its work.
struct HostedSession: Sendable {
    /// The character's id, such as `gardener`. It is what the session's URLs use.
    let id: String
    let hub: SessionHub
    let backend: any SessionBackend
}
