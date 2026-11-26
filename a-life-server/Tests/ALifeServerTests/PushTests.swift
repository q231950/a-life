import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records what it is asked to send, and sends nothing. Each token gets
/// what `results` says, or is delivered.
actor RecordingPushSender: PushSender {
    private(set) var sent: [(notice: PushNotice, token: String)] = []
    private var results: [String: PushResult] = [:]

    func send(_ notice: PushNotice, to device: RegisteredDevice) -> PushResult {
        sent.append((notice, device.token))
        return results[device.token] ?? .delivered
    }

    func answer(_ result: PushResult, for token: String) {
        results[token] = result
    }
}

// MARK: When a job ends

/// `JobWatch`, driven by a session's events, a minute apart.
final class JobWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_763_820_000)

    /// The jobs the events end, fed to `watch` one a minute.
    private func endings(_ events: [SessionEvent], watch: inout JobWatch) -> [JobWatch.Ending] {
        var endings: [JobWatch.Ending] = []
        for (index, event) in events.enumerated() {
            let envelope = EventEnvelope(seq: index + 1, event: event, time: start.addingTimeInterval(Double(index) * 60))
            if let ending = watch.feed(envelope) { endings.append(ending) }
        }
        return endings
    }

    private func endings(_ events: [SessionEvent]) -> [JobWatch.Ending] {
        var watch = JobWatch()
        return endings(events, watch: &watch)
    }

    private func you(_ text: String) -> SessionEvent {
        .message(Message(kind: .user, speaker: "You", text: text))
    }

    private let running = SessionEvent.statusChanged(.running, stopReason: nil)
    private let done = SessionEvent.statusChanged(.idle, stopReason: .endTurn)

    func testAFinishedJobNotifiesOnce() throws {
        let events: [SessionEvent] = [
            .conversationStarted(conversationID: "c1"),
            you("Tidy the lot"),
            running,
            .toolUsed(ToolUse(toolName: "Read", input: "/lot/lot.md")),
            .toolUsed(ToolUse(toolName: "Bash", input: "ls buildings")),
            .toolUsed(ToolUse(toolName: "Edit", input: "/lot/buildings/office.md")),
            .subagentStarted(Subagent(task: "Measure the north corner")),
            .approvalRequested(Approval(toolName: "Write", input: "construction-worker: /lot/garden/roses.md")),
            .message(Message(id: "r1", kind: .agent, speaker: "Builder", text: "Done.")),
            done,
            done, // said again, with no new work
        ]
        let ended = endings(events)
        XCTAssertEqual(ended.count, 1)
        let ending = try XCTUnwrap(ended.first)
        XCTAssertEqual(ending.kind, .finished)
        XCTAssertEqual(ending.record.task, "Tidy the lot")
        XCTAssertEqual(ending.record.filesChanged, ["/lot/buildings/office.md", "/lot/garden/roses.md"])
        XCTAssertEqual(ending.record.commands, 1)
        XCTAssertEqual(ending.record.helpers, 1)
        XCTAssertEqual(ending.messageID, "r1")
        XCTAssertEqual(ending.conversationID, "c1")
        XCTAssertEqual(ending.seq, 10)
        XCTAssertEqual(ending.duration, 7 * 60) // from running to the end
    }

    func testAJobThatStoppedOnAnErrorNotifiesAsOne() throws {
        let ending = try XCTUnwrap(endings([
            you("Fix the build"),
            running,
            .message(Message(id: "e1", kind: .error, speaker: "Engineer", text: "Claude Code stopped unexpectedly.")),
            done,
        ]).first)
        XCTAssertEqual(ending.kind, .error)
        XCTAssertEqual(ending.messageID, "e1")
    }

    func testNothingForWhatIsntTheEndOfTheWork() {
        let interrupted = SessionEvent.statusChanged(.idle, stopReason: .interrupted)
        let limit = SessionEvent.statusChanged(.idle, stopReason: .usageLimit, resumesAt: start.addingTimeInterval(3600))
        let asks = SessionEvent.statusChanged(.idle, stopReason: .requiresAction)
        XCTAssertTrue(endings([you("Tidy"), running, interrupted, done]).isEmpty, "an interrupt")
        XCTAssertTrue(endings([you("Tidy"), running, limit]).isEmpty, "the usage limit")
        XCTAssertTrue(endings([you("Tidy"), running, asks]).isEmpty, "a question")
        XCTAssertTrue(endings([done, done]).isEmpty, "a status with no run before it")
        XCTAssertTrue(endings([you("Tidy"), running, .conversationStarted(conversationID: "c2"), done]).isEmpty, "starting over")
    }

    func testWaitingForYouIsStillTheSameJob() throws {
        let ended = endings([
            you("Build an office"),
            running,
            .toolUsed(ToolUse(toolName: "Write", input: "/lot/buildings/office.md")),
            .statusChanged(.idle, stopReason: .requiresAction),
            running,
            .toolUsed(ToolUse(toolName: "Bash", input: "ls")),
            done,
        ])
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.record.filesChanged, ["/lot/buildings/office.md"])
        XCTAssertEqual(ended.first?.record.commands, 1)
        XCTAssertEqual(ended.first?.duration, 5 * 60)
    }

    func testTwoJobsInARowNotifyOnceEach() {
        let ended = endings([
            you("Plant roses"),
            running,
            .toolUsed(ToolUse(toolName: "Write", input: "/lot/garden/roses.md")),
            done,
            you("Now some tulips"),
            running,
            done,
        ])
        XCTAssertEqual(ended.map(\.record.task), ["Plant roses", "Now some tulips"])
        XCTAssertEqual(ended.map(\.record.filesChanged), [["/lot/garden/roses.md"], []])
    }

    func testCarryingOnAfterTheUsageLimitNotifiesOnceWithTheTaskFromBefore() {
        let ended = endings([
            you("Build a barn"),
            running,
            .statusChanged(.idle, stopReason: .usageLimit, resumesAt: start.addingTimeInterval(3600)),
            .message(Message(kind: .user, speaker: Message.aLife, text: ClaudeCharacter.pleaseContinue)),
            running,
            .message(Message(kind: .agent, speaker: "Builder", text: "The barn is up.")),
            done,
        ])
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.record.task, "Build a barn") // not a*life's "please continue"
    }

    func testFilesAreTheDistinctOnesChanged() {
        let ended = endings([
            you("Tidy the code"),
            running,
            .toolUsed(ToolUse(toolName: "Edit", input: "/a/World.swift")),
            .toolUsed(ToolUse(toolName: "MultiEdit", input: "/a/Office.swift")),
            .toolUsed(ToolUse(toolName: "Edit", input: "/a/World.swift")),
            .toolUsed(ToolUse(toolName: "NotebookEdit", input: "/a/Plan.ipynb")),
            .toolUsed(ToolUse(toolName: "Read", input: "/a/README.md")),
            .toolUsed(ToolUse(toolName: "Grep", input: "Sheep")),
            .toolUsed(ToolUse(toolName: "Bash", input: "swift test")),
            .toolUsed(ToolUse(toolName: "Bash", input: "git status")),
            // Asked about after it was used: counted once.
            .approvalRequested(Approval(toolName: "Bash", input: "git status")),
            .subagentStarted(Subagent(task: "Look into it")),
            .subagentStarted(Subagent(task: "And this")),
            done,
        ])
        XCTAssertEqual(ended.first?.record.filesChanged, ["/a/World.swift", "/a/Office.swift", "/a/Plan.ipynb"])
        XCTAssertEqual(ended.first?.record.commands, 2)
        XCTAssertEqual(ended.first?.record.helpers, 2)
    }

    func testAJobUnderWayIsSeededFromTheSession() throws {
        var state = SessionState(id: "engineer", name: "Engineer")
        for (seq, event) in [SessionEvent.conversationStarted(conversationID: "c1"), you("Add notifications"), running].enumerated() {
            state.apply(EventEnvelope(seq: seq + 1, event: event))
        }
        var watch = JobWatch(seededFrom: state, now: start)
        let ending = try XCTUnwrap(endings([
            .message(Message(id: "r1", kind: .agent, speaker: "Engineer", text: "Added.")),
            done,
        ], watch: &watch).first)
        XCTAssertEqual(ending.record.task, "Add notifications")
        XCTAssertEqual(ending.conversationID, "c1")
        XCTAssertEqual(ending.messageID, "r1")
    }
}

