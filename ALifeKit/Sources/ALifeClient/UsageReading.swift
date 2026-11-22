import ALifeAPI
import Foundation

/// What a front end reads off a reading of the 5-hour window: whether it
/// still holds, whether it is old, how long until it resets, and how full
/// it is.
extension UsageWindow {
    /// How old a reading can be before the gauge says when it was taken and
    /// dims, as it may not be up to date: the server only hears while one of
    /// its characters is running.
    public static let staleAfter: TimeInterval = 30 * 60

    /// How full the window is, for the gauge's colour.
    public enum Band: Equatable, Sendable {
        /// Under 70%: green.
        case plenty
        /// From 70%: amber.
        case getting
        /// From 90%: red.
        case nearlyFull
    }

    /// Whether the window is still going at `date`. Once it has reset, the
    /// reading says nothing about the window after it.
    public func isCurrent(at date: Date) -> Bool {
        date < resetsAt
    }

    /// Whether the reading is more than `staleAfter` old at `date`.
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(readAt) > Self.staleAfter
    }

    /// How long until the window resets, from `date`; 0 once it has.
    public func remaining(at date: Date) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(date))
    }

    /// How long until the window resets, to show: "2h 14m", "14m" or
    /// "under a minute", or `nil` once it has reset.
    public func countdown(at date: Date) -> String? {
        guard isCurrent(at: date) else { return nil }
        let (hours, minutes) = Self.hoursAndMinutes(remaining(at: date))
        switch (hours, minutes) {
        case (0, 0): return "under a minute"
        case (0, _): return "\(minutes)m"
        default: return "\(hours)h \(minutes)m"
        }
    }

    /// The same, to be read out: "2 hours 14 minutes".
    public func spokenCountdown(at date: Date) -> String? {
        guard isCurrent(at: date) else { return nil }
        let (hours, minutes) = Self.hoursAndMinutes(remaining(at: date))
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return parts.isEmpty ? "under a minute" : parts.joined(separator: " ")
    }

    /// How much of the window is used, as a whole percentage, if known.
    public var percent: Int? {
        utilization.map { Int(($0 * 100).rounded()) }
    }

    /// How full the window is, if known.
    public var band: Band? {
        guard let utilization else { return nil }
        if utilization >= 0.9 { return .nearlyFull }
        if utilization >= 0.7 { return .getting }
        return .plenty
    }

    private static func hoursAndMinutes(_ seconds: TimeInterval) -> (Int, Int) {
        let minutes = Int(seconds / 60)
        return (minutes / 60, minutes % 60)
    }
}

extension Usage {
    /// The window to show at `date`: the one read, while it is still going.
    public func currentWindow(at date: Date) -> UsageWindow? {
        guard let window, window.isCurrent(at: date) else { return nil }
        return window
    }
}

extension DayClock {
    /// The lot's day for a usage window: midnight as it starts, noon halfway
    /// through, and midnight again as it resets, after which the lot holds
    /// at midnight until a new window is read.
    public init(window: UsageWindow) {
        self.init(length: UsageWindow.length, midnight: window.startedAt, until: window.resetsAt)
    }

    /// The lot's day for `usage`: the last window read, or, if none has
    /// ever been, the five-hour days that follow from the date alone.
    public static func lot(for usage: Usage) -> DayClock {
        usage.window.map(DayClock.init(window:)) ?? DayClock()
    }
}
