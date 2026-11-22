import Foundation

/// The time of day on the lot. A day there lasts five hours, and the time of
/// day follows from the date alone, so the sun is where it should be however
/// long the app was away, and every front end shows the same time of day.
///
/// A day starts at midnight, with the sun rising in the east a quarter of
/// the way through, standing in the south at noon halfway through, and
/// setting in the west three quarters of the way through, as on a spring
/// day some way north of the equator. The moon stands opposite the sun.
///
/// Anchored to a 5-hour usage window (`init(window:)`), a day is the
/// window: midnight as it starts and as it resets, after which the lot
/// holds at midnight (`until`) until a new window is read.
public struct DayClock: Equatable, Sendable {
    /// How long a day on the lot lasts in real time: five hours.
    public static let dayLength: TimeInterval = 5 * 60 * 60

    /// How long a day lasts, in seconds.
    public let length: TimeInterval
    /// A moment at which a day began, at midnight. Every day since and
    /// before is the same length.
    public let midnight: Date
    /// When the lot stops at midnight, for a day that is a usage window:
    /// the window's reset. `nil` for days that go on one after another.
    public let until: Date?

    public init(length: TimeInterval = DayClock.dayLength, midnight: Date = Date(timeIntervalSinceReferenceDate: 0), until: Date? = nil) {
        self.length = length
        self.midnight = midnight
        self.until = until
    }

    /// How far through its day the lot is at `date`, from 0 at midnight up
    /// to, but not including, 1 at the next midnight. 0 from `until` on.
    public func phase(at date: Date) -> Double {
        if let until, date >= until { return 0 }
        return runningPhase(at: date)
    }

    /// The phase as if the days went on one after another, past `until`:
    /// for the clouds, which keep drifting while the lot holds at midnight.
    public func runningPhase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(midnight).truncatingRemainder(dividingBy: length)
        let phase = (elapsed < 0 ? elapsed + length : elapsed) / length
        return phase < 1 ? phase : 0
    }

    /// The sky over the lot at `date`.
    public func sky(at date: Date) -> Sky {
        Sky(phase: phase(at: date))
    }
}

/// The time of day as the sky shows it: a `DayClock`, and, for a little
/// while after it is swapped for another, an ease from where the sky was to
/// where the new clock says, so the sun sweeps across rather than leaping
/// when a new usage window turns up.
public struct SkyClock: Equatable, Sendable {
    /// How long the sky takes to catch up with a new clock, in seconds.
    public static let easing: TimeInterval = 10

    /// The clock the sky follows, once it has caught up.
    public private(set) var clock: DayClock
    private var ease: Ease?

    /// Where the sky was when the clock changed, and when that was.
    private struct Ease: Equatable, Sendable {
        var start: Date
        var phase: Double
        var clouds: Double
    }

    public init(_ clock: DayClock = DayClock()) {
        self.clock = clock
    }

    /// Follows `clock` from `date` on, easing over from where the sky is
    /// then if `eases`, or straight away if not. The same clock again
    /// changes nothing.
    public mutating func change(to clock: DayClock, at date: Date, eases: Bool = true) {
        guard clock != self.clock else { return }
        let from = Ease(start: date, phase: phase(at: date), clouds: cloudPhase(at: date))
        self.clock = clock
        ease = eases ? from : nil
    }

    /// Whether the sky is still catching up at `date`.
    public func isEasing(at date: Date) -> Bool {
        guard let ease else { return false }
        let elapsed = date.timeIntervalSince(ease.start)
        return elapsed >= 0 && elapsed < Self.easing
    }

    /// How far through its day the sky shows the lot at `date`.
    public func phase(at date: Date) -> Double {
        eased(from: ease?.phase, to: clock.phase(at: date), at: date)
    }

    /// How far round its days the sky shows the clouds' drift at `date`,
    /// which carries on while the lot holds at midnight.
    public func cloudPhase(at date: Date) -> Double {
        eased(from: ease?.clouds, to: clock.runningPhase(at: date), at: date)
    }

    /// The sky over the lot at `date`.
    public func sky(at date: Date) -> Sky {
        Sky(phase: phase(at: date))
    }

    /// The short way round from `from` to `to`, as far along as the ease
    /// is at `date`, gently at either end.
    private func eased(from: Double?, to target: Double, at date: Date) -> Double {
        guard let from, let ease, isEasing(at: date) else { return target }
        var delta = (target - from).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        let progress = smoothstep(0, 1, date.timeIntervalSince(ease.start) / Self.easing)
        let phase = (from + delta * progress).truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }
}

/// A direction from the lot into the sky: how far east, north and up it
/// points, as a unit vector.
public struct SkyDirection: Equatable, Sendable {
    public var east: Double
    public var north: Double
    public var up: Double

    public init(east: Double, north: Double, up: Double) {
        self.east = east
        self.north = north
        self.up = up
    }

    /// How high over the horizon it is, in radians: 0 on the horizon, π/2
    /// straight up, and below 0 under it.
    public var elevation: Double { asin(max(-1, min(1, up))) }

    /// Which way round the horizon it is, in radians, as on a compass: 0 to
    /// the north, π/2 to the east, π to the south and 3π/2 to the west.
    public var azimuth: Double {
        let angle = atan2(east, north)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    public static prefix func - (direction: SkyDirection) -> SkyDirection {
        SkyDirection(east: -direction.east, north: -direction.north, up: -direction.up)
    }
}

/// The sky at one moment of the lot's day: where the sun and the moon are,
/// and how light it is.
public struct Sky: Equatable, Sendable {
    /// How far north of the equator the lot is, in radians, which sets how
    /// high the sun climbs: 90° less this at noon.
    public static let latitude: Double = 35 * .pi / 180

    /// The point in the sky the sun, the moon and the stars turn round once
    /// a day, low in the north.
    public static let pole = SkyDirection(east: 0, north: cos(latitude), up: sin(latitude))

    /// How far through its day the lot is, from 0 at midnight to 1.
    public let phase: Double

    public init(phase: Double) {
        self.phase = phase
    }

    /// Where the sun is.
    public var sun: SkyDirection {
        // The sun's hour angle: 0 at noon, growing through the afternoon.
        let hour = 2 * .pi * (phase - 0.5)
        return SkyDirection(
            east: -sin(hour),
            north: -cos(hour) * sin(Self.latitude),
            up: cos(hour) * cos(Self.latitude)
        )
    }

    /// Where the moon is: opposite the sun, so up all night.
    public var moon: SkyDirection { -sun }

    /// How far the sky has turned round `pole` since midnight, in radians,
    /// by the right-hand rule: turning the sun at midnight by this brings it
    /// to where it is now. The stars turn with it.
    public var turn: Double { -2 * .pi * phase }

    /// How light the day is, from 0 at night to 1 once the sun is up.
    public var daylight: Double {
        smoothstep(-6, 8, degrees(sun.elevation))
    }

    /// How much the dawn or dusk glows, from 0 to 1 while the sun is near
    /// the horizon.
    public var glow: Double {
        1 - smoothstep(0, 14, abs(degrees(sun.elevation) - 1))
    }

    /// How bright the moonlight is, from 0 to 1 once the moon is up.
    public var moonlight: Double {
        smoothstep(-2, 10, degrees(moon.elevation))
    }

    /// How clearly the stars show, from 0 by day to 1 once it is dark.
    public var starlight: Double {
        1 - smoothstep(-14, -3, degrees(sun.elevation))
    }

    /// Whether the sun is up.
    public var isDay: Bool { sun.up > 0 }

    private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// 0 up to `low`, 1 from `high`, and an S-curve in between.
private func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = max(0, min(1, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)
}
