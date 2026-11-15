import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The agents file: the one the server ships with, what an agent can leave
/// out, how mistakes in it are reported, and a server with a cast of its own.
final class CastTests: XCTestCase {
    /// One agent, with every field.
    private let painter = """
        agents:
          - id: painter
            name: Painter
            color: "#3366CC"
            permission_mode: acceptEdits
            works_in: a-life
            changes_things: true
            role: |
              You are the Painter.

              You paint the house.
            helper:
              name: brush
              tools: [Read, Edit]
              description: Paints walls.
              prompt: |
                You paint walls.
        """

    /// The painter file with `old` replaced by `new`.
    private func amended(replacing old: String, with new: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(painter.contains(old), "the painter file has no \(old)", file: file, line: line)
        return painter.replacingOccurrences(of: old, with: new)
    }

    // MARK: The shipped file

    func testTheShippedFileHasTheGardenerTheBuilderAndTheEngineer() throws {
        let cast = try Cast.load(contentsOf: Cast.shippedFile)
        XCTAssertEqual(cast.map(\.id), ["gardener", "builder", "engineer"])
        XCTAssertEqual(cast.map(\.name), ["Gardener", "Builder", "Engineer"])
        XCTAssertEqual(cast.map(\.color), ["#D9594D", "#F2A633", "#8050C8"])
        XCTAssertEqual(cast.map(\.permissionMode), ["acceptEdits", "default", "default"])
        // The Engineer works on a*life itself, in its checkout.
        XCTAssertEqual(cast.map(\.workspace), [.lot, .lot, .aLife])
        XCTAssertEqual(cast.map(\.changesThings), [false, true, true])
        XCTAssertEqual(cast.map(\.helper.name), ["planter", "construction-worker", "a-life-expert"])
        XCTAssertEqual(cast.map(\.helper.tools), [
            ["Read", "Glob", "Grep", "Write", "Edit"],
            ["Read", "Glob", "Grep", "Write", "Edit"],
            ["Read", "Glob", "Grep", "Write", "Edit", "Bash"],
        ])

        for character in cast {
            XCTAssertTrue(character.role.hasPrefix("You are the \(character.name), a character in a*life, a little life sim."))
            // Each paragraph of a role is one line, as Claude Code is given it.
            let paragraphs = character.role.components(separatedBy: "\n\n")
            XCTAssertFalse(paragraphs.contains { $0.isEmpty || $0.contains("\n") }, "\(character.name)'s role")
            XCTAssertTrue(character.helper.prompt.hasPrefix("You are the \(character.name)'s "))
            XCTAssertFalse(character.helper.description.isEmpty)
        }

        // The lines a helper writes at the top of a file keep their lines.
        XCTAssertTrue(Character.gardener.helper.prompt.contains("garden/rose-bed.md, starting with these lines, which put it on the lot:\n\n---\nkind: rose\ncolor: red\n"))
        XCTAssertTrue(Character.builder.helper.prompt.contains("\n---\nkind: restaurant\nx: 38\ny: 22\nwidth: 5\ndepth: 4\n---\n"))

        // The Engineer sends its a*life expert for any change to a*life, and
        // the expert knows its way around the app, the package and the server.
        XCTAssertTrue(Character.engineer.helper.description.contains("Use it whenever a*life is to be changed."))
        let expert = Character.engineer.helper.prompt
        for part in ["ALife/", "ALifeKit/", "a-life-server/", "World.swift", "SheepSystem.swift", "Buildings.swift", "Plants.swift", "ClaudeCharacter.swift", "LotSurvey.swift", "LotHub.swift", "agents.yaml"] {
            XCTAssertTrue(expert.contains(part), "the a*life expert doesn't know \(part)")
        }
        XCTAssertTrue(expert.contains("\n1. Run git status first."))
        XCTAssertTrue(expert.contains("swift test --package-path a-life-server"))
        XCTAssertFalse(expert.contains("--cloud"))
    }

    // MARK: What a file says