// MARK: What it says

final class JobSummaryTests: XCTestCase {
    private func body(
        task: String? = nil, files: [String] = [], commands: Int = 0, helpers: Int = 0,
        duration: TimeInterval? = nil, kind: PushRoute.Kind = .finished
    ) -> String {
        let record = JobRecord(task: task, startedAt: nil, filesChanged: files, commands: commands, helpers: helpers)
        return JobSummary.body(of: record, duration: duration, kind: kind, name: "Engineer")
    }

    func testTheLineForAWholeJob() {
        XCTAssertEqual(
            body(
                task: "Add a plan for push notifications", files: ["docs/plans/push-notifications.md", "README.md"],
                commands: 4, helpers: 2, duration: 12 * 60 + 30
            ),
            "Worked on “Add a plan for push notifications” for 12 min: changed push-notifications.md and README.md, ran 4 commands, sent 2 helpers."
        )
        XCTAssertEqual(body(files: ["/lot/README.md"], commands: 1, helpers: 1), "Changed README.md, ran 1 command, sent 1 helper.")
    }

    func testTheTaskIsItsFirstLineInPlainText() {
        XCTAssertEqual(
            body(task: "\n## **Add** a `plan`  for [push](https://example.com/a) notifications\nand then the rest"),
            "Worked on “Add a plan for push notifications”."
        )
    }

