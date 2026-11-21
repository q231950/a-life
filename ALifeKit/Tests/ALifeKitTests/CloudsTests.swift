import XCTest
@testable import ALifeClient

/// A few soft clouds in the sky, drifting slowly round it, white by day and
/// faint at night.
final class CloudsTests: XCTestCase {
    private let clock = DayClock()
    private let degree = Double.pi / 180

    func testThereAreACoupleOfClouds() {
        XCTAssertGreaterThanOrEqual(Clouds.clouds.count, 3)
        XCTAssertLessThanOrEqual(Clouds.clouds.count, 8)
        // Each shows somewhere, thickly, and most of the sky is clear.
        var clear = 0, total = 0
        for cloud in Clouds.clouds {
            let middle = cloud.puffs[cloud.puffs.count / 2]
            XCTAssertGreaterThan(Clouds.cover(azimuth: middle.azimuth, elevation: middle.elevation), 0.8)
        }
        for azimuth in stride(from: 0.0, to: 360, by: 2) {
            for elevation in stride(from: 0.0, through: 90, by: 2) {
                total += 1
                if Clouds.cover(azimuth: azimuth * degree, elevation: elevation * degree) < 0.05 { clear += 1 }
            }
        }
        XCTAssertGreaterThan(Double(clear) / Double(total), 0.7)
    }

    func testCloudsStayBetweenTheWallsWorldAndStraightUp() {
        for azimuth in stride(from: 0.0, to: 360, by: 1) {
            for elevation in stride(from: -10.0, through: 90, by: 0.5) {
                let cover = Clouds.cover(azimuth: azimuth * degree, elevation: elevation * degree)
                XCTAssertGreaterThanOrEqual(cover, 0)
                XCTAssertLessThanOrEqual(cover, 1)
                if elevation * degree <= Clouds.lowest || elevation * degree >= Clouds.highest {
                    XCTAssertEqual(cover, 0, accuracy: 1e-9, "at \(azimuth)°, \(elevation)°")
                }
            }
        }
    }

    func testCloudsGoRoundTheSkyWithoutASeam() {
        for elevation in stride(from: 0.0, through: 90, by: 1) {
            let e = elevation * degree
            XCTAssertEqual(Clouds.cover(azimuth: 0, elevation: e), Clouds.cover(azimuth: 2 * .pi, elevation: e), accuracy: 1e-9)
            XCTAssertEqual(Clouds.cover(azimuth: -0.001, elevation: e), Clouds.cover(azimuth: 2 * .pi - 0.001, elevation: e), accuracy: 1e-9)
        }
    }

    func testCloudsAreGreyerAtTheirBaseThanOnTop() {
        for cloud in Clouds.clouds {
            let middle = cloud.puffs[cloud.puffs.count / 2]
            let base = Clouds.light(azimuth: middle.azimuth, elevation: cloud.base)
            let top = Clouds.light(azimuth: middle.azimuth, elevation: middle.elevation + middle.radius)
            XCTAssertLessThan(base, top)
            XCTAssertGreaterThan(base, 0.5)
            XCTAssertLessThanOrEqual(top, 1)
        }
    }

    func testCloudsDriftSlowlyAndCarryOnFromOneDayToTheNext() {
        // Round the sky a whole number of times a day.
        XCTAssertEqual(Clouds.turnsPerDay, Clouds.turnsPerDay.rounded())
        XCTAssertEqual(Clouds.drift(in: Sky(phase: 0)), 0, accuracy: 1e-9)

        var previous = Clouds.drift(in: clock.sky(at: clock.midnight))
        for second in stride(from: 1.0, through: 2 * DayClock.dayLength, by: 1) {
            let drift = Clouds.drift(in: clock.sky(at: clock.midnight.addingTimeInterval(second)))
            XCTAssertGreaterThanOrEqual(drift, 0)
            XCTAssertLessThan(drift, 1)
            // Forwards, a little each second, wrapping round once a turn.
            var step = drift - previous
            if step < 0 { step += 1 }
            XCTAssertGreaterThan(step, 0)
            XCTAssertLessThan(step * 360, 0.5, "slower than half a degree a second")
            previous = drift
        }
        // The same at the same moment for everyone.
        let date = Date(timeIntervalSince1970: 1_790_000_123)
        XCTAssertEqual(Clouds.drift(in: DayClock().sky(at: date)), Clouds.drift(in: clock.sky(at: date)))
    }

    func testCloudsAreFullByDayAndFaintAtNight() {
        let noon = Clouds.opacity(in: Sky(phase: 0.5))
        let midnight = Clouds.opacity(in: Sky(phase: 0))
        XCTAssertGreaterThan(noon, 0.85)
        XCTAssertLessThanOrEqual(noon, 1)
        XCTAssertGreaterThan(midnight, 0)
        XCTAssertLessThan(midnight, 0.4)
        // Fading smoothly through dusk and back up through dawn.
        var previous = Clouds.opacity(in: Sky(phase: 0))
        for phase in stride(from: 0.001, to: 1, by: 0.001) {
            let opacity = Clouds.opacity(in: Sky(phase: phase))
            XCTAssertEqual(opacity, previous, accuracy: 0.02, "at \(phase)")
            if phase > 0.5 && phase < 0.99 { XCTAssertLessThanOrEqual(opacity, previous + 1e-12) }
            previous = opacity
        }
    }
}