    func testEveryFieldIsRead() throws {
        let cast = try Cast.decode(painter, from: "agents.yaml")
        XCTAssertEqual(cast, [
            Character(
                id: "painter",
                name: "Painter",
                color: "#3366CC",
                changesThings: true,
                permissionMode: "acceptEdits",
                workspace: .aLife,
                // Without the line break a YAML block ends with.
                role: "You are the Painter.\n\nYou paint the house.",
                helper: Helper(name: "brush", description: "Paints walls.", prompt: "You paint walls.", tools: ["Read", "Edit"])
            ),
        ])
    }

    func testAnAgentCanLeaveOutItsColourPermissionModeWorkspaceAndWhetherItChangesThings() throws {
        let yaml = """
            agents:
              - id: painter
                name: Painter
                role: You paint the house.
                helper: {name: brush, tools: [Read], description: Paints walls., prompt: You paint walls.}
            """
        let painter = try XCTUnwrap(Cast.decode(yaml, from: "agents.yaml").first)
        XCTAssertNil(painter.color) // the front ends choose one
        XCTAssertEqual(painter.permissionMode, "default") // asks before every change
        XCTAssertEqual(painter.workspace, .lot)
        XCTAssertFalse(painter.changesThings)
    }

    func testTheAgentsAreInTheFilesOrder() throws {
        let yaml = painter + """

              - id: plumber
                name: Plumber
                role: You fix the pipes.
                helper: {name: wrench, tools: [Read], description: Fixes pipes., prompt: You fix pipes.}
            """
        XCTAssertEqual(try Cast.decode(yaml, from: "agents.yaml").map(\.id), ["painter", "plumber"])
    }

    // MARK: Mistakes

    func testMistakesAreRefusedSayingWhereTheyAre() {
        let mistakes: [(file: String, error: String)] = [
            ("", "agents.yaml is empty. It should list the agents under agents:."),
            ("agents: []", "agents.yaml: agents is empty. There has to be at least one agent."),
            ("agents:", "agents.yaml: agents should be a list."),
            ("- id: painter", "agents.yaml: the file should be a set of fields."),
            (
                amended(replacing: "agents:", with: "agent:"),
                "agents.yaml: agent isn't a field of the file. The field is agents."
            ),
            (
                amended(replacing: "    name: Painter\n", with: ""),
                "agents.yaml: agents[0].name is missing."
            ),
            (
                amended(replacing: "    name: Painter", with: "    name: \"  \""),
                "agents.yaml: agents[0].name is empty."
            ),
            (
                amended(replacing: "color:", with: "colour:"),
                "agents.yaml: agents[0].colour isn't a field of an agent. The fields are id, name, color, permission_mode, works_in, changes_things, role and helper."
            ),
            (
                amended(replacing: "\"#3366CC\"", with: "purple"),
                "agents.yaml: agents[0].color should be a colour like \"#8050C8\", not \"purple\"."
            ),
            (
                amended(replacing: "\"#3366CC\"", with: "#3366CC"),
                "agents.yaml: agents[0].color is empty. Leave it out, or give it a value; one that starts with # needs quotes."
            ),
            (
                amended(replacing: "id: painter", with: "id: The Painter"),
                "agents.yaml: agents[0].id \"The Painter\" won't do. An id has only lowercase letters, digits and hyphens, such as \"gardener\"."
            ),
            (
                painter + "\n  - id: painter\n    name: Another\n    role: Again.\n    helper: {name: roller, tools: [Read], description: Rolls., prompt: Roll.}",
                "agents.yaml: agents[1].id \"painter\" is agents[0]'s id too. Each agent needs an id of its own."
            ),
            (
                amended(replacing: "permission_mode: acceptEdits", with: "permission_mode: ask"),
                "agents.yaml: agents[0].permission_mode \"ask\" isn't one of Claude Code's permission modes: default, manual, acceptEdits, plan, auto, dontAsk, bypassPermissions."
            ),
            (
                amended(replacing: "works_in: a-life", with: "works_in: garden"),
                "agents.yaml: agents[0].works_in \"garden\" isn't somewhere a character can work. It can be lot, the lot the characters share, or a-life, a checkout of the a*life repository."
            ),
            (
                amended(replacing: "changes_things: true", with: "changes_things: sometimes"),
                "agents.yaml: agents[0].changes_things should be true or false."
            ),
            (
                amended(replacing: "    role: |\n      You are the Painter.\n\n      You paint the house.\n", with: "    role: [paint, the, house]\n"),
                "agents.yaml: agents[0].role should be a single value, not a list or a set of fields."
            ),
            (
                amended(replacing: "name: brush", with: "name: Big Brush"),
                "agents.yaml: agents[0].helper.name \"Big Brush\" won't do. A helper's name has only lowercase letters, digits and hyphens, such as \"construction-worker\"."
            ),
            (
                amended(replacing: "tools: [Read, Edit]", with: "tools: []"),
                "agents.yaml: agents[0].helper.tools is empty. A helper needs at least one tool, such as Read."
            ),
            (
                amended(replacing: "tools: [Read, Edit]", with: "tools: [Read, \"\"]"),
                "agents.yaml: agents[0].helper.tools[1] is empty."
            ),
            (
                amended(replacing: "tools: [Read, Edit]", with: "tools: Read"),
                "agents.yaml: agents[0].helper.tools should be a list."
            ),
            (
                amended(replacing: "      prompt: |\n        You paint walls.", with: ""),
                "agents.yaml: agents[0].helper.prompt is missing."
            ),
            (
                amended(replacing: "description: Paints walls.", with: "descripton: Paints walls."),
                "agents.yaml: agents[0].helper.descripton isn't a field of a helper. The fields are name, tools, description and prompt."
            ),
        ]
        for mistake in mistakes {
            XCTAssertThrowsError(try Cast.decode(mistake.file, from: "agents.yaml"), mistake.error) { error in
                XCTAssertEqual("\(error)", mistake.error)
            }
        }
    }

