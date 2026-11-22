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
    /// The session's id, which is also its character's, such as `builder`.
    public let id: String
    public private(set) var state: SessionState
    /// The most recent thing that went wrong when talking to this session.
    public private(set) var lastError: String?

    public var name: String { state.name }
    /// The character's colour, as `#RRGGBB`, or `nil` if the server leaves
    /// it to the front end.
    public var color: String? { state.color }
    /// Whether the character is working.
    public var status: RunStatus { state.status }
    public var stopReason: StopReason? { state.stopReason }
    /// When the character carries on by itself, if it stopped on the 5-hour
    /// usage limit and is waiting for it to reset.
    public var resumesAt: Date? { state.stopReason == .usageLimit ? state.resumesAt : nil }
    /// What the character is doing right now, such as the name of a tool.
    public var activity: String? { state.activity }
    /// What was said, by you and the character.
    public var transcript: [Message] { state.messages }
    /// The whole conversation in order: what was said, the tools the
    /// character used, and the tool calls that asked for a yes or no, with
    /// how each was settled.
    public var conversation: [ConversationEntry] { state.conversation }
    /// The tool calls waiting for your yes or no right now.
    public var pendingApprovals: [Approval] { state.approvals }
    /// The helpers out working for the character right now. Each one leaves
    /// the list once it has reported back.
    public var subagents: [Subagent] { state.subagents }
    /// A tool call is waiting for your yes or no. Until it has one, the
    /// character can't be told anything else.
    public var isWaitingForYou: Bool { !state.approvals.isEmpty }
    /// Whether the character's tool calls are allowed without asking you.
    /// Only this session's: each character has its own.
    public var autoApprove: Bool { state.autoApprove }

    /// What was said in the session since this front end caught up with it,
    /// oldest first, as it happened: not what was said before and replayed
    /// on connecting, nor what the character said while finishing a job it
    /// already had when this front end first met it. The most recent few
    /// only. These are the lines worth saying out loud.
    public private(set) var newMessages: [Message] = []
    /// Whether the character is still on a job it already had when this
    /// front end first met it, or is still being caught up on. What it does
    /// meanwhile happened while you were away: it goes to the log, not to
    /// `newMessages`. It ends once the character is seen without a job, or
    /// once you answer it or tell it something.
    public private(set) var isCatchingUp = true
    /// What the character said in the job it finished while you were away,
    /// oldest first: its replies since it was last told something, if
    /// catching up ended with its job done or with it waiting for you. The
    /// narrator turns it into a missed call. Empty otherwise, and once you
    /// answer it or tell it something.
    public private(set) var finishedWhileAway: [Message] = []

    /// Set by the connection while it has a server to talk to.
    @ObservationIgnored var client: ALifeServerClient?
    /// Where what the character does is written down. Set by the connection.
    @ObservationIgnored weak var log: EventLog?
    /// The sequence number the server had got to when the connection last
    /// listed the sessions. Events up to it are replayed, not new.
    @ObservationIgnored var caughtUpAt = 0
    /// How many of `newMessages` are kept.
    static let newMessagesKept = 20

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
        isCatchingUp = false // you're back with it
        finishedWhileAway = []
        await perform { try await $0.sendMessage(text, to: self.id) }
    }

    /// Stops whatever the character is doing.
    public func interrupt() async {
        await perform { try await $0.interrupt(self.id) }
    }

    /// Answers a tool call that is waiting for approval.
    public func respond(to approval: Approval, allow: Bool) async {
        isCatchingUp = false // you're back with it
        finishedWhileAway = []
        await perform { try await $0.decide(approvalID: approval.id, allow: allow, in: self.id) }
    }

    /// Turns auto approve on or off for this character, for every front end.
    /// Turning it on also allows whatever is waiting for you. The switch
    /// shows the change straight away, and goes back if the server says no.
    public func setAutoApprove(_ enabled: Bool) async {
        let was = state.autoApprove
        state.autoApprove = enabled
        await perform { try await $0.setAutoApprove(enabled, in: self.id) }
        if lastError != nil, state.autoApprove == enabled { state.autoApprove = was }
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
        let before = state
        let isWhileAway = envelope.seq <= caughtUpAt || isCatchingUp
        state.apply(envelope)
        if !isWhileAway, case .message(let message) = envelope.event, state.messages.count > before.messages.count {
            newMessages.append(message)
            if newMessages.count > Self.newMessagesKept {
                newMessages.removeFirst(newMessages.count - Self.newMessagesKept)
            }
        }
        record(envelope, after: before, isWhileAway: isWhileAway)
        finishCatchingUp()
    }

    /// Takes on what the server's list of sessions says about this one.
    func update(from listed: SessionState) {
        if state.name != listed.name { state.name = listed.name }
        if state.color != listed.color { state.color = listed.color }
        caughtUpAt = listed.lastSeq
        finishCatchingUp()
    }

    /// Catching up is over once everything listed has been replayed and the
    /// character isn't working any more: whatever job it had before you came
    /// is done, or it is waiting for you. If it finished a job, or is
    /// waiting for you, what it said meanwhile is kept for a missed call.
    private func finishCatchingUp() {
        guard isCatchingUp, state.lastSeq >= caughtUpAt, state.status != .running else { return }
        isCatchingUp = false
        guard (state.status == .idle && state.stopReason == .endTurn) || isWaitingForYou else { return }
        let sinceToldSomething = state.messages.reversed().prefix { $0.kind != .user }.reversed()
        finishedWhileAway = Array(sinceToldSomething.filter { $0.kind == .agent }.suffix(Self.newMessagesKept))
    }

    /// Writes down in the log what `envelope` changed, if it is worth
    /// looking back on. `before` is the session as it was before.
    private func record(_ envelope: EventEnvelope, after before: SessionState, isWhileAway: Bool) {
        guard let log else { return }
        let entry: (EventLog.Entry.Kind, String)?
        switch envelope.event {
        case .message(let message) where state.messages.count > before.messages.count:
            switch message.kind {
            case .agent: entry = (.reply, message.text)
            case .error: entry = (.error, message.text)
            case .user where message.speaker == Message.aLife: entry = (.continued, "Told to carry on: \(message.text)")
            case .user: entry = nil
            }
        case .subagentStarted(let subagent) where state.subagents.count > before.subagents.count:
            entry = (.helperSent, "Sent a helper off: \(subagent.task)")
        case .subagentFinished(let subagentID):
            entry = before.subagents.first { $0.id == subagentID }.map { (.helperBack, "A helper reported back: \($0.task)") }
        case .statusChanged(let status, let stopReason, let resumesAt)
            where status != before.status || stopReason != before.stopReason || resumesAt != before.resumesAt:
            switch (status, stopReason) {
            case (.idle, .endTurn): entry = (.jobDone, "Finished the job")
            case (.idle, .interrupted): entry = (.stopped, "Was stopped")
            case (.idle, .usageLimit):
                let back = resumesAt.map { " Back at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
                entry = (.usageLimit, "Hit the 5-hour usage limit.\(back)")
            default: entry = nil
            }
        case .approvalRequested(let approval) where !before.autoApprove && state.approvals.count > before.approvals.count:
            // With auto approve on, it goes ahead without asking you.
            entry = (.waitingForYou, "Asked to use \(approval.toolName): \(approval.input)")
        default:
            entry = nil
        }
        guard let (kind, text) = entry else { return }
        log.record(kind, text, sessionID: id, name: state.name, time: envelope.time ?? Date(), isWhileAway: isWhileAway)
    }
}
