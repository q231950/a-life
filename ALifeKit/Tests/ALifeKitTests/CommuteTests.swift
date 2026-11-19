import XCTest
@testable import ALifeClient

/// A character's way to work and back: up to its room when it starts
/// working, staying put there until it's really done, and back out.
final class CommuteTests: XCTestCase {
    private let frame: Float = 1 / 60

    /// Runs `commute` for `seconds`, and returns what it did on the way.
    @discardableResult
    private func run(_ commute: inout Commute, for seconds: Float, isAtWork: Bool, isAtLift: Bool = false) -> [Commute.Step] {
        var steps: [Commute.Step] = []
        var time: Float = 0
        while time < seconds {
            if let step = commute.advance(by: frame, isAtWork: isAtWork, isAtLift: isAtLift) {
                steps.append(step)
            }
            time += frame
        }
        return steps
    }

    /// A character that has walked in and taken the lift up to its desk.
    private func atDesk() -> Commute {
        var commute = Commute()
        run(&commute, for: 0.5, isAtWork: true) // walking in
        XCTAssertEqual(commute.phase, .goingIn)
        XCTAssertEqual(run(&commute, for: 0.1, isAtWork: true, isAtLift: true), [.enterLift])
        XCTAssertEqual(run(&commute, for: Commute.rideDuration + 0.1, isAtWork: true), [.appearAtDesk])
        XCTAssertEqual(commute.phase, .atDesk)
        return commute
    }

    func testACharacterGoesUpToItsDeskWhenItStartsWorkingAndOutWhenItsDone() {
        var commute = atDesk()
        XCTAssertEqual(run(&commute, for: 10, isAtWork: true), [])
        XCTAssertEqual(run(&commute, for: Commute.settleTime + 0.1, isAtWork: false), [.leaveDesk])
        XCTAssertEqual(run(&commute, for: Commute.rideDuration + 0.1, isAtWork: false), [.appearAtLift])
        XCTAssertEqual(commute.phase, .outside)
        XCTAssertFalse(commute.isHeadingIn)
    }

    func testACharacterAtItsDeskStaysThereWhenYouAnswerItsRequest() {
        // Answering a request, the server says it was answered a moment
        // before it says the character is running again, so the character
        // looks done in between.
        var commute = atDesk()
        for _ in 0..<5 {
            XCTAssertEqual(run(&commute, for: 3, isAtWork: true), []) // working, or waiting for you
            XCTAssertEqual(run(&commute, for: 0.3, isAtWork: false), []) // answered, not running yet
        }
        run(&commute, for: 0.1, isAtWork: true)
        XCTAssertEqual(run(&commute, for: Commute.settleTime * 0.9, isAtWork: false), [])
        XCTAssertEqual(commute.phase, .atDesk)
    }

    func testACharacterOnItsWayInKeepsGoingThroughABlip() {
        var commute = Commute()
        run(&commute, for: 0.5, isAtWork: true)
        run(&commute, for: 0.3, isAtWork: false)
        XCTAssertEqual(commute.phase, .goingIn)
        XCTAssertTrue(commute.isHeadingIn)
        // Turns round once it's really done.
        run(&commute, for: Commute.settleTime, isAtWork: false)
        XCTAssertEqual(commute.phase, .outside)
    }

    func testACharacterBackAtWorkOnTheWayDownGoesStraightBackUp() {
        var commute = atDesk()
        XCTAssertEqual(run(&commute, for: Commute.settleTime + 0.1, isAtWork: false), [.leaveDesk])
        XCTAssertEqual(run(&commute, for: 0.5, isAtWork: false), [])
        // Out of sight all the way, and back at its desk, never in the lobby.
        XCTAssertEqual(run(&commute, for: Commute.rideDuration + 0.1, isAtWork: true), [.appearAtDesk])
    }

    func testACharacterOutsideStaysOutUntilItWorks() {
        var commute = Commute()
        XCTAssertEqual(run(&commute, for: 5, isAtWork: false, isAtLift: true), [])
        XCTAssertEqual(commute.phase, .outside)
    }
}
