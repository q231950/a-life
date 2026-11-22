import ALifeAPI
@testable import ALifeServer
import Vapor
import XCTest

/// A character that runs into Claude's 5-hour usage limit waits for it to
/// reset and then carries on, by itself, even across a restart. The lines
/// the stand-in CLI says are trimmed from what Claude Code 2.1 writes.
final class UsageLimitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var resetsAt: Date { start.addingTimeInterval(3 * 3600) }
    private var carriesOnAt: Date { resetsAt.addingTimeInterval(60) }

    private func make(
        clock: TestClock,
        continues: PendingContinues = PendingContinues(file: nil)
    ) async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let hub = SessionHub(id: "builder", name: "Builder")
        let claudeCode = FakeClaudeCode()
        let builder = ClaudeCharacter(.builder, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"), continues: continues, clock: clock)
        await builder.reset()
        return (builder, hub, claudeCode)
    }

    @discardableResult
    private func until(
        _ hub: SessionHub,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: (SessionState) -> Bool
    ) async -> SessionState {
        for _ in 0..<300 {
            let state = await hub.state
            if condition(state) { return state }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        return await hub.state
    }

    /// Gives anything that would happen a moment to.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// How many times the character was told to carry on, across every CLI.
    private func pleaseContinues(_ claudeCode: FakeClaudeCode) -> Int {
        claudeCode.clis.flatMap(\.sent).filter { $0["message"]?["content"]?.string == "please continue" }.count
    }

    private func rateLimitEvent(_ status: String, type: String, resetsAt: Date) -> String {
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","resetsAt":\#(Int(resetsAt.timeIntervalSince1970)),"rateLimitType":"\#(type)","isUsingOverage":false},"uuid":"u-1","session_id":"session-1"}"#
    }

    private func hitTheLimit(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"parent_tool_use_id":null,"error":"rate_limit","session_id":"session-1"}"#
    }

    private func errorResult(_ text: String) -> String {
        #"{"type":"result","subtype":"success","is_error":true,"result":"\#(text)","session_id":"session-1"}"#
    }

    private let started = #"{"type":"system","subtype":"init","session_id":"session-1","tools":["Agent","Bash","Read","Write"]}"#

    /// Asks the Builder for an office, and has it run into the 5-hour limit.
    private func runIntoTheLimit(_ builder: ClaudeCharacter, _ hub: SessionHub, _ claudeCode: FakeClaudeCode) async throws -> SessionState {
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.last)
        cli.say(started)
        cli.say(rateLimitEvent("rejected", type: "five_hour", resetsAt: resetsAt))
        cli.say(hitTheLimit("You've hit your session limit · resets 3pm (Europe/Berlin)"))
        cli.say(errorResult("You've hit your session limit · resets 3pm (Europe/Berlin)"))
        return await until(hub, "the limit") { $0.stopReason == .usageLimit }
    }

    func testTheFiveHourLimitIsWaitedOutAndThenItCarriesOnOnce() async throws {
        let clock = TestClock(start)
        let continues = PendingContinues(file: nil)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: continues)

        let state = try await runIntoTheLimit(builder, hub, claudeCode)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.resumesAt, carriesOnAt)
        // Waited out, it isn't an error.
        XCTAssertFalse(state.messages.contains { $0.kind == .error })
        let waiting = await continues.all
        XCTAssertEqual(waiting["builder"], PendingContinues.Entry(character: "builder", claudeSessionID: "session-1", resetsAt: resetsAt))

        // Not before a minute after the reset.
        clock.advance(to: carriesOnAt.addingTimeInterval(-1))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 0)

        clock.advance(to: carriesOnAt)
        let carriedOn = await until(hub, "it to carry on") { $0.status == .running }
        XCTAssertEqual(carriedOn.messages.last?.kind, .user)
        XCTAssertEqual(carriedOn.messages.last?.speaker, "a*life")
        XCTAssertEqual(carriedOn.messages.last?.text, "please continue")
        XCTAssertNil(carriedOn.resumesAt)
        // In the same session, on the CLI still running.
        XCTAssertEqual(claudeCode.launches.count, 1)
        XCTAssertEqual(pleaseContinues(claudeCode), 1)
        let afterwards = await continues.all
        XCTAssertTrue(afterwards.isEmpty)

        // Only once.
        clock.advance(to: carriesOnAt.addingTimeInterval(3600))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 1)
    }

    func testAfterTheCLIHasExitedItCarriesOnInTheSameSession() async throws {
        let clock = TestClock(start)
        let (builder, hub, claudeCode) = await make(clock: clock)
        _ = try await runIntoTheLimit(builder, hub, claudeCode)
        claudeCode.clis.first?.exit()
        await settle()
        var state = await hub.state
        XCTAssertEqual(state.stopReason, .usageLimit) // exiting while it waits isn't an error

        clock.advance(to: carriesOnAt)
        state = await until(hub, "it to carry on") { $0.status == .running }
        XCTAssertEqual(claudeCode.launches.count, 2)
        let resumed = claudeCode.launches[1]
        XCTAssertEqual(resumed.firstIndex(of: "--resume").map { resumed[$0 + 1] }, "session-1")
        XCTAssertEqual(pleaseContinues(claudeCode), 1)
    }

    func testRunningIntoTheLimitAgainWaitsAgain() async throws {
        let clock = TestClock(start)
        let (builder, hub, claudeCode) = await make(clock: clock)
        _ = try await runIntoTheLimit(builder, hub, claudeCode)
        clock.advance(to: carriesOnAt)
        await until(hub, "it to carry on") { $0.status == .running }

        let cli = try XCTUnwrap(claudeCode.clis.last)
        let later = carriesOnAt.addingTimeInterval(4 * 3600)
        cli.say(rateLimitEvent("rejected", type: "five_hour", resetsAt: later))
        cli.say(hitTheLimit("You've hit your session limit · resets 7pm"))
        cli.say(errorResult("You've hit your session limit · resets 7pm"))
        let state = await until(hub, "the limit again") { $0.stopReason == .usageLimit }
        XCTAssertEqual(state.resumesAt, later.addingTimeInterval(60))

        clock.advance(to: later.addingTimeInterval(60))
        await until(hub, "it to carry on again") { $0.status == .running }
        XCTAssertEqual(pleaseContinues(claudeCode), 2)
    }

    func testTellingItSomethingCallsItOff() async throws {
        let clock = TestClock(start)
        let continues = PendingContinues(file: nil)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: continues)
        _ = try await runIntoTheLimit(builder, hub, claudeCode)

        try await builder.handleMessage("Never mind, build a shed")
        let waiting = await continues.all
        XCTAssertTrue(waiting.isEmpty)
        clock.advance(to: carriesOnAt.addingTimeInterval(60))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 0)
    }

    func testStoppingItCallsItOff() async throws {
        let clock = TestClock(start)
        let continues = PendingContinues(file: nil)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: continues)
        _ = try await runIntoTheLimit(builder, hub, claudeCode)

        await builder.interrupt()
        let state = await hub.state
        XCTAssertEqual(state.stopReason, .interrupted)
        XCTAssertNil(state.resumesAt)
        let waiting = await continues.all
        XCTAssertTrue(waiting.isEmpty)
        clock.advance(to: carriesOnAt.addingTimeInterval(60))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 0)
    }

    func testStartingOverCallsItOff() async throws {
        let clock = TestClock(start)
        let continues = PendingContinues(file: nil)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: continues)
        _ = try await runIntoTheLimit(builder, hub, claudeCode)

        await builder.reset()
        let waiting = await continues.all
        XCTAssertTrue(waiting.isEmpty)
        clock.advance(to: carriesOnAt.addingTimeInterval(60))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 0)
        XCTAssertEqual(claudeCode.launches.count, 1)
    }

    func testTheWeeklyLimitIsOnlyReported() async throws {
        let clock = TestClock(start)
        let continues = PendingContinues(file: nil)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: continues)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.say(rateLimitEvent("rejected", type: "seven_day", resetsAt: start.addingTimeInterval(2 * 3600)))
        cli.say(hitTheLimit("You've hit your weekly limit · resets 5pm"))
        cli.say(errorResult("You've hit your weekly limit · resets 5pm"))

        let state = await until(hub, "the end of the turn") { $0.status == .idle && $0.stopReason != nil }
        XCTAssertEqual(state.stopReason, .endTurn)
        XCTAssertNil(state.resumesAt)
        XCTAssertEqual(state.messages.map(\.kind), [.user, .error])
        XCTAssertEqual(state.messages.last?.text, "You've hit your weekly limit · resets 5pm")
        let waiting = await continues.all
        XCTAssertTrue(waiting.isEmpty)
        clock.advance(to: start.addingTimeInterval(8 * 24 * 3600))
        await settle()
        XCTAssertEqual(pleaseContinues(claudeCode), 0)
    }

    func testWithoutTheEventTheTextSaysWhenItResets() async throws {
        let clock = TestClock(start)
        let (builder, hub, claudeCode) = await make(clock: clock)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        let text = "Claude AI usage limit reached|\(Int(resetsAt.timeIntervalSince1970))"
        cli.say(hitTheLimit(text))
        cli.say(errorResult(text))
        let state = await until(hub, "the limit") { $0.stopReason == .usageLimit }
        XCTAssertEqual(state.resumesAt, carriesOnAt)
    }

    func testWaitingForTheLimitOutlastsARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("continues.json")
        let clock = TestClock(start)
        let (builder, hub, claudeCode) = await make(clock: clock, continues: PendingContinues(file: file))
        _ = try await runIntoTheLimit(builder, hub, claudeCode)

        // The file says who waits, in which session, until when.
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?["character"] as? String, "builder")
        XCTAssertEqual(saved.first?["claude_session_id"] as? String, "session-1")
        XCTAssertEqual(saved.first?["resets_at"] as? Double, resetsAt.timeIntervalSince1970)

        // The server stops, and starts again later, as configure does.
        await builder.shutdown()
        let restartedAt = carriesOnAt.addingTimeInterval(-600)
        let laterClock = TestClock(restartedAt)
        let continues = PendingContinues(file: file)
        let loaded = await continues.all
        let entry = try XCTUnwrap(loaded["builder"])
        let (restarted, newHub, newClaudeCode) = await make(clock: laterClock, continues: continues)
        await restarted.carryOn(after: entry)
        var state = await newHub.state
        XCTAssertEqual(state.stopReason, .usageLimit)
        XCTAssertEqual(state.resumesAt, carriesOnAt)
        XCTAssertTrue(newClaudeCode.launches.isEmpty)

        laterClock.advance(to: carriesOnAt)
        state = await until(newHub, "it to carry on") { $0.status == .running }
        XCTAssertEqual(state.messages.last?.text, "please continue")
        let resumed = try XCTUnwrap(newClaudeCode.launches.first)
        XCTAssertEqual(resumed.firstIndex(of: "--resume").map { resumed[$0 + 1] }, "session-1")
        XCTAssertEqual(pleaseContinues(newClaudeCode), 1)
        // Once sent, it's gone from the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testALimitThatResetWhileTheServerWasDownCarriesOnSoonAfterStarting() async throws {
        let clock = TestClock(start)
        let (builder, hub, claudeCode) = await make(clock: clock)
        await builder.carryOn(after: PendingContinues.Entry(character: "builder", claudeSessionID: "session-1", resetsAt: start.addingTimeInterval(-3600)))
        let state = await hub.state
        XCTAssertEqual(state.resumesAt, start.addingTimeInterval(10))
        clock.advance(to: start.addingTimeInterval(10))
        await until(hub, "it to carry on") { $0.status == .running }
        XCTAssertEqual(pleaseContinues(claudeCode), 1)
    }

    // MARK: Reading the limit

    func testWhichLimitAndWhenItResets() {
        let now = start
        let inThreeHours = now.addingTimeInterval(3 * 3600)
        typealias Info = UsageLimit.Info
        XCTAssertEqual(UsageLimit.fiveHourReset(info: Info(status: "rejected", resetsAt: inThreeHours, type: "five_hour"), text: nil, now: now), inThreeHours)
        XCTAssertNil(UsageLimit.fiveHourReset(info: Info(status: "rejected", resetsAt: inThreeHours, type: "seven_day"), text: nil, now: now))
        XCTAssertNil(UsageLimit.fiveHourReset(info: Info(status: "rejected", resetsAt: inThreeHours, type: "seven_day_opus"), text: nil, now: now))
        // Of no known type, only if it resets within five hours.
        XCTAssertEqual(UsageLimit.fiveHourReset(info: Info(status: "rejected", resetsAt: inThreeHours, type: nil), text: nil, now: now), inThreeHours)
        XCTAssertNil(UsageLimit.fiveHourReset(info: Info(status: "rejected", resetsAt: now.addingTimeInterval(2 * 86400), type: nil), text: nil, now: now))
        // A warning isn't the limit; the text is read instead.
        XCTAssertNil(UsageLimit.fiveHourReset(info: Info(status: "allowed_warning", resetsAt: inThreeHours, type: "five_hour"), text: "API Error: overloaded", now: now))

        // The text: 2027-01-15 08:00 UTC is 09:00 in Berlin.
        let morning = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let utc = TimeZone(identifier: "UTC")!
        func at(_ hours: Double) -> Date { morning.addingTimeInterval(hours * 3600) }
        XCTAssertEqual(UsageLimit.reset(in: "You've hit your session limit · resets 1pm (Europe/Berlin)", now: morning, timeZone: utc), at(4))
        XCTAssertEqual(UsageLimit.reset(in: "You've hit your limit · resets 11:30am", now: morning, timeZone: berlin), at(2.5))
        XCTAssertEqual(UsageLimit.reset(in: "resets 12pm", now: morning, timeZone: utc), at(4))
        XCTAssertEqual(UsageLimit.reset(in: "resets 14:00", now: morning, timeZone: utc), at(6))
        // A time gone already is tomorrow's.
        XCTAssertEqual(UsageLimit.reset(in: "resets 7am", now: morning, timeZone: utc), at(23))
        XCTAssertEqual(UsageLimit.reset(in: "resets Jan 17, 3pm", now: morning, timeZone: utc), at(55))
        XCTAssertEqual(UsageLimit.reset(in: "Claude AI usage limit reached|1800010800", now: morning), at(3))
        XCTAssertNil(UsageLimit.reset(in: "Not logged in · Please run /login", now: morning))

        XCTAssertEqual(UsageLimit.fiveHourReset(info: nil, text: "You've hit your session limit · resets 1pm (Europe/Berlin)", now: morning), at(4))
        XCTAssertNil(UsageLimit.fiveHourReset(info: nil, text: "You've hit your weekly limit · resets 1pm (Europe/Berlin)", now: morning))
        XCTAssertNil(UsageLimit.fiveHourReset(info: nil, text: "You've hit your limit · resets 7am", now: morning, timeZone: utc))

        XCTAssertTrue(UsageLimit.isLimit(error: "rate_limit", text: "API Error: Rate limited"))
        XCTAssertTrue(UsageLimit.isLimit(error: nil, text: "You've hit your session limit · resets 3pm"))
        XCTAssertTrue(UsageLimit.isLimit(error: nil, text: "Claude AI usage limit reached|1800010800"))
        XCTAssertFalse(UsageLimit.isLimit(error: "authentication_failed", text: "Not logged in · Please run /login"))
    }
}

/// A clock that only moves when a test moves it, so nobody waits for real.
final class TestClock: WakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (until: Date, wake: CheckedContinuation<Void, Error>)] = [:]

    init(_ start: Date) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Moves the time on to `date`, waking whoever waits for it.
    func advance(to date: Date) {
        lock.lock()
        current = date
        let due = sleepers.filter { $0.value.until <= date }
        for id in due.keys { sleepers[id] = nil }
        lock.unlock()
        for sleeper in due.values { sleeper.wake.resume() }
    }

    func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    wake.resume(throwing: CancellationError())
                } else if date <= current {
                    lock.unlock()
                    wake.resume()
                } else {
                    sleepers[id] = (date, wake)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.wake.resume(throwing: CancellationError())
        }
    }
}
