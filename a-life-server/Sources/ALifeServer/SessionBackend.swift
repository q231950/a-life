import ALifeAPI

/// What does the work in one session, when a front end asks for it. It
/// reports what happens by emitting events to the session's `SessionHub`.
///
/// `ClaudeCharacter` runs a Claude Code session and translates what it does
/// into events. `DummyCharacter` plays a script instead, without a model.
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
    /// Turns auto approve on or off in the session. While it's on, each tool
    /// call that asks is allowed straight away and settled as
    /// `autoApproved`; turning it on settles any waiting that way, too.
    func setAutoApprove(_ enabled: Bool) async
    /// Changes the model the character runs on: at once if its session is
    /// running, or else from its next start. `nil` goes back to the agents
    /// file's. Kept across starting over, and, for a Claude Code session,
    /// across a restart of the server.
    func setModel(_ model: ClaudeModel?) async throws
    /// Drops the conversation and begins an empty one.
    func reset() async
    /// The server is stopping: stops anything the session runs.
    func shutdown() async
}

extension SessionBackend {
    func shutdown() async {}
}

/// One session the server hosts: a character's event log, and what does
/// its work.
struct HostedSession: Sendable {
    /// The character's id, such as `builder`. It is what the session's URLs use.
    let id: String
    let hub: SessionHub
    let backend: any SessionBackend
}
