import Foundation

/// How much of Claude's 5-hour usage window is used, as the server last
/// heard from a character's Claude Code run. The server sends it whole, on
/// `GET /v1/usage` and its stream, each time it changes.
public struct Usage: Codable, Equatable, Sendable {
    /// Goes up by one each time the usage changes. 0 until the server has
    /// read any.
    public var revision: Int
    /// The last 5-hour window read, or `nil` if none has been read yet. It
    /// stays after it resets, until a run reports a new one.
    public var window: UsageWindow?

    public init(revision: Int = 0, window: UsageWindow? = nil) {
        self.revision = revision
        self.window = window
    }

    private enum CodingKeys: String, CodingKey {
        case revision, window
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        // A window this front end can't read is as good as none.
        window = (try? container.decodeIfPresent(UsageWindow.self, forKey: .window)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(window, forKey: .window)
    }
}

/// One reading of the 5-hour usage window: how much of it is used, and when
/// it resets. Dates are in seconds since 1970 on the wire.
public struct UsageWindow: Codable, Equatable, Sendable {
    /// How long a window lasts: five hours.
    public static let length: TimeInterval = 5 * 60 * 60

    /// How much of the window is used, from 0 to 1, or `nil` if the reading
    /// only said when it resets.
    public var utilization: Double?
    /// When the window resets, and a new one can start.
    public var resetsAt: Date
    /// When the reading was taken.
    public var readAt: Date

    public init(utilization: Double?, resetsAt: Date, readAt: Date) {
        self.utilization = utilization.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
        self.readAt = readAt
    }

    /// When the window started: five hours before it resets.
    public var startedAt: Date { resetsAt.addingTimeInterval(-Self.length) }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case readAt = "read_at"
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resetsAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .resetsAt))
        self.init(
            utilization: try container.decodeIfPresent(Double.self, forKey: .utilization),
            resetsAt: resetsAt,
            // Without a time, it counts as read when the window started.
            readAt: try container.decodeIfPresent(Double.self, forKey: .readAt).map(Date.init(timeIntervalSince1970:))
                ?? resetsAt.addingTimeInterval(-Self.length)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(utilization, forKey: .utilization)
        try container.encode(resetsAt.timeIntervalSince1970, forKey: .resetsAt)
        try container.encode(readAt.timeIntervalSince1970, forKey: .readAt)
        // For anyone reading it with curl; it follows from `resets_at`.
        try container.encode(startedAt.timeIntervalSince1970, forKey: .startedAt)
    }
}