    func testALongTaskIsCutAtAWord() throws {
        let task = "Please tidy up every single flower bed on the lot and then water all of the roses twice over"
        let cut = JobSummary.cut(task, near: JobSummary.taskLength)
        XCTAssertTrue(cut.hasSuffix("…"))
        let kept = String(cut.dropLast())
        XCTAssertLessThanOrEqual(kept.count, JobSummary.taskLength)
        XCTAssertTrue(task.hasPrefix(kept + " "), cut) // whole words only
        XCTAssertEqual(body(task: task), "Worked on “\(cut)”.")
    }

    func testFilesPastThreeAreCounted() {
        let files = ["a", "b", "c", "d", "e", "f", "g"].map { "Sources/\($0).swift" }
        XCTAssertEqual(body(task: "Tidy up", files: files), "Worked on “Tidy up”: changed a.swift, b.swift, c.swift and 4 more.")
        XCTAssertEqual(body(task: "Tidy up", files: Array(files.prefix(3))), "Worked on “Tidy up”: changed a.swift, b.swift and c.swift.")
    }

    func testHowLongItTook() {
        XCTAssertEqual(body(task: "Water the roses", duration: 30), "Worked on “Water the roses” for under a minute.")
        XCTAssertEqual(body(task: "Water the roses", duration: 12 * 60), "Worked on “Water the roses” for 12 min.")
        XCTAssertEqual(body(task: "Water the roses", duration: 80 * 60), "Worked on “Water the roses” for 1 h 20 min.")
        XCTAssertEqual(body(task: "Water the roses", duration: 120 * 60 + 10), "Worked on “Water the roses” for 2 h.")
    }

    func testAJobThatStopped() {
        XCTAssertEqual(
            body(task: "Fix the build", commands: 2, duration: 3 * 60, kind: .error),
            "Stopped after 3 min, working on “Fix the build”: ran 2 commands."
        )
        XCTAssertEqual(body(task: "Fix the build", duration: 20, kind: .error), "Stopped within a minute, working on “Fix the build”.")
        XCTAssertEqual(JobSummary.subtitle(for: .error), "Stopped")
        XCTAssertEqual(JobSummary.subtitle(for: .finished), "Finished")
    }

    func testItsNeverTooLongTheFilesGivingWayFirst() {
        let task = "Rename every view in the app so that each says what it shows"
        let files = (1...6).map { "Sources/AVeryLongFileNameThatGoesOnAndOn\($0).swift" }
        let line = body(task: task, files: files, commands: 12, helpers: 3, duration: 95 * 60)
        XCTAssertLessThanOrEqual(line.count, JobSummary.maxLength, line)
        XCTAssertTrue(line.contains("changed 6 files"), line)
        XCTAssertTrue(line.contains("“\(JobSummary.cut(task, near: JobSummary.taskLength))”"), line)

        let huge = body(task: String(repeating: "word ", count: 2000), files: (1...500).map { "/\(String(repeating: "x", count: 200))/\($0).swift" }, commands: 9999, helpers: 9999, duration: 99 * 3600)
        XCTAssertLessThanOrEqual(huge.count, JobSummary.maxLength, huge)
    }

