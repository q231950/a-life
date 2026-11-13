import Foundation
import Observation

/// One character's session, as a front end sees it: what the character is
/// doing, the conversation with it, and its tool calls waiting for a yes or
/// no. Talk to it with `send(_:)`.
///
/// A `ServerConnection` makes these, one per session on the server, and keeps
/// them up to date.
@MainActor
@Observable
public final class AgentSession {
    /// The session's id, which is also its character's, such as `gardener`.
    public let id: String
    public private(set) var state: SessionState
    /// The most recent thing that went wrong when talking to this session.
    public private(set) var lastError: String?

    public var name: String { state.name }
    /// Whether the character is working.
    public var status: RunStatus { state.status }
    public var stopReason: StopReason? { state.stopReason }
    /// What the character is doing right now, such as the name of a tool.
    public var activity: String? { state.activity }
    public var transcript: [Message] { state.messages }
    public var pendingApprovals: [Approval] { state.approvals }
    /// A tool call is waiting for your yes or no. Until it has one, the
    /// character can't be told anything else.
    public var isWaitingForYou: Bool { !state.approvals.isEmpty }

    /// Set by the connection while it has a server to talk to.
    @ObservationIgnored var client: ALifeServerClient?

    public init(_ state: SessionState) {
        id = state.id
        self.state = state
    }

    // MARK: Talking to the character

    /// Says something to the character. Works while it is busy, too: it
    /// answers at its next step.
    public func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await perform { try await $0.sendMessage(text, to: self.id) }
    }

    /// Stops whatever the character is doing.
    public func interrupt() async {
        await perform { try await $0.interrupt(self.id) }
    }

    /// Answers a tool call that is waiting for approval.
    public func respond(to approval: Approval, allow: Bool) async {
        await perform { try await $0.decide(approvalID: approval.id, allow: allow, in: self.id) }
    }

    /// Ends the conversation and starts an empty one, for every front end.
    public func startOver() async {
        await perform { try await $0.startOver(self.id) }
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

    // MARK: Kept up to date by the connection

    func apply(_ envelope: EventEnvelope) {
        state.apply(envelope)
    }

    /// Takes on what the server's list of sessions says about this one.
    func update(from listed: SessionState) {
        if state.name != listed.name { state.name = listed.name }
    }
}
