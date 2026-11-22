import XCTest
@testable import ALifeClient

/// What the log keeps, in which order, and what counts as seen.
@MainActor
final class EventLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEntriesAreKeptInTheOrderTheyHappened() {
        let log = EventLog(seenStore: InMemoryLogSeenStore())
        log.record(.reply, "Second.", sessionID: "gardener", name: "Gardener", time: start + 2)
        log.record(.reply, "First.", sessionID: "builder", name: "Builder", time: start + 1)
        log.record(.jobDone, "Finished the job", sessionID: "gardener", name: "Gardener", time: start + 3)
        XCTAssertEqual(log.entries.map(\.text), ["First.", "Second.", "Finished the job"])
        XCTAssertEqual(Set(log.entries.map(\.id)).count, 3)
    }

    func testEntriesAreOneShortPlainLine() {
        let log = EventLog(seenStore: InMemoryLogSeenStore())
        log.record(.reply, "## Done\n\nI built a **café**.", sessionID: "builder", name: "Builder", time: start)
        log.record(.reply, String(repeating: "word ", count: 100), sessionID: "builder", name: "Builder", time: start)
        XCTAssertEqual(log.entries[0].text, "Done. I built a café.")
        XCTAssertEqual(log.entries[1].text.count, EventLog.textLength)
        XCTAssertTrue(log.entries[1].text.hasSuffix("…"))
    }

    func testOnlyTheLatestAreKept() {
        let log = EventLog(seenStore: InMemoryLogSeenStore())
        for index in 0..<(EventLog.kept + 5) {
            log.record(.reply, "Line \(index).", sessionID: "gardener", name: "Gardener", time: start + Double(index))
        }
        XCTAssertEqual(log.entries.count, EventLog.kept)
        XCTAssertEqual(log.entries.first?.text, "Line 5.")
    }

    func testLookingMarksEverythingSeenOnLaterLaunchesToo() {
        let store = InMemoryLogSeenStore()
        let log = EventLog(seenStore: store)
        log.record(.reply, "Before.", sessionID: "gardener", name: "Gardener", time: start, isWhileAway: true)
        log.record(.helperBack, "A helper reported back", sessionID: "gardener", name: "Gardener", time: start + 1, isWhileAway: true)
        XCTAssertEqual(log.unseen.count, 2)

        log.markSeen()
        XCTAssertTrue(log.unseen.isEmpty)
        log.record(.reply, "After.", sessionID: "gardener", name: "Gardener", time: start + 2)
        XCTAssertEqual(log.unseen.map(\.text), ["After."])

        // Caught up on again next launch, what you saw stays seen.
        let relaunched = EventLog(seenStore: store)
        relaunched.record(.reply, "Before.", sessionID: "gardener", name: "Gardener", time: start, isWhileAway: true)
        relaunched.record(.reply, "After.", sessionID: "gardener", name: "Gardener", time: start + 2, isWhileAway: true)
        XCTAssertEqual(relaunched.unseen.map(\.text), ["After."])
    }

    func testClearingKeepsWhatYouHaveSeen() {
        let log = EventLog(seenStore: InMemoryLogSeenStore())
        log.record(.reply, "Hello.", sessionID: "gardener", name: "Gardener", time: start)
        log.markSeen()
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.lastSeen, start)
    }
}
