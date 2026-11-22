import Foundation

/// Claude's usage limits, as Claude Code reports running into one, and
/// whether it is the 5-hour limit, which a character waits out and then
/// carries on after.
///
/// Claude Code says so in more than one way, depending on its version:
///
/// - a `rate_limit_event` whenever what it knows about the limits changes,
///   with `rate_limit_info`: its `status` (`allowed`, `allowed_warning` or
///   `rejected`), `resetsAt` in seconds since 1970, and `rateLimitType`
///   (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`,
///   `seven_day_overage_included` or `overage`);
/// - an assistant message whose `error` is `rate_limit`, with the line it
///   shows, such as "You've hit your session limit · resets 3pm
///   (Europe/Berlin)";
/// - in older versions, only "Claude AI usage limit reached|<seconds since
///   1970>".
///
/// The structured event is read first; the text is the fallback.
enum UsageLimit {
    /// What a `rate_limit_event` says about the limits.
    struct Info: Equatable, Sendable {
        /// `allowed`, `allowed_warning` or `rejected`.
        var status: String?
        var resetsAt: Date?
        /// Which limit, such as `five_hour` or `seven_day`.
        var type: String?

        /// From a `rate_limit_event`'s `rate_limit_info`, or `nil` if it
        /// isn't one.
        init?(_ json: JSONValue?) {
            guard let json, case .object = json else { return nil }
            status = json["status"]?.string
            resetsAt = json["resetsAt"]?.number.map(Date.init(timeIntervalSince1970:))
            type = json["rateLimitType"]?.string
        }

        init(status: String?, resetsAt: Date?, type: String?) {
            self.status = status
            self.resetsAt = resetsAt
            self.type = type
        }
    }

    /// The longest a 5-hour limit can take to reset, with a little to spare
    /// for clocks and rounding.
    static let fiveHours: TimeInterval = 5 * 3600 + 5 * 60

    /// Whether a message Claude Code marked as an error, with `error` and
    /// `text`, says a usage limit stopped the turn. It may not be the
    /// 5-hour one: see `fiveHourReset`.
    static func isLimit(error: String?, text: String) -> Bool {
        if error == "rate_limit" { return true }
        return text.range(of: #"hit your (\S+ )*?limit|usage limit reached|5-hour limit|session limit"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// When the 5-hour limit a turn ran into resets, from the last
    /// `rate_limit_event` (`info`) or, failing that, from what Claude Code
    /// said (`text`). `nil` if it was another limit, such as the weekly one,
    /// or if there's no telling when it resets.
    static func fiveHourReset(info: Info?, text: String?, now: Date, timeZone: TimeZone = .current) -> Date? {
        if let info, info.status == "rejected", let resetsAt = info.resetsAt, resetsAt > now.addingTimeInterval(-300) {
            switch info.type {
            case "five_hour": return resetsAt
            case nil: return resetsAt <= now.addingTimeInterval(fiveHours) ? resetsAt : nil
            default: return nil // a weekly limit, or extra usage
            }
        }
        guard let text else { return nil }
        if text.range(of: #"week|opus|sonnet|month|spend|credit|budget"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        guard let resetsAt = reset(in: text, now: now, timeZone: timeZone),
              resetsAt > now.addingTimeInterval(-300),
              resetsAt <= now.addingTimeInterval(fiveHours)
        else { return nil }
        return resetsAt
    }

    /// When `text` says a limit resets: "…|1763820000", or "resets 3pm",
    /// "resets 3:30pm (Europe/Berlin)", "resets 15:00" or "resets Nov 25,
    /// 3pm", in the time zone in brackets if there is one and `timeZone`
    /// otherwise. A time of day without a date is the next one after `now`.
    static func reset(in text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        if let match = text.firstMatch(of: /\|\s*(\d{9,11})\b/), let seconds = Double(match.1) {
            return Date(timeIntervalSince1970: seconds)
        }
        let pattern = /(?i)resets\s+(?:at\s+)?(?:([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap])?\.?m?\.?(?:\s*\(([^)]+)\))?/
        guard let match = text.firstMatch(of: pattern), var hour = Int(match.3) else { return nil }
        let minute = match.4.flatMap { Int($0) } ?? 0
        if let half = match.5?.lowercased() {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (half == "p" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = match.6.flatMap { TimeZone(identifier: String($0).trimmingCharacters(in: .whitespaces)) } ?? timeZone
        var day = calendar.dateComponents([.year, .month, .day], from: now)
        if let monthName = match.1, let date = match.2.flatMap({ Int($0) }) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: String(monthName.prefix(3)).lowercased()) else { return nil }
            day.month = month + 1
            day.day = date
        }
        day.hour = hour
        day.minute = minute
        guard var resetsAt = calendar.date(from: day) else { return nil }
        // A time already gone is tomorrow's, or next year's for a date.
        let unit: Calendar.Component = match.1 == nil ? .day : .year
        while resetsAt < now.addingTimeInterval(-300) {
            guard let later = calendar.date(byAdding: unit, value: 1, to: resetsAt) else { return nil }
            resetsAt = later
        }
        return resetsAt
    }
}

/// The time, and a way to wait for a time, so a character can wait out a
/// usage limit. `SystemWakeClock` is the real one; tests put one here that
/// doesn't wait.
protocol WakeClock: Sendable {
    func now() -> Date
    /// Returns at `date`, or straight away if it has gone. Throws if the
    /// task waiting is cancelled.
    func sleep(until date: Date) async throws
}

/// The Mac's own clock. It wakes at most a minute apart to look at the time
/// again, so a Mac that slept through the reset carries on once it wakes.
struct SystemWakeClock: WakeClock {
    func now() -> Date { Date() }

    func sleep(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 60) * 1_000_000_000))
        }
    }
}
