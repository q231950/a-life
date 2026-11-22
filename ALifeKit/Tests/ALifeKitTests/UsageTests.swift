import XCTest
@testable import ALifeAPI
@testable import ALifeClient

/// The 5-hour usage window: how it comes over the wire, what the gauge
/// reads off it, and the lot's day that follows it.
final class UsageTests: XCTestCase {
    private let hour: TimeInterval = 60 * 60
    private let resetsAt = Date(timeIntervalSince1970: 1_795_366_800)
    private var window: UsageWindow {
        UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: resetsAt.addingTimeInterval(-2 * hour))
    }

    // MARK: The wire

    func testUsageRoundTripsInSecondsSince1970() throws {
        let usage = Usage(revision: 3, window: window)
        let data = try JSONEncoder().encode(usage)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let window = try XCTUnwrap(json["window"] as? [String: Any])
        XCTAssertEqual(window["resets_at"] as? Double, 1_795_366_800)
        XCTAssertEqual(window["started_at"] as? Double, 1_795_366_800 - 5 * hour)
        XCTAssertEqual(window["utilization"] as? Double, 0.46)
        XCTAssertEqual(try JSONDecoder().decode(Usage.self, from: data), usage)
    }

    func testUsageIsReadTolerantly() throws {
        // Nothing read yet.
        XCTAssertEqual(try JSONDecoder().decode(Usage.self, from: Data(#"{"revision":0}"#.utf8)), Usage())
        XCTAssertEqual(try JSONDecoder().decode(Usage.self, from: Data(#"{}"#.utf8)), Usage())
        // Fields it doesn't know, and no utilization or reading time.
        let decoded = try JSONDecoder().decode(Usage.self, from: Data(#"{"revision":2,"window":{"resets_at":1795366800,"status":"allowed"},"seven_day":{}}"#.utf8))
        XCTAssertEqual(decoded.revision, 2)
        XCTAssertNil(decoded.window?.utilization)
        XCTAssertEqual(decoded.window?.resetsAt, resetsAt)
        XCTAssertEqual(decoded.window?.readAt, resetsAt.addingTimeInterval(-5 * hour))
        // A window it can't read is none.
        let broken = try JSONDecoder().decode(Usage.self, from: Data(#"{"revision":4,"window":{"utilization":"lots"}}"#.utf8))
        XCTAssertEqual(broken, Usage(revision: 4))
    }

    func testUtilizationIsAShareFromNoneToAll() {
        XCTAssertEqual(UsageWindow(utilization: 1.4, resetsAt: resetsAt, readAt: resetsAt).utilization, 1)
        XCTAssertEqual(UsageWindow(utilization: -0.1, resetsAt: resetsAt, readAt: resetsAt).utilization, 0)
    }

    // MARK: The gauge

    func testTheCountdownToTheReset() {
        let window = self.window
        XCTAssertEqual(window.countdown(at: resetsAt.addingTimeInterval(-(2 * hour + 14 * 60 + 30))), "2h 14m")
        XCTAssertEqual(window.countdown(at: resetsAt.addingTimeInterval(-5 * hour)), "5h 0m")
        XCTAssertEqual(window.countdown(at: resetsAt.addingTimeInterval(-14 * 60)), "14m")
        XCTAssertEqual(window.countdown(at: resetsAt.addingTimeInterval(-59)), "under a minute")
        XCTAssertNil(window.countdown(at: resetsAt))
        XCTAssertNil(window.countdown(at: resetsAt.addingTimeInterval(hour)))
        XCTAssertEqual(window.remaining(at: resetsAt.addingTimeInterval(-90)), 90)
        XCTAssertEqual(window.remaining(at: resetsAt.addingTimeInterval(90)), 0)

        XCTAssertEqual(window.spokenCountdown(at: resetsAt.addingTimeInterval(-(2 * hour + 14 * 60))), "2 hours 14 minutes")
        XCTAssertEqual(window.spokenCountdown(at: resetsAt.addingTimeInterval(-(hour + 60))), "1 hour 1 minute")
        XCTAssertEqual(window.spokenCountdown(at: resetsAt.addingTimeInterval(-hour)), "1 hour")
        XCTAssertEqual(window.spokenCountdown(at: resetsAt.addingTimeInterval(-10)), "under a minute")
    }

    func testAWindowIsCurrentUntilItResets() {
        XCTAssertTrue(window.isCurrent(at: resetsAt.addingTimeInterval(-1)))
        XCTAssertFalse(window.isCurrent(at: resetsAt))
        XCTAssertEqual(Usage(revision: 1, window: window).currentWindow(at: resetsAt.addingTimeInterval(-1)), window)
        XCTAssertNil(Usage(revision: 1, window: window).currentWindow(at: resetsAt))
        XCTAssertNil(Usage().currentWindow(at: resetsAt))
    }

    func testAReadingIsStaleAfterHalfAnHour() {
        let readAt = window.readAt
        XCTAssertEqual(UsageWindow.staleAfter, 30 * 60)
        XCTAssertFalse(window.isStale(at: readAt))
        XCTAssertFalse(window.isStale(at: readAt.addingTimeInterval(30 * 60)))
        XCTAssertTrue(window.isStale(at: readAt.addingTimeInterval(30 * 60 + 1)))
    }

    func testThePercentageAndItsColour() {
        func band(_ share: Double?) -> UsageWindow.Band? {
            UsageWindow(utilization: share, resetsAt: resetsAt, readAt: resetsAt).band
        }
        XCTAssertEqual(window.percent, 46)
        XCTAssertNil(UsageWindow(utilization: nil, resetsAt: resetsAt, readAt: resetsAt).percent)
        XCTAssertEqual(band(0), .plenty)
        XCTAssertEqual(band(0.69), .plenty)
        XCTAssertEqual(band(0.7), .getting)
        XCTAssertEqual(band(0.89), .getting)
        XCTAssertEqual(band(0.9), .nearlyFull)
        XCTAssertEqual(band(1), .nearlyFull)
        XCTAssertNil(band(nil))
    }

    // MARK: The day

    func testADayIsTheWindow() {
        let clock = DayClock(window: window)
        let start = window.startedAt
        XCTAssertEqual(clock.phase(at: start), 0, accuracy: 1e-9)
        XCTAssertEqual(clock.phase(at: start.addingTimeInterval(1.25 * hour)), 0.25, accuracy: 1e-9)
        // Noon halfway through, with the sun in the south.
        let noon = clock.sky(at: start.addingTimeInterval(2.5 * hour))
        XCTAssertEqual(noon.phase, 0.5, accuracy: 1e-9)
        XCTAssertTrue(noon.isDay)
        XCTAssertLessThan(noon.sun.north, 0)
        XCTAssertEqual(noon.sun.east, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(clock.phase(at: resetsAt.addingTimeInterval(-1)), 0.99)
        // Midnight as it resets.
        XCTAssertEqual(clock.phase(at: resetsAt), 0)
        XCTAssertFalse(clock.sky(at: resetsAt).isDay)
    }

    func testBetweenWindowsTheLotHoldsAtMidnight() {
        let clock = DayClock(window: window)
        for later in [1, 1.25 * hour, 2.5 * hour, 7 * hour] {
            XCTAssertEqual(clock.phase(at: resetsAt.addingTimeInterval(later)), 0)
        }
        // The clouds carry on drifting.
        XCTAssertEqual(clock.runningPhase(at: resetsAt.addingTimeInterval(1.25 * hour)), 0.25, accuracy: 1e-9)
    }

    func testWithNoWindowEverReadTheDayFollowsTheDateAlone() {
        XCTAssertEqual(DayClock.lot(for: Usage()), DayClock())
        XCTAssertEqual(DayClock.lot(for: Usage(revision: 1, window: window)), DayClock(window: window))
        // An old window still holds the lot at midnight.
        XCTAssertEqual(DayClock.lot(for: Usage(revision: 1, window: window)).phase(at: resetsAt.addingTimeInterval(hour)), 0)
    }

    // MARK: The sky catching up

    func testTheSkyEasesOverToANewWindow() {
        let old = DayClock(window: window)
        let start = window.startedAt.addingTimeInterval(4.5 * hour) // phase 0.9
        var sky = SkyClock(old)
        let next = UsageWindow(utilization: 0.02, resetsAt: start.addingTimeInterval(4.5 * hour), readAt: start)
        sky.change(to: DayClock(window: next), at: start) // phase 0.1 there

        XCTAssertTrue(sky.isEasing(at: start))
        XCTAssertEqual(sky.phase(at: start), 0.9, accuracy: 1e-9)
        // Halfway, it has gone the short way round, over midnight.
        let halfway = sky.phase(at: start.addingTimeInterval(SkyClock.easing / 2))
        XCTAssertTrue(halfway > 0.95 || halfway < 0.05, "\(halfway)")
        // Then it follows the new clock.
        let after = start.addingTimeInterval(SkyClock.easing)
        XCTAssertFalse(sky.isEasing(at: after))
        XCTAssertEqual(sky.phase(at: after), DayClock(window: next).phase(at: after), accuracy: 1e-9)
        XCTAssertEqual(sky.cloudPhase(at: after), DayClock(window: next).runningPhase(at: after), accuracy: 1e-9)
    }

    func testTheSameClockAgainChangesNothing() {
        let clock = DayClock(window: window)
        var sky = SkyClock(clock)
        sky.change(to: clock, at: window.readAt)
        XCTAssertFalse(sky.isEasing(at: window.readAt))
        var straight = SkyClock()
        straight.change(to: clock, at: window.readAt, eases: false)
        XCTAssertFalse(straight.isEasing(at: window.readAt))
        XCTAssertEqual(straight.phase(at: window.readAt), clock.phase(at: window.readAt))
    }
}
