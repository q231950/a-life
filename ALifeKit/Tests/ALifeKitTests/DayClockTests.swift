import XCTest
@testable import ALifeClient

/// The lot's five-hour day: the sun up by day and down by night, the moon
/// opposite it, and the same time of day for the same moment.
final class DayClockTests: XCTestCase {
    private let clock = DayClock()
    private let hour: TimeInterval = 60 * 60
    private let degree = Double.pi / 180

    private func sky(after seconds: TimeInterval) -> Sky {
        clock.sky(at: clock.midnight.addingTimeInterval(seconds))
    }

    func testADayLastsFiveHours() {
        XCTAssertEqual(DayClock.dayLength, 5 * hour)
        let start = Date(timeIntervalSince1970: 1_790_000_123)
        for offset in stride(from: 0.0, to: 5 * hour, by: 1234) {
            let date = start.addingTimeInterval(offset)
            XCTAssertEqual(clock.phase(at: date), clock.phase(at: date.addingTimeInterval(5 * hour)), accuracy: 1e-6)
            XCTAssertEqual(clock.phase(at: date), clock.phase(at: date.addingTimeInterval(-15 * hour)), accuracy: 1e-6)
        }
    }

    func testTheTimeOfDayComesFromTheDateAlone() {
        let date = Date(timeIntervalSince1970: 1_790_000_123)
        XCTAssertEqual(DayClock().phase(at: date), DayClock().phase(at: date))
        XCTAssertEqual(DayClock().sky(at: date), clock.sky(at: date))
        // Before the clock's own midnight, too.
        let early = clock.phase(at: clock.midnight.addingTimeInterval(-hour))
        XCTAssertEqual(early, 0.8, accuracy: 1e-9)
    }

    func testTheDayGoesFromMidnightThroughSunriseNoonAndSunset() {
        XCTAssertEqual(sky(after: 0).phase, 0, accuracy: 1e-9)
        XCTAssertEqual(sky(after: 1.25 * hour).phase, 0.25, accuracy: 1e-9)
        XCTAssertEqual(sky(after: 2.5 * hour).phase, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sky(after: 3.75 * hour).phase, 0.75, accuracy: 1e-9)
        XCTAssertLessThan(sky(after: 4.99 * hour).phase, 1)
    }

    func testTheSunRisesInTheEastStandsInTheSouthAtNoonAndSetsInTheWest() {
        let sunrise = Sky(phase: 0.25).sun
        XCTAssertEqual(sunrise.elevation, 0, accuracy: 1e-9)
        XCTAssertEqual(sunrise.azimuth, .pi / 2, accuracy: 1e-9)

        let noon = Sky(phase: 0.5).sun
        XCTAssertEqual(noon.elevation, .pi / 2 - Sky.latitude, accuracy: 1e-9)
        XCTAssertEqual(noon.azimuth, .pi, accuracy: 1e-9)

        let sunset = Sky(phase: 0.75).sun
        XCTAssertEqual(sunset.elevation, 0, accuracy: 1e-9)
        XCTAssertEqual(sunset.azimuth, 3 * .pi / 2, accuracy: 1e-9)

        // From east to west through the south, climbing till noon.
        var previous = Sky(phase: 0.26).sun
        for phase in stride(from: 0.27, through: 0.74, by: 0.01) {
            let sun = Sky(phase: phase).sun
            XCTAssertGreaterThan(sun.azimuth, previous.azimuth)
            if phase < 0.5 { XCTAssertGreaterThan(sun.elevation, previous.elevation) }
            if phase > 0.51 { XCTAssertLessThan(sun.elevation, previous.elevation) }
            previous = sun
        }
    }

