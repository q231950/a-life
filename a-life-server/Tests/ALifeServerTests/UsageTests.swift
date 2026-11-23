import ALifeAPI
import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How much of the 5-hour usage window is used: read from what Claude Code
/// says on every turn, kept across a restart, and sent to the front ends.
final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_359_600)
    private let resetsAt = Date(timeIntervalSince1970: 1_795_366_800)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What Claude Code 2.1.323 wrote on an ordinary turn, trimmed.
    private let ordinaryTurn = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795366800,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.46,"resetsAt":1795366800,"status":"allowed"},"seven_day":{"utilization":0.51,"resetsAt":1795395600,"status":"allowed"}}},"uuid":"u-1","session_id":"session-1"}"#

    private func info(_ line: String) throws -> UsageLimit.Info {
        try XCTUnwrap(UsageLimit.Info(JSONValue.decode(Data(line.utf8))["rate_limit_info"]))
    }

    // MARK: Reading it

    func testTheWindowsAreReadFromAnOrdinaryTurn() throws {
        let info = try info(ordinaryTurn)
        XCTAssertEqual(info.windows["five_hour"], UsageLimit.Info.Window(utilization: 0.46, resetsAt: resetsAt, status: "allowed"))
        XCTAssertEqual(info.windows["seven_day"]?.utilization, 0.51)
        XCTAssertEqual(info.windows["seven_day"]?.resetsAt, Date(timeIntervalSince1970: 1_795_395_600))
        XCTAssertEqual(info.fiveHourWindow(readAt: now), UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: now))
    }

    func testWithoutTheWindowsOnlyWhenItResetsIsKnown() throws {
        let allowed = try info(#"{"rate_limit_info":{"status":"allowed","resetsAt":1795366800,"rateLimitType":"five_hour"}}"#)
        XCTAssertEqual(allowed.fiveHourWindow(readAt: now), UsageWindow(utilization: nil, resetsAt: resetsAt, readAt: now))
        let refused = try info(#"{"rate_limit_info":{"status":"rejected","resetsAt":1795366800,"rateLimitType":"five_hour"}}"#)
        XCTAssertEqual(refused.fiveHourWindow(readAt: now)?.utilization, 1)
        // The weekly limit says nothing about the 5-hour window.
        let weekly = try info(#"{"rate_limit_info":{"status":"allowed","resetsAt":1795395600,"rateLimitType":"seven_day"}}"#)
        XCTAssertNil(weekly.fiveHourWindow(readAt: now))
    }

    func testWhatItCantReadIsSkipped() throws {
        let odd = try info(#"{"rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":"lots"},"ten_minute":{"utilization":0.1,"resetsAt":1},"seven_day":"soon"},"somethingNew":true}}"#)
        XCTAssertEqual(odd.windows["five_hour"], UsageLimit.Info.Window(utilization: nil, resetsAt: nil, status: nil))
        XCTAssertNil(odd.windows["seven_day"])
        XCTAssertNil(odd.fiveHourWindow(readAt: now)) // no reset, no reading
        XCTAssertNil(UsageLimit.Info(JSONValue.string("nope")))
    }

    // MARK: The hub

    func testTheLatestReadingWins() async {
        let hub = UsageHub(file: nil)
        let empty = await hub.usage
        XCTAssertEqual(empty, Usage())

        let first = UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: now)
        await hub.record(first)
        let later = UsageWindow(utilization: 0.4, resetsAt: resetsAt, readAt: now.addingTimeInterval(60))
        await hub.record(later) // from another character, a moment later
        var usage = await hub.usage
        XCTAssertEqual(usage, Usage(revision: 2, window: later))

        // One that doesn't say how much is used keeps what was known.
        await hub.record(UsageWindow(utilization: nil, resetsAt: resetsAt, readAt: now.addingTimeInterval(120)))
        usage = await hub.usage
        XCTAssertEqual(usage.window?.utilization, 0.4)
        XCTAssertEqual(usage.revision, 3)

        // The same again changes nothing.
        await hub.record(UsageWindow(utilization: 0.4, resetsAt: resetsAt, readAt: now.addingTimeInterval(120)))
        usage = await hub.usage
        XCTAssertEqual(usage.revision, 3)

        // A new window, and nothing known of it, is just that.
        let next = resetsAt.addingTimeInterval(5 * 3600)
        await hub.record(UsageWindow(utilization: nil, resetsAt: next, readAt: resetsAt.addingTimeInterval(60)))
        usage = await hub.usage
        XCTAssertNil(usage.window?.utilization)
        XCTAssertEqual(usage.window?.resetsAt, next)
    }

    func testFollowersHearOfEachChange() async {
        let hub = UsageHub(file: nil)
        var changes = await hub.subscribe().makeAsyncIterator()
        let first = await changes.next()
        XCTAssertEqual(first, Usage())
        let reading = UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: now)
        await hub.record(reading)
        let second = await changes.next()
        XCTAssertEqual(second, Usage(revision: 1, window: reading))
        await hub.stop()
        let ended = await changes.next()
        XCTAssertNil(ended)
    }

    func testTheReadingOutlastsARestart() async throws {
        let file = directory.appendingPathComponent("usage.json")
        let reading = UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: now)
        await UsageHub(file: file).record(reading)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["resets_at"] as? Double, resetsAt.timeIntervalSince1970)
        XCTAssertEqual(saved["read_at"] as? Double, now.timeIntervalSince1970)
        XCTAssertEqual(saved["utilization"] as? Double, 0.46)

        let restarted = await UsageHub(file: file).usage
        XCTAssertEqual(restarted, Usage(revision: 1, window: reading))

        // A file it can't read is no reading at all.
        try Data("not json".utf8).write(to: file)
        let unreadable = await UsageHub(file: file).usage
        XCTAssertEqual(unreadable, Usage())
    }

    func testTheDummiesMakeUpALittleUseEachTime() async {
        let hub = UsageHub(file: nil)
        await hub.recordMadeUpUse(at: now)
        var window = await hub.usage.window
        XCTAssertEqual(window?.utilization ?? 0, 0.04, accuracy: 1e-9)
        XCTAssertEqual(window?.resetsAt, now.addingTimeInterval(5 * 3600))
        await hub.recordMadeUpUse(at: now.addingTimeInterval(60))
        window = await hub.usage.window
        XCTAssertEqual(window?.utilization ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(window?.resetsAt, now.addingTimeInterval(5 * 3600))
        // Once it has reset, a new window.
        await hub.recordMadeUpUse(at: now.addingTimeInterval(6 * 3600))
        window = await hub.usage.window
        XCTAssertEqual(window?.utilization ?? 0, 0.04, accuracy: 1e-9)
        XCTAssertEqual(window?.resetsAt, now.addingTimeInterval(11 * 3600))
    }

    // MARK: From the characters

    private func makeBuilder(_ usage: UsageHub, clock: TestClock) async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let hub = SessionHub(id: "builder", name: "Builder")
        let claudeCode = FakeClaudeCode()
        let builder = ClaudeCharacter(.builder, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"), clock: clock, usage: usage)
        await builder.reset()
        return (builder, hub, claudeCode)
    }

    private func until(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    func testEveryTurnTellsTheHub() async throws {
        let usage = UsageHub(file: nil)
        let (builder, _, claudeCode) = await makeBuilder(usage, clock: TestClock(now))
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.last)
        cli.say(ordinaryTurn)
        await until("the reading") { await usage.usage.window != nil }
        let window = await usage.usage.window
        XCTAssertEqual(window, UsageWindow(utilization: 0.46, resetsAt: resetsAt, readAt: now))
    }

    func testATurnThatEndsOnTheLimitReadsAsFull() async throws {
        let usage = UsageHub(file: nil)
        let (builder, hub, claudeCode) = await makeBuilder(usage, clock: TestClock(now))
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.last)
        cli.say(#"{"type":"system","subtype":"init","session_id":"session-1","tools":["Agent","Bash","Read","Write"]}"#)
        cli.say(#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1795366800,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.98,"resetsAt":1795366800,"status":"rejected"}}},"session_id":"session-1"}"#)
        cli.say(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 3pm"}]},"parent_tool_use_id":null,"error":"rate_limit","session_id":"session-1"}"#)
        cli.say(#"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 3pm","session_id":"session-1"}"#)
        await until("the limit") { await hub.state.stopReason == .usageLimit }
        let window = await usage.usage.window
        XCTAssertEqual(window?.utilization, 1)
        XCTAssertEqual(window?.resetsAt, resetsAt)
    }

    // MARK: The server

    @MainActor
    func testTheFrontEndsFollowTheUsage() async throws {
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        do {
            try await configure(app, players: .dummies(step: .milliseconds(20)))
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0 // any free port
            try await app.startup()
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

            let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
            let before = try await client.usage()
            XCTAssertEqual(before, Usage())

            let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
            server.connect()
            for _ in 0..<500 where server.phase != .live {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            // A dummy at work uses up a little of a made-up window.
            let builder = try XCTUnwrap(server.sessions.first)
            await builder.send("Build me a shed")
            for _ in 0..<500 where server.usage.window == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let window = try XCTUnwrap(server.usage.window)
            XCTAssertEqual(window.utilization ?? 0, 0.04, accuracy: 1e-9)
            let now = try await client.usage()
            XCTAssertEqual(now.window, window)
            server.disconnect()
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
