import Foundation
import Observation

/// What the characters have been up to, to look back on: their replies, the
/// helpers they sent off and that came back, the jobs they finished or were
/// stopped in, the tool calls they asked you about, their errors, and their
/// calls to you, missed ones too.
///
/// What happened before this front end caught up with a character, or while
/// it was still finishing a job it had before you came, is marked as while
/// you were away. That is never said out loud or rung about; it is only
/// written down here. The time you last looked is kept between launches, so
/// what you have seen stays seen when it is caught up on again.
@MainActor
@Observable
public final class EventLog {
    /// One thing a character did.
    public struct Entry: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// The character said something to you.
            case reply
            /// Something went wrong.
            case error
            /// It sent a helper (a subagent) off.
            case helperSent
            /// A helper reported back.
            case helperBack
            /// It finished its job.
            case jobDone
            /// Someone stopped it.
            case stopped
            /// It asked you about a tool call.
            case waitingForYou
            /// It called you about what you missed.
            case call
            /// It left you a missed call about a job it finished while you
            /// were away.
            case missedCall
        }

        public let id: Int
        /// The character's session.
        public let sessionID: String
        /// The character's name, as it was then.
        public let name: String
        public let kind: Kind
        /// What happened, in a line.
        public let text: String
        /// When it happened, by the server's clock where it said.
        public let time: Date
        /// Whether it happened while you were away: before this front end
        /// caught up with the character, or before it finished a job it had
        /// already started when you came.
        public let isWhileAway: Bool
    }

    /// How many entries are kept. Older ones go first.
    public static let kept = 500
    /// How long an entry's text may be, in characters.
    static let textLength = 160

    /// Everything logged, oldest first.
    public private(set) var entries: [Entry] = []
    /// When you last looked at the log, or `nil` if you never have.
    public private(set) var lastSeen: Date?

    @ObservationIgnored private let seenStore: any LogSeenStoring
    @ObservationIgnored private var nextID = 0

    public init(seenStore: any LogSeenStoring = UserDefaultsLogSeenStore()) {
        self.seenStore = seenStore
        lastSeen = seenStore.load()
    }

    /// Writes down something a character did. Entries are kept in the order
    /// they happened, whatever order they arrive in.
    public func record(
        _ kind: Entry.Kind,
        _ text: String,
        sessionID: String,
        name: String,
        time: Date = Date(),
        isWhileAway: Bool = false
    ) {
        let entry = Entry(
            id: nextID, sessionID: sessionID, name: name, kind: kind,
            text: Self.oneLine(text), time: time, isWhileAway: isWhileAway
        )
        nextID += 1
        let place = entries.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: place)
        if entries.count > Self.kept {
            entries.removeFirst(entries.count - Self.kept)
        }
    }

    /// Whether `entry` came after you last looked.
    public func isUnseen(_ entry: Entry) -> Bool {
        lastSeen.map { entry.time > $0 } ?? true
    }

    /// The entries you haven't looked at yet, oldest first.
    public var unseen: [Entry] {
        entries.filter(isUnseen)
    }

    /// Marks everything logged so far as seen, now and on later launches.
    public func markSeen() {
        // By the newest entry's own clock, which is the server's for most,
        // so the next one is unseen even if this device's clock is ahead.
        let seen = entries.last.map(\.time) ?? Date()
        guard lastSeen.map({ seen > $0 }) ?? true else { return }
        lastSeen = seen
        seenStore.save(seen)
    }

    /// Forgets every entry, as for a different server. What you have seen
    /// stays seen.
    public func clear() {
        entries = []
    }

    /// `text` as one line, plain and short.
    static func oneLine(_ text: String) -> String {
        let spoken = SpokenText.from(text)
        let plain = spoken.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : spoken
        let line = plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard line.count > textLength else { return line }
        return String(line.prefix(textLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Where the time you last looked at the log is kept between launches.
public protocol LogSeenStoring: Sendable {
    func load() -> Date?
    func save(_ date: Date)
}

public struct UserDefaultsLogSeenStore: LogSeenStoring {
    private let key: String

    public init(key: String = "ALife.logLastSeen") {
        self.key = key
    }

    public func load() -> Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    public func save(_ date: Date) {
        UserDefaults.standard.set(date, forKey: key)
    }
}

/// Keeps the time in memory only. For tests and previews.
public final class InMemoryLogSeenStore: LogSeenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    public init(_ date: Date? = nil) { self.date = date }

    public func load() -> Date? { lock.withLock { date } }
    public func save(_ date: Date) { lock.withLock { self.date = date } }
}
