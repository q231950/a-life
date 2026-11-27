import Foundation

/// Everything on a server as it is right now, which a front end takes on in
/// one go when it launches or reconnects, rather than catching up event by
/// event: every session, what is built and planted on the lot, and the
/// usage.
///
/// Each session says where it had got to (`conversationID` and `lastSeq`),
/// so a front end can follow its events on from there without missing or
/// repeating any.
public struct InitialState: Codable, Equatable, Sendable {
    /// Every session, one per character, in the server's order.
    public var sessions: [SessionState]
    /// What the characters have built and planted on the lot.
    public var lot: Lot
    /// How much of Claude's 5-hour usage window is used.
    public var usage: Usage

    public init(sessions: [SessionState], lot: Lot = Lot(), usage: Usage = Usage()) {
        self.sessions = sessions
        self.lot = lot
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case sessions, lot, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([SessionState].self, forKey: .sessions)
        // A lot or a usage this version can't read is as good as none.
        lot = (try? container.decodeIfPresent(Lot.self, forKey: .lot)) ?? Lot()
        usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? Usage()
    }
}