    func testTheSunIsUpByDayAndDownByNightWithTheMoonOppositeIt() {
        for phase in stride(from: 0.26, through: 0.74, by: 0.01) {
            let sky = Sky(phase: phase)
            XCTAssertTrue(sky.isDay, "at \(phase)")
            XCTAssertGreaterThan(sky.sun.elevation, 0)
            XCTAssertLessThan(sky.moon.elevation, 0)
            XCTAssertEqual(sky.starlight, 0, "no stars by day, at \(phase)")
        }
        for phase in Array(stride(from: 0.0, through: 0.24, by: 0.01)) + Array(stride(from: 0.76, to: 1, by: 0.01)) {
            let sky = Sky(phase: phase)
            XCTAssertFalse(sky.isDay, "at \(phase)")
            XCTAssertLessThan(sky.sun.elevation, 0)
            XCTAssertGreaterThan(sky.moon.elevation, 0)
        }
        let noon = Sky(phase: 0.5)
        XCTAssertEqual(noon.daylight, 1)
        XCTAssertEqual(noon.glow, 0)
        XCTAssertEqual(noon.moonlight, 0)
        let midnight = Sky(phase: 0)
        XCTAssertEqual(midnight.daylight, 0)
        XCTAssertEqual(midnight.starlight, 1)
        XCTAssertEqual(midnight.moonlight, 1)
        XCTAssertEqual(midnight.moon.elevation, .pi / 2 - Sky.latitude, accuracy: 1e-9)
    }

    func testDawnAndDuskGlow() {
        XCTAssertGreaterThan(Sky(phase: 0.25).glow, 0.9)
        XCTAssertGreaterThan(Sky(phase: 0.75).glow, 0.9)
        let dusk = Sky(phase: 0.75)
        XCTAssertGreaterThan(dusk.daylight, 0)
        XCTAssertLessThan(dusk.daylight, 1)
    }

    func testTheSkyCarriesOnSmoothlyFromOneDayToTheNext() {
        let before = sky(after: 5 * hour - 1)
        let after = sky(after: 5 * hour + 1)
        XCTAssertGreaterThan(before.phase, 0.99)
        XCTAssertLessThan(after.phase, 0.01)
        let apart = acos(before.sun.east * after.sun.east + before.sun.north * after.sun.north + before.sun.up * after.sun.up)
        XCTAssertLessThan(apart, 0.1 * degree)
        XCTAssertEqual(before.daylight, after.daylight, accuracy: 1e-6)
        XCTAssertEqual(before.starlight, after.starlight, accuracy: 1e-6)

        // And from one moment to the next all day long.
        var previous = sky(after: 0)
        for second in stride(from: 10.0, through: 5 * hour, by: 10) {
            let sky = sky(after: second)
            XCTAssertEqual(sky.sun.up, previous.sun.up, accuracy: 0.03)
            XCTAssertEqual(sky.daylight, previous.daylight, accuracy: 0.03)
            XCTAssertEqual(sky.starlight, previous.starlight, accuracy: 0.03)
            previous = sky
        }
    }

    func testTheSkyTurnsRoundThePoleWithTheSun() {
        let midnight = Sky(phase: 0).sun
        for phase in stride(from: 0.0, to: 1, by: 0.05) {
            let sky = Sky(phase: phase)
            let turned = rotate(midnight, about: Sky.pole, by: sky.turn)
            XCTAssertEqual(turned.east, sky.sun.east, accuracy: 1e-9)
            XCTAssertEqual(turned.north, sky.sun.north, accuracy: 1e-9)
            XCTAssertEqual(turned.up, sky.sun.up, accuracy: 1e-9)
        }
    }

    /// Turns `v` by `angle` round `axis`, by the right-hand rule.
    private func rotate(_ v: SkyDirection, about axis: SkyDirection, by angle: Double) -> SkyDirection {
        let (c, s) = (cos(angle), sin(angle))
        let dot = v.east * axis.east + v.north * axis.north + v.up * axis.up
        let cross = (
            east: axis.north * v.up - axis.up * v.north,
            north: axis.up * v.east - axis.east * v.up,
            up: axis.east * v.north - axis.north * v.east
        )
        return SkyDirection(
            east: v.east * c + cross.east * s + axis.east * dot * (1 - c),
            north: v.north * c + cross.north * s + axis.north * dot * (1 - c),
            up: v.up * c + cross.up * s + axis.up * dot * (1 - c)
        )
    }
}
