import ALifeAPI
import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The model each character runs on: the agents file's, switched in a front
/// end's model picker, at once with `set_model` or from its next start, kept
/// in `models.json`, and the versions the simple names stand for. The lines
/// the stand-in CLI writes are trimmed from what Claude Code 2.1.323 wrote
/// in a captured run.
final class ModelTests: XCTestCase {
    private func make(
        _ character: Character = .builder,
        choices: ModelChoices = ModelChoices(file: nil),
        models: ModelCatalog = ModelCatalog()
    ) async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let model = await choices.model(for: character)
        let hub = SessionHub(id: character.id, name: character.name, model: model, fileModel: character.model)
        let claudeCode = FakeClaudeCode()
        let backend = ClaudeCharacter(
            character, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"),
            model: model, choices: choices, models: models
        )
        await backend.reset()
        return (backend, hub, claudeCode)
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

    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    private func model(in arguments: [String]) -> String? {
        arguments.firstIndex(of: "--model").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// The control requests of `subtype` sent to `cli`, in order.
    private func requests(_ subtype: String, to cli: FakeClaudeCLI) -> [JSONValue] {
        cli.sent.filter { $0["type"]?.string == "control_request" && $0["request"]?["subtype"]?.string == subtype }
    }

    // MARK: The CLI's lines

    /// The answer to `initialize`, with the models as Claude Code 2.1.323
    /// listed them.
    private func initialized(_ id: String) -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks"},{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work and everyday tasks"},{"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5","description":"Most efficient for simpler tasks"},{"value":"fable","resolvedModel":"claude-fable-5-2","displayName":"Fable 5.2","description":"For your toughest challenges"},{"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","description":"Fastest for quick answers"},{"value":"claude-opus-4-8","resolvedModel":"claude-opus-4-8","displayName":"Opus 4.8","description":"Best for everyday, complex tasks"}]}}}"#
    }

    private let started = #"{"type":"system","subtype":"init","session_id":"session-1","model":"claude-haiku-5-5","tools":["Agent","Bash","Read","Write"]}"#

    private func switched(_ id: String, to model: String) -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"model":"\#(model)"}}}"#
    }

    private func refused(_ id: String) -> String {
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"Model 'fable' not found"}}"#
    }

    private let asksToWrite = #"{"type":"control_request","request_id":"request-write","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/lot/buildings/office.md","content":"An office"},"description":"buildings/office.md","tool_use_id":"toolu_write"}}"#

    // MARK: Starting on the agents file's model

    func testACharacterStartsOnItsModelAndKeepsItWhenResumed() async throws {
        let (builder, hub, claudeCode) = await make()
        let state = await hub.state
        XCTAssertEqual(state.model, .haiku)
        XCTAssertEqual(state.fileModel, .haiku)

        try await builder.handleMessage("Build me a shed")
        XCTAssertEqual(model(in: try XCTUnwrap(claudeCode.launches.first)), "haiku")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.exit()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await builder.handleMessage("And a fence")
        let resumed = try XCTUnwrap(claudeCode.launches.last)
        XCTAssertEqual(claudeCode.launches.count, 2)
        XCTAssertEqual(model(in: resumed), "haiku")
        XCTAssertTrue(resumed.contains("--resume"))
    }

    func testACharacterWithoutAModelRunsOnClaudeCodesDefault() async throws {
        let (birdwatcher, hub, claudeCode) = await make(.birdwatcher)
        let state = await hub.state
        XCTAssertNil(state.model)
        try await birdwatcher.handleMessage("Look for robins")
        XCTAssertNil(model(in: try XCTUnwrap(claudeCode.launches.first)))
    }

    // MARK: Switching

    func testSwitchingWhileItRunsTellsClaudeCodeAtOnce() async throws {
        let choices = ModelChoices(file: nil)
        let (builder, hub, claudeCode) = await make(choices: choices)
        try await builder.handleMessage("Build me a shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        await until(hub, "the model it started on") { $0.context?.model == "claude-haiku-5-5" }

        try await builder.setModel(.opus)
        var state = await hub.state
        XCTAssertEqual(state.model, .opus)
        XCTAssertEqual(state.fileModel, .haiku)
        let request = try XCTUnwrap(requests("set_model", to: cli).last)
        XCTAssertEqual(request["request"]?["model"], "opus")
        let entry = await choices.all["builder"]
        XCTAssertEqual(entry, ModelChoices.Entry(model: .opus, fileModel: .haiku))

        // Claude Code says what it runs on now, as a full id, for the ring.
        cli.say(switched(try XCTUnwrap(request["request_id"]?.string), to: "claude-opus-5-5"))
        state = await until(hub, "the new model's id") { $0.context?.model == "claude-opus-5-5" }
        XCTAssertEqual(state.context?.modelName, "Opus 5.5")
        XCTAssertEqual(claudeCode.launches.count, 1) // the same session goes on

        // Going back to the agents file's forgets the choice.
        try await builder.setModel(nil)
        state = await hub.state
        XCTAssertEqual(state.model, .haiku)
        XCTAssertEqual(requests("set_model", to: cli).last?["request"]?["model"], "haiku")
        let all = await choices.all
        XCTAssertTrue(all.isEmpty)
    }

    func testASwitchClaudeCodeRefusesGoesBackAndSaysWhy() async throws {
        let choices = ModelChoices(file: nil)
        let (builder, hub, claudeCode) = await make(choices: choices)
        try await builder.handleMessage("Build me a shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        try await builder.setModel(.fable)
        let request = try XCTUnwrap(requests("set_model", to: cli).last)
        cli.say(refused(try XCTUnwrap(request["request_id"]?.string)))
        let state = await until(hub, "the switch undone") { $0.model == .haiku }
        XCTAssertEqual(state.messages.last?.kind, .error)
        XCTAssertEqual(state.messages.last?.text, "Couldn't switch Builder to Fable: Model 'fable' not found")
        let all = await choices.all
        XCTAssertTrue(all.isEmpty)
    }

    func testSwitchingWhileItIsntRunningTakesEffectWhenItStarts() async throws {
        let models = ModelCatalog()
        let (builder, hub, claudeCode) = await make(models: models)
        try await builder.setModel(.sonnet)
        XCTAssertTrue(claudeCode.launches.isEmpty) // nothing is started for it
        var state = await hub.state
        XCTAssertEqual(state.model, .sonnet)
        XCTAssertNil(state.context) // not started: the app shows the model it will run on

        try await builder.handleMessage("Build me a shed")
        XCTAssertEqual(model(in: try XCTUnwrap(claudeCode.launches.last)), "sonnet")
        // Its Claude Code says which versions there are, in answer to initialize.
        let cli = try XCTUnwrap(claudeCode.clis.last)
        let initialize = try XCTUnwrap(requests("initialize", to: cli).first?["request_id"]?.string)
        cli.say(initialized(initialize))
        cli.say(started.replacingOccurrences(of: "haiku", with: "sonnet"))
        await until(hub, "the model it started on") { $0.context?.model == "claude-sonnet-5-5" }
        let options = await models.options
        XCTAssertEqual(options.map(\.displayName), ["Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])

        // Once it has stopped, the ring shows the next model straight away.
        cli.exit()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await builder.setModel(.opus)
        state = await until(hub, "the next model's id") { $0.context?.model == "claude-opus-5-5" }
        XCTAssertEqual(state.model, .opus)
        try await builder.handleMessage("And a fence")
        XCTAssertEqual(model(in: try XCTUnwrap(claudeCode.launches.last)), "opus")
    }

    func testStartingOverKeepsTheModel() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.setModel(.opus)
        await builder.reset()
        let state = await hub.state
        XCTAssertEqual(state.model, .opus)
        XCTAssertEqual(state.fileModel, .haiku)
        XCTAssertTrue(state.messages.isEmpty)
        try await builder.handleMessage("Build me a shed")
        XCTAssertEqual(model(in: try XCTUnwrap(claudeCode.launches.last)), "opus")
    }

    func testTheModelCanBeSwitchedWhileItWaitsForYou() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me a shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(asksToWrite)
        await until(hub, "the approval") { !$0.approvals.isEmpty }
        try await builder.setModel(.sonnet)
        let state = await hub.state
        XCTAssertEqual(state.model, .sonnet)
        XCTAssertEqual(state.approvals.map(\.id), ["request-write"]) // still waiting for you
        XCTAssertEqual(requests("set_model", to: cli).last?["request"]?["model"], "sonnet")
    }

    // MARK: Kept across restarts

    func testAChoiceOutlastsARestartUntilTheAgentsFileChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json")

        let choices = ModelChoices(file: file)
        await choices.choose(.opus, for: .builder)
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(written, "{\n  \"builder\" : {\n    \"file_model\" : \"haiku\",\n    \"model\" : \"opus\"\n  }\n}")

        // After a restart, the Builder runs on Opus again.
        var model = await ModelChoices(file: file).model(for: .builder)
        XCTAssertEqual(model, .opus)

        // Until the agents file gives it another model: the newer word.
        let rebuilt = try XCTUnwrap(Cast.decode("""
            agents:
              - id: builder
                name: Builder
                model: sonnet
                role: You build.
                helper: {name: worker, tools: [Read], description: Builds., prompt: You build.}
            """, from: "agents.yaml").first)
        let restarted = ModelChoices(file: file)
        model = await restarted.model(for: rebuilt)
        XCTAssertEqual(model, .sonnet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Choosing the agents file's own, or going back to it, keeps nothing.
        await restarted.choose(.sonnet, for: rebuilt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await restarted.choose(.fable, for: rebuilt)
        await restarted.choose(nil, for: rebuilt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: The versions

    func testTheVersionsAreAskedOfAClaudeCodeWithNothingToDo() async throws {
        let claudeCode = FakeClaudeCode()
        let asking = Task { await ModelCatalog.initializeAnswer(from: claudeCode, patience: .seconds(5)) }
        await waitFor("Claude Code to be started") { !claudeCode.clis.isEmpty }
        let cli = try XCTUnwrap(claudeCode.clis.first)
        await waitFor("initialize") { !requests("initialize", to: cli).isEmpty }
        // Only asked, with no prompt and so no turn.
        XCTAssertEqual(cli.sent.count, 1)
        XCTAssertNil(model(in: try XCTUnwrap(claudeCode.launches.first)))
        cli.say(initialized(try XCTUnwrap(requests("initialize", to: cli).first?["request_id"]?.string)))
        let answer = await asking.value
        let models = ModelCatalog()
        await models.learn(from: answer)
        let options = await models.options
        XCTAssertEqual(options, [
            ModelOption(model: .fable, name: "Fable 5.2", description: "For your toughest challenges", resolved: "claude-fable-5-2"),
            ModelOption(model: .opus, name: "Opus 5.5", description: "For complex work and everyday tasks", resolved: "claude-opus-5-5"),
            ModelOption(model: .sonnet, name: "Sonnet 5.5", description: "Most efficient for simpler tasks", resolved: "claude-sonnet-5-5"),
            ModelOption(model: .haiku, name: "Haiku 5.5", description: "Fastest for quick answers", resolved: "claude-haiku-5-5"),
        ])
        XCTAssertTrue(cli.isClosed)
    }

    func testWithoutAnAnswerTheModelsHaveTheirPlainNames() async throws {
        let claudeCode = FakeClaudeCode()
        let answer = await ModelCatalog.initializeAnswer(from: claudeCode, patience: .milliseconds(50))
        XCTAssertNil(answer)
        let models = ModelCatalog()
        await models.learn(from: answer)
        let options = await models.options
        XCTAssertEqual(options.map(\.displayName), ["Fable", "Opus", "Sonnet", "Haiku"])
        XCTAssertEqual(claudeCode.clis.first?.isClosed, true)
    }

    // MARK: The dummies and the front ends

    @MainActor
    func testTheFrontEndsSwitchTheModel() async throws {
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        do {
            try await configure(app, players: .dummies(step: .milliseconds(20)), cast: [.builder, .birdwatcher])
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0 // any free port
            try await app.startup()
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

            let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
            server.connect()
            for _ in 0..<500 where server.phase != .live || server.models.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            // The dummies ask no Claude Code, so the models have their plain names.
            XCTAssertEqual(server.models.map(\.displayName), ["Fable", "Opus", "Sonnet", "Haiku"])
            let builder = try XCTUnwrap(server.session("builder"))
            let birdwatcher = try XCTUnwrap(server.session("birdwatcher"))
            XCTAssertEqual(builder.model, .haiku)
            XCTAssertEqual(builder.fileModel, .haiku)
            XCTAssertNil(birdwatcher.model)
            XCTAssertEqual(builder.modelName(among: server.models), "Haiku") // before it has started
            XCTAssertEqual(birdwatcher.modelName(among: server.models), "Default model")

            await builder.setModel(.opus)
            XCTAssertNil(builder.lastError)
            let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
            var snapshot = try await client.state(of: "builder")
            XCTAssertEqual(snapshot.model, .opus)
            XCTAssertEqual(snapshot.fileModel, .haiku)

            // Starting over keeps it, in every front end.
            await builder.startOver()
            for _ in 0..<300 where builder.state.messages.isEmpty == false || builder.model != .opus {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            snapshot = try await client.state(of: "builder")
            XCTAssertEqual(snapshot.model, .opus)
            XCTAssertEqual(builder.model, .opus)

            // A name the server doesn't know is refused.
            var request = URLRequest(url: baseURL.appendingPathComponent("/v1/sessions/builder/model"))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"model":"opus-5"}"#.utf8)
            let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("isn't one of the models a character can run on"), String(decoding: body, as: UTF8.self))

            // Back to the agents file's.
            await builder.setModel(nil)
            snapshot = try await client.state(of: "builder")
            XCTAssertEqual(snapshot.model, .haiku)
            server.disconnect()
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