    func testYAMLThatDoesntParseSaysWhere() {
        let broken = amended(replacing: "name: Painter", with: "name: Painter: the first")
        XCTAssertThrowsError(try Cast.decode(broken, from: "agents.yaml")) { error in
            let message = "\(error)"
            XCTAssertTrue(message.hasPrefix("agents.yaml isn't valid YAML: "), message)
            XCTAssertTrue(message.contains("3:"), "names the line: \(message)")
        }
    }

    // MARK: Which file

    func testALIFE_AGENTS_FILEChoosesTheFile() throws {
        XCTAssertEqual(Cast.file(in: [:]), Cast.shippedFile)
        XCTAssertEqual(Cast.file(in: ["ALIFE_AGENTS_FILE": ""]), Cast.shippedFile)
        XCTAssertEqual(
            Cast.file(in: ["ALIFE_AGENTS_FILE": "~/lot/agents.yaml"]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("lot/agents.yaml").path
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("my-agents.yaml")
        try painter.write(to: file, atomically: true, encoding: .utf8)

        let chosen = Cast.file(in: ["ALIFE_AGENTS_FILE": file.path])
        XCTAssertEqual(chosen, file)
        XCTAssertEqual(try Cast.load(contentsOf: chosen).map(\.name), ["Painter"])

        // Errors name the file.
        try "agents: []".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Cast.load(contentsOf: file)) { error in
            XCTAssertEqual("\(error)", "\(file.path): agents is empty. There has to be at least one agent.")
        }
        let missing = directory.appendingPathComponent("nobody.yaml")
        XCTAssertThrowsError(try Cast.load(contentsOf: missing)) { error in
            XCTAssertTrue("\(error)".hasPrefix("Couldn't read the agents file \(missing.path): "), "\(error)")
        }
    }

    // MARK: The server

    func testTheServerHasASessionForEachAgentInTheFile() async throws {
        let cast = try Cast.decode(painter + """

              - id: plumber
                name: Plumber
                role: You fix the pipes.
                helper: {name: wrench, tools: [Read], description: Fixes pipes., prompt: You fix pipes.}
            """, from: "agents.yaml")

        let app = try await Application.make(.testing)
        do {
            try await configure(app, players: .dummies(step: .milliseconds(20)), cast: cast)
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0 // any free port
            try await app.startup()
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let client = ALifeServerClient(
                baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
                urlSession: URLSession(configuration: .ephemeral)
            )

            let sessions = try await client.sessions()
            XCTAssertEqual(sessions.map(\.id), ["painter", "plumber"])
            XCTAssertEqual(sessions.map(\.name), ["Painter", "Plumber"])
            XCTAssertEqual(sessions.map(\.color), ["#3366CC", nil])
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