    func testWithNothingToSayItSaysTheyFinished() {
        XCTAssertEqual(body(), "Engineer finished their work.")
        XCTAssertEqual(body(duration: 600), "Engineer finished their work.")
        XCTAssertEqual(body(task: "  \n  ", duration: 600), "Engineer finished their work.")
        XCTAssertEqual(body(kind: .error), "Engineer stopped.")
    }
}

// MARK: The payload

final class PushNoticeTests: XCTestCase {
    private let route = PushRoute(serverID: "6B0E", session: "engineer", conversation: "1F3C", message: "9A21", seq: 482, kind: .finished)

    private func payload(_ notice: PushNotice) throws -> [String: Any] {
        let data = try notice.payload()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testThePayloadSaysWhoAndWhereToGo() throws {
        let notice = PushNotice.job(name: "Engineer", summary: "Worked on “Tidy up”.", fallback: "Engineer finished their work.", route: route)
        let json = try payload(notice)
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title"] as? String, "Engineer")
        XCTAssertEqual(alert["subtitle"] as? String, "Finished")
        XCTAssertEqual(alert["body"] as? String, "Worked on “Tidy up”.")
        XCTAssertEqual(aps["thread-id"] as? String, "engineer")
        XCTAssertEqual(aps["sound"] as? String, "default")
        XCTAssertEqual(aps["interruption-level"] as? String, "active")
        XCTAssertNil(aps["badge"])
        let alife = try XCTUnwrap(json["alife"] as? [String: Any])
        XCTAssertEqual(Set(alife.keys), ["server_id", "session", "conversation", "message", "seq", "kind"])
        XCTAssertEqual(alife["message"] as? String, "9A21")
        XCTAssertEqual(alife["kind"] as? String, "finished")
        XCTAssertEqual(try JSONDecoder().decode(PushRoute.self, from: JSONSerialization.data(withJSONObject: alife)), route)
    }

    func testTheReplyIsNeverInIt() throws {
        let marker = "SECRET-REPLY-7f3a"
        let reply = Message(id: "r1", kind: .agent, speaker: "Engineer", text: "\(marker): I changed README.md and Office.swift, and ran swift test.")
        var watch = JobWatch()
        var ending: JobWatch.Ending?
        let events: [SessionEvent] = [
            .message(Message(kind: .user, speaker: "You", text: "Tidy the README")),
            .statusChanged(.running, stopReason: nil),
            .toolUsed(ToolUse(toolName: "Edit", input: "/a-life/README.md")),
            .toolUsed(ToolUse(toolName: "Bash", input: "swift test \(marker)")),
            .message(reply),
            .statusChanged(.idle, stopReason: .endTurn),
        ]
        for (index, event) in events.enumerated() {
            ending = watch.feed(EventEnvelope(seq: index + 1, event: event, time: Date())) ?? ending
        }
        let ended = try XCTUnwrap(ending)
        let route = PushRoute(serverID: "6B0E", session: "engineer", conversation: nil, message: ended.messageID, seq: ended.seq, kind: ended.kind)
        let notice = PushNotice.job(
            name: "Engineer",
            summary: JobSummary.body(of: ended.record, duration: ended.duration, kind: ended.kind, name: "Engineer"),
            fallback: JobSummary.fallback(kind: ended.kind, name: "Engineer"),
            route: route
        )
        let text = String(decoding: try notice.payload(), as: UTF8.self)
        XCTAssertFalse(text.contains(marker), text) // neither the reply nor the command
        XCTAssertFalse(text.contains("swift test"), text)
        XCTAssertTrue(notice.body.contains("README.md"), notice.body)
        XCTAssertEqual(notice.route?.message, "r1")
    }

    func testItStaysUnderAppleLimit() throws {
        let record = JobRecord(
            task: String(repeating: "Ünïcödé wörds ", count: 1000), startedAt: nil,
            filesChanged: (1...500).map { "/\(String(repeating: "dïr/", count: 50))\($0)-\(String(repeating: "ñ", count: 200)).swift" },
            commands: 1000, helpers: 1000
        )
        let summary = JobSummary.body(of: record, duration: 9 * 3600, kind: .finished, name: "Engineer")
        let notice = PushNotice.job(name: "Engineer", summary: summary, fallback: "Engineer finished their work.", route: route)
        XCTAssertLessThanOrEqual(try notice.payload().count, PushNotice.maxPayloadSize)
        XCTAssertLessThanOrEqual(notice.body.count, JobSummary.maxLength)

        // Anything too big for Apple goes as the fallback.
        let tooBig = PushNotice.job(name: "Engineer", summary: String(repeating: "x", count: 5000), fallback: "Engineer finished their work.", route: route)
        XCTAssertEqual(tooBig.body, "Engineer finished their work.")
    }

    func testTheTestNotificationPointsNowhere() throws {
        let json = try payload(.test)
        XCTAssertNil(json["alife"])
        XCTAssertEqual(((json["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String, "a*life can reach you.")
    }
}

// MARK: The devices

final class DeviceRegistryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("devices.json") }
    private let token = String(repeating: "a1b2c3d4", count: 8)
    private let phone = DeviceRegistrationRequest(environment: .sandbox, bundleID: "dev.neoneon.alife", name: "iPhone")

    func testRegistersUpdatesAndUnregisters() async {
        let registry = DeviceRegistry(file: nil)
        let first = Date(timeIntervalSince1970: 1_000)
        await registry.register(token: token.uppercased(), phone, now: first)
        var all = await registry.all
        XCTAssertEqual(all.map { $0.token }, [token])
        XCTAssertEqual(all.first?.registeredAt, first)

        // Again, as on every launch: the same device, seen again.
        let later = first.addingTimeInterval(3600)
        await registry.register(token: token, DeviceRegistrationRequest(environment: .production, bundleID: "dev.neoneon.alife", name: "iPhone"), now: later)
        all = await registry.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.registeredAt, first)
        XCTAssertEqual(all.first?.lastSeen, later)
        XCTAssertEqual(all.first?.environment, .production)

        await registry.unregister(token: token)
        await registry.unregister(token: token) // and again, which is fine
        all = await registry.all
        XCTAssertTrue(all.isEmpty)
    }

    func testKeepsThemAcrossARestartWithTheSameServerID() async throws {
        let registry = DeviceRegistry(file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) // nothing to keep yet
        await registry.register(token: token, phone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let restarted = DeviceRegistry(file: file)
        let serverID = await registry.serverID
        let restartedID = await restarted.serverID
        XCTAssertEqual(restartedID, serverID)
        let all = await restarted.all
        XCTAssertEqual(all.map { $0.token }, [token])
        XCTAssertEqual(all.first?.name, "iPhone")
        XCTAssertEqual(all.first?.bundleID, "dev.neoneon.alife")

        await restarted.drop(token: token)
        let again = DeviceRegistry(file: file)
        let none = await again.all
        XCTAssertTrue(none.isEmpty)
        let againID = await again.serverID
        XCTAssertEqual(againID, serverID)
    }

    func testForgetsDevicesNotSeenFor90Days() async {
        let now = Date()
        let registry = DeviceRegistry(file: file)
        await registry.register(token: token, phone, now: now.addingTimeInterval(-91 * 24 * 3600))
        await registry.register(token: String(repeating: "ff", count: 32), phone, now: now.addingTimeInterval(-89 * 24 * 3600))

        let later = DeviceRegistry(file: file, now: now)
        let kept = await later.all
        XCTAssertEqual(kept.map { $0.token }, [String(repeating: "ff", count: 32)])
        // And the file says so.
        let reread = await DeviceRegistry(file: file, now: now.addingTimeInterval(-100 * 24 * 3600)).all
        XCTAssertEqual(reread.count, 1)
    }

    func testWithoutAFileTheServerIDIsNewEachTime() async {
        let one = await DeviceRegistry(file: nil).serverID
        let another = await DeviceRegistry(file: nil).serverID
        XCTAssertNotEqual(one, another)
    }

    func testTellsATokenFromAnythingElse() {
        XCTAssertTrue(DeviceRegistry.isToken(token))
        XCTAssertTrue(DeviceRegistry.isToken(token.uppercased()))
        XCTAssertFalse(DeviceRegistry.isToken("not-a-token"))
        XCTAssertFalse(DeviceRegistry.isToken("abc")) // half a byte, and too short
        XCTAssertFalse(DeviceRegistry.isToken(String(repeating: "zz", count: 32)))
    }
}

// MARK: The settings

final class PushSettingsTests: XCTestCase {
    func testNoneSetIsOffWithoutAWord() {
        let settings = PushSettings.read(from: [:])
        XCTAssertNil(settings.credentials)
        XCTAssertNil(settings.problem)
        XCTAssertNil(settings.topic)
    }

    func testSomeSetSaysWhichAreMissing() {
        let settings = PushSettings.read(from: ["ALIFE_APNS_KEY_ID": "ABC1234567", "ALIFE_APNS_TOPIC": "dev.neoneon.alife"])
        XCTAssertNil(settings.credentials)
        XCTAssertEqual(settings.topic, "dev.neoneon.alife")
        XCTAssertEqual(
            settings.problem,
            "Push notifications are off: ALIFE_APNS_KEY_FILE and ALIFE_APNS_TEAM_ID aren't set. See Push notifications in the README."
        )
    }

    func testAllSetIsOn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("AuthKey_ABC1234567.p8")
        let key = P256.Signing.PrivateKey().pemRepresentation
        try key.write(to: keyFile, atomically: true, encoding: .utf8)
        var environment = [
            "ALIFE_APNS_KEY_FILE": keyFile.path,
            "ALIFE_APNS_KEY_ID": "ABC1234567",
            "ALIFE_APNS_TEAM_ID": "TEAM123456",
            "ALIFE_APNS_TOPIC": "dev.neoneon.alife",
        ]
        let settings = PushSettings.read(from: environment)
        XCTAssertNil(settings.problem)
        XCTAssertEqual(
            settings.credentials,
            PushSettings.Credentials(key: key, keyID: "ABC1234567", teamID: "TEAM123456", topic: "dev.neoneon.alife")
        )

        // A key that isn't one keeps them off, and says so.
        try "not a key".write(to: keyFile, atomically: true, encoding: .utf8)
        let broken = PushSettings.read(from: environment)
        XCTAssertNil(broken.credentials)
        XCTAssertTrue(broken.problem?.contains("couldn't read the key") == true, broken.problem ?? "")

        environment["ALIFE_APNS_KEY_FILE"] = directory.appendingPathComponent("missing.p8").path
        XCTAssertNil(PushSettings.read(from: environment).credentials)
    }
}

// MARK: The routes, and the dummies end to end

@MainActor
final class PushRoutesTests: XCTestCase {
    private var app: Application!
    private var baseURL: URL!
    private let sender = RecordingPushSender()
    private let token = String(repeating: "a1b2c3d4", count: 8)
    private let otherToken = String(repeating: "0f1e2d3c", count: 8)
    private let phone = DeviceRegistrationRequest(environment: .sandbox, bundleID: "dev.neoneon.alife", name: "iPhone")

    override func tearDown() async throws {
        try await app?.asyncShutdown()
    }

    private func start(push: PushSetup?) async throws {
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        try await configure(app, players: .dummies(step: .milliseconds(20)), cast: [.birdwatcher, .builder], push: push)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0 // any free port
        try await app.startup()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }

    private var client: ALifeServerClient {
        ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
    }

    /// The status and body of a request to `path` with `body`.
    private func ask(_ method: String, _ path: String, _ body: String? = nil) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let met = await condition()
        XCTAssertTrue(met, "timed out waiting for \(description)", file: file, line: line)
    }

    func testRegistersAndForgetsADevice() async throws {
        try await start(push: PushSetup(sender: sender, topic: "dev.neoneon.alife"))
        let registration = try await client.registerDevice(token: token, phone)
        XCTAssertTrue(registration.pushEnabled)
        XCTAssertFalse(registration.serverID.isEmpty)
        // Again, as on every launch: the same server.
        let again = try await client.registerDevice(token: token.uppercased(), phone)
        XCTAssertEqual(again.serverID, registration.serverID)

        // The test notification.
        try await client.sendTestNotification(token: token)
        let sent = await sender.sent
        XCTAssertEqual(sent.map { $0.token }, [token])
        XCTAssertEqual(sent.first?.notice, .test)

        try await client.unregisterDevice(token: token)
        try await client.unregisterDevice(token: token) // not registered, which is fine
        let test = try await ask("POST", "/v1/devices/\(token)/test")
        XCTAssertEqual(test.status, 404)
    }

    func testRefusesWhatIsntADeviceOfThisApp() async throws {
        try await start(push: PushSetup(sender: sender, topic: "dev.neoneon.alife"))
        let notHex = try await ask("PUT", "/v1/devices/not-a-token", #"{"environment":"sandbox","bundle_id":"dev.neoneon.alife"}"#)
        XCTAssertEqual(notHex.status, 400)
        let staging = try await ask("PUT", "/v1/devices/\(token)", #"{"environment":"staging","bundle_id":"dev.neoneon.alife"}"#)
        XCTAssertEqual(staging.status, 400)
        let otherApp = try await ask("PUT", "/v1/devices/\(token)", #"{"environment":"sandbox","bundle_id":"com.someone.else"}"#)
        XCTAssertEqual(otherApp.status, 400)
        XCTAssertTrue(otherApp.body.contains("dev.neoneon.alife"), otherApp.body)
    }

    func testWithoutTheSettingsDevicesRegisterButNothingIsSent() async throws {
        try await start(push: nil)
        let registration = try await client.registerDevice(token: token, phone)
        XCTAssertFalse(registration.pushEnabled)
        let test = try await ask("POST", "/v1/devices/\(token)/test")
        XCTAssertEqual(test.status, 503)
    }

    func testAFinishedJobIsToldToEveryDevice() async throws {
        try await start(push: PushSetup(sender: sender, topic: "dev.neoneon.alife"))
        let registration = try await client.registerDevice(token: token, phone)
        _ = try await client.registerDevice(token: otherToken, phone)
        // Apple will say this one is gone.
        await sender.answer(.goneForGood, for: otherToken)

        try await client.sendMessage("Look for snails", to: "birdwatcher")
        await eventually("a notification to each device") { await self.sender.sent.count == 2 }
        let sent = await sender.sent
        XCTAssertEqual(Set(sent.map { $0.token }), [token, otherToken])
        let notice = try XCTUnwrap(sent.first?.notice)
        XCTAssertEqual(notice.title, "Birdwatcher")
        XCTAssertEqual(notice.subtitle, "Finished")
        XCTAssertEqual(notice.body, "Worked on “Look for snails” for under a minute: sent 2 helpers.")
        XCTAssertEqual(notice.threadID, "birdwatcher")
        let state = try await client.state(of: "birdwatcher")
        let reply = try XCTUnwrap(state.messages.last)
        XCTAssertFalse(String(decoding: try notice.payload(), as: UTF8.self).contains("Had a look around")) // the reply's text
        XCTAssertEqual(notice.route, PushRoute(
            serverID: registration.serverID, session: "birdwatcher", conversation: state.conversationID,
            message: reply.id, seq: try XCTUnwrap(notice.route?.seq), kind: .finished
        ))

        // The device Apple said was gone is forgotten; the other is told of
        // the next job.
        try await Task.sleep(nanoseconds: 200_000_000)
        try await client.sendMessage("And for slugs", to: "birdwatcher")
        await eventually("the next notification") { await self.sender.sent.count >= 3 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let next = await sender.sent.dropFirst(2).map { $0.token }
        XCTAssertEqual(next, [token])
        let lastBody = await sender.sent.last?.notice.body
        XCTAssertEqual(lastBody, "Worked on “And for slugs” for under a minute: sent 2 helpers.")

        // Stopping a character isn't the end of its work.
        let before = await sender.sent.count
        try await client.sendMessage("Tidy the lot", to: "builder")
        await eventually("the Builder to ask") { (try? await self.client.state(of: "builder").stopReason) == .requiresAction }
        try await client.interrupt("builder")
        await eventually("the Builder to stop") { (try? await self.client.state(of: "builder").stopReason) == .interrupted }
        try await Task.sleep(nanoseconds: 200_000_000)
        let after = await sender.sent.count
        XCTAssertEqual(after, before)
    }
}
