import Foundation

/// Who is on the lot, as the server last said: the ids of its sessions, in
/// the server's order. Agents join and leave the lot while the server runs,
/// such as when the Team Lead adds one, so the server sends the roster whole,
/// on `GET /v1/sessions/events`, at the start and each time it changes. A
/// front end compares it with the sessions it follows, and takes on
/// everything again (`GET /v1/init`) if they differ.
public struct Roster: Codable, Equatable, Sendable {
    /// Goes up by one each time who is on the lot changes. 1 for the first
    /// roster the server sends.
    public var revision: Int
    /// The id of each session, one per character, in the server's order.
    public var sessions: [String]

    public init(revision: Int = 0, sessions: [String] = []) {
        self.revision = revision
        self.sessions = sessions
    }
}
