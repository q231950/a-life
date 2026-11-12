import ALifeAPI

/// The thing that actually does the work when a front end asks for it. It
/// reports what happens by emitting events to the `SessionHub`.
///
/// `DummyTeam` is the only implementation for now. A real one would run
/// agents here and translate what they do into the same events.
protocol TeamBackend: Sendable {
    /// An instruction for the coordinator. Must not wait for the work to finish.
    func handleMessage(_ text: String) async
    /// Stops one agent, or the whole team when `agentID` is `nil`.
    func interrupt(agentID: String?) async
    /// Answers a tool call that is waiting for approval. Throws if there is
    /// no such approval.
    func decide(approvalID: String, allow: Bool) async throws
    /// Drops everything and begins an empty session.
    func reset() async
}
