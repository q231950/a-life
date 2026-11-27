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
            model: opus
            works_in: a-life
            changes_things: true
            role: |
              You are the Painter.

              You paint the house.
            helper:
              name: brush
              tools: [Read, Edit]
              model: haiku
              description: Paints walls.
              prompt: |
                You paint walls.
        """

    /// The painter file with `old` replaced by `new`.
    private func amended(replacing old: String, with new: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(painter.contains(old), "the painter file has no \(old)", file: file, line: line)
        return painter.replacingOccurrences(of: old, with: new)
    }

    // MARK: The built-in agents

    func testTheBuiltInAgentsAreTheBuilderTheALifeEngineerTheTeamLeadAndTheConservationist() throws {
        let cast = Cast.builtIn
        XCTAssertEqual(cast.map(\.id), ["builder", "engineer", "team-lead", "conservationist"])
        // The Engineer was renamed, and kept its id, so that its saved
        // session, its model and the front ends' references still match.
        XCTAssertEqual(cast.map(\.name), ["Builder", "a*life Engineer", "Team Lead", "Conservationist"])
        XCTAssertEqual(cast.map(\.color), ["#F2A633", "#8050C8", "#2A9D8F", "#228B22"])
        XCTAssertEqual(cast.map(\.permissionMode), ["default", "default", "default", "acceptEdits"])
        // The Engineer works on a*life itself, in its checkout.
        XCTAssertEqual(cast.map(\.workspace), [.lot, .aLife, .lot, .lot])
        XCTAssertEqual(cast.map(\.changesThings), [true, true, true, true])
        // Each runs on a model fit for its work, and the helpers on their
        // character's.
        let models: [String: ClaudeModel] = [
            "builder": .haiku, "conservationist": .haiku, "team-lead": .sonnet, "engineer": .opus,
        ]
        for (id, model) in models {
            let character = try XCTUnwrap(cast.first { $0.id == id }, id)
            XCTAssertEqual(character.model, model, id)
            XCTAssertNil(character.helper.model, id)
        }
        XCTAssertEqual(cast.map(\.helper.name), ["construction-worker", "a-life-expert", "recruiter", "keeper"])
        XCTAssertEqual(cast.first { $0.id == "team-lead" }?.helper.tools, [
            // The recruiter changes the added agents with the server's
            // commands, never by writing a file itself.
            "Read", "Glob", "Grep", "Bash",
        ])

        // Every agent has a name and a helper of its own, and a role and
        // helper that say who they are.
        XCTAssertEqual(Set(cast.map(\.id)).count, cast.count)
        XCTAssertEqual(Set(cast.map(\.name)).count, cast.count)
        XCTAssertEqual(Set(cast.map(\.helper.name)).count, cast.count)
        for character in cast {
            XCTAssertTrue(character.role.hasPrefix("You are the \(character.name), a character in a*life, a little life sim."))
            // Each paragraph of a role is one line, as Claude Code is given it.
            let paragraphs = character.role.components(separatedBy: "\n\n")
            XCTAssertFalse(paragraphs.contains { $0.isEmpty || $0.contains("\n") }, "\(character.name)'s role")
            XCTAssertTrue(character.helper.prompt.hasPrefix("You are the \(character.name)'s "), character.name)
            XCTAssertFalse(character.helper.description.isEmpty)
            // The Engineer's name is a*life Engineer wherever it is said.
            XCTAssertFalse(character.role.contains("the Engineer"), character.name)
            XCTAssertFalse(character.helper.prompt.contains("the Engineer"), character.name)
        }

        // The lines a helper writes at the top of a file keep their lines.
        XCTAssertTrue(Character.conservationist.helper.prompt.contains("garden/rose-bed.md, starting with these lines, which put it on the lot:\n\n---\nkind: rose\ncolor: red\n"))
        XCTAssertTrue(Character.builder.helper.prompt.contains("\n---\nkind: restaurant\nx: 38\ny: 22\nwidth: 5\ndepth: 4\n---\n"))

        // The a*life Engineer sends its a*life expert for any change to
        // a*life, and the expert knows its way around the app, the package
        // and the server.
        XCTAssertTrue(Character.engineer.role.hasPrefix("You are the a*life Engineer, a character in a*life"))
        XCTAssertTrue(Character.engineer.helper.description.contains("Use it whenever a*life is to be changed."))
        let expert = Character.engineer.helper.prompt
        for part in ["ALife/", "ALifeKit/", "a-life-server/", "World.swift", "SheepSystem.swift", "Buildings.swift", "Plants.swift", "ClaudeCharacter.swift", "LotSurvey.swift", "LotHub.swift", "agents.yaml"] {
            XCTAssertTrue(expert.contains(part), "the a*life expert doesn't know \(part)")
        }
        XCTAssertTrue(expert.contains("\n1. Run git status first."))
        XCTAssertTrue(expert.contains("swift test --package-path a-life-server"))
        XCTAssertFalse(expert.contains("--cloud"))

        // The Team Lead sends its recruiter to add agents, and leaves the
        // lot's work to the others; the recruiter adds them with the
        // server's command, from what the server tells its session.
        let teamLead = Character.teamLead
        XCTAssertTrue(teamLead.role.contains("`recruiter`"))
        XCTAssertTrue(teamLead.role.contains("leave the lot to the Builder and the Conservationist"))
        XCTAssertTrue(teamLead.helper.description.contains("Use it whenever an agent is to be added"))
        let recruiter = teamLead.helper.prompt
        for part in [
            "cat \"$ALIFE_AGENTS_FILE\" \"$ALIFE_ADDED_AGENTS_FILE\"",
            "\"$ALIFE_SERVER_COMMAND\" add-agent <<'AGENT'\nid: painter\n",
            "Never write or edit either file yourself",
        ] {
            XCTAssertTrue(recruiter.contains(part), "the recruiter doesn't know \(part)")
        }

        // New agents join straight away, with no restart to say anything about.
        XCTAssertTrue(teamLead.role.contains("they join the lot straight away, with no restart"))
        XCTAssertFalse(teamLead.role.contains("once the person restarts the server"))
        XCTAssertTrue(teamLead.helper.description.contains("joins the lot straight away"))
        XCTAssertTrue(recruiter.contains("that they join the lot straight away"))

        // It takes agents away too, but only once the person has said yes
        // to the agent the Team Lead names, only the ones it added, and
        // never the built-in agents or the person's own.
        XCTAssertTrue(teamLead.role.contains("You take away only agents you added."))
        XCTAssertTrue(teamLead.role.contains("ask them first, naming the agent"))
        XCTAssertTrue(teamLead.role.contains("Only once they've clearly said yes"))
        XCTAssertTrue(teamLead.role.contains("You never take away the built-in agents, yourself, the Builder, the Conservationist and the a*life Engineer"))
        XCTAssertTrue(teamLead.role.contains("tell them to take it out of agents.yaml themselves"))
        XCTAssertTrue(teamLead.role.contains("the person edits agents.yaml themselves"))
        XCTAssertTrue(teamLead.helper.description.contains("taken away once the person has said yes"))
        for part in ["the person said yes", "\"$ALIFE_SERVER_COMMAND\" remove-agent painter\n", "\"$ALIFE_SERVER_COMMAND\" remove-agent painter --confirmed\n"] {
            XCTAssertTrue(recruiter.contains(part), "the recruiter doesn't know \(part)")
        }
        XCTAssertEqual(Cast.builtIn.map(\.id).sorted(), ["builder", "conservationist", "engineer", "team-lead"])
    }

    func testTheShippedAgentsFileListsNoAgentsAndKeepsItsExample() throws {
        // It is the person's own file, so it only says how to fill it in.
        XCTAssertEqual(try Cast.load(contentsOf: Cast.shippedFile), [])
        let shipped = try String(contentsOf: Cast.shippedFile, encoding: .utf8)
        XCTAssertTrue(shipped.contains("# - id: app-engineer"))
        XCTAssertFalse(shipped.contains("\n  - id:"), "an active agent")
        XCTAssertTrue(shipped.contains("can't take one away"))
        // The built-in agents aren't in it, and neither is anything the
        // Team Lead adds.
        for id in ["builder", "engineer", "team-lead", "conservationist"] {
            XCTAssertFalse(shipped.contains("id: \(id)"), id)
        }
    }

    // MARK: Adding an agent

    /// The fields of a new agent, the plumber, as the recruiter gives them.
    private let plumber = """
        id: plumber
        name: Plumber
        color: "#2266AA"
        model: sonnet
        role: |
          You are the Plumber.

          You fix the pipes.
        helper:
          name: wrench
          tools: [Read, Edit]
          description: Fixes pipes.
          prompt: |
            You fix pipes.
        """

    func testAnAgentIsAddedAfterTheLastOneLeavingTheOthersAndTheCommentsAsTheyAre() throws {
        let file = """
            # Who is on the lot.
            agents:
              - id: painter
                name: Painter
                role: You paint the house.
                helper: {name: brush, tools: [Read], description: Paints walls., prompt: You paint walls.}

              # Another, to take the #s off:
              # - id: roofer
              #   name: Roofer

            """
        let (text, added) = try Cast.adding(plumber, to: file, from: "agents.yaml")
        XCTAssertEqual(text, """
            # Who is on the lot.
            agents:
              - id: painter
                name: Painter
                role: You paint the house.
                helper: {name: brush, tools: [Read], description: Paints walls., prompt: You paint walls.}

              - id: plumber
                name: Plumber
                color: "#2266AA"
                model: sonnet
                role: |
                  You are the Plumber.

                  You fix the pipes.
                helper:
                  name: wrench
                  tools: [Read, Edit]
                  description: Fixes pipes.
                  prompt: |
                    You fix pipes.

              # Another, to take the #s off:
              # - id: roofer
              #   name: Roofer

            """)
        XCTAssertEqual(added, Character(
            id: "plumber",
            name: "Plumber",
            color: "#2266AA",
            changesThings: false,
            permissionMode: "default",
            model: .sonnet,
            workspace: .lot,
            role: "You are the Plumber.\n\nYou fix the pipes.",
            helper: Helper(name: "wrench", description: "Fixes pipes.", prompt: "You fix pipes.", tools: ["Read", "Edit"], model: nil)
        ))

        // Given as a list item, indented, it is the same agent.
        let asAnItem = "    - " + plumber.replacingOccurrences(of: "\n", with: "\n      ")
        XCTAssertEqual(try Cast.adding(asAnItem, to: file, from: "agents.yaml").text, text)
    }

    func testAnAgentThatCantBeAddedIsRefusedSayingWhy() {
        let file = "agents:\n  - id: painter\n    name: Painter\n    role: You paint.\n    helper: {name: brush, tools: [Read], description: Paints., prompt: Paint.}\n"
        let mistakes: [(entry: String, error: String)] = [
            (
                plumber.replacingOccurrences(of: "id: plumber", with: "id: painter"),
                "agents.yaml: agents[1].id \"painter\" is agents[0]'s id too. Each agent needs an id of its own."
            ),
            (
                plumber.replacingOccurrences(of: "name: Plumber", with: "name: painter"),
                "agents.yaml: agents[1].name \"painter\" is agents[0]'s name too. Each agent needs a name of its own."
            ),
            (
                plumber.replacingOccurrences(of: "\"#2266AA\"", with: "blue"),
                "agents.yaml: agents[1].color should be a colour like \"#8050C8\", not \"blue\"."
            ),
            (
                plumber.replacingOccurrences(of: "color:", with: "colour:"),
                "agents.yaml: agents[1].colour isn't a field of an agent. The fields are id, name, color, permission_mode, model, works_in, project, changes_things, role and helper."
            ),
            (
                plumber.replacingOccurrences(of: "model: sonnet", with: "model: sonnet-5"),
                "agents.yaml: agents[1].model \"sonnet-5\" isn't one of the models a character can run on: fable, opus, sonnet or haiku. Leave it out for Claude Code's own default."
            ),
            (
                plumber.replacingOccurrences(of: "  tools: [Read, Edit]\n", with: ""),
                "agents.yaml: agents[1].helper.tools is missing."
            ),
            ("", "The new agent is empty. Give its fields, starting with id:."),
            ("plumber", "The new agent should be one agent's fields, starting with id:, as an agent in the file has them."),
            ("- plumber", "The new agent should be one agent's fields, starting with id:, as an agent in the file has them."),
            (
                "- id: plumber\n- id: roofer",
                "The new agent should be one agent's fields, starting with id:, as an agent in the file has them."
            ),
        ]
        for mistake in mistakes {
            XCTAssertThrowsError(try Cast.adding(mistake.entry, to: file, from: "agents.yaml"), mistake.error) { error in
                XCTAssertEqual("\(error)", mistake.error)
            }
        }
        XCTAssertThrowsError(try Cast.adding("id: plumber\nname: [Plumber", to: file, from: "agents.yaml")) { error in
            XCTAssertTrue("\(error)".hasPrefix("The new agent isn't valid YAML: "), "\(error)")
        }
        // Nothing is added to a file that is wrong already.
        XCTAssertThrowsError(try Cast.adding(plumber, to: "agents:\n  - id: painter\n", from: "agents.yaml")) { error in
            XCTAssertEqual("\(error)", "agents.yaml: agents[0].name is missing.")
        }
    }

    // MARK: Files to try with

    /// A directory that is gone when the test ends, with the environment that
    /// points the server at an agents file and an added agents file in it,
    /// neither there until a test writes it.
    private func files(
        agents: String? = nil, added: String? = nil
    ) throws -> (agentsFile: URL, addedFile: URL, environment: [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let agentsFile = directory.appendingPathComponent("agents.yaml")
        let addedFile = directory.appendingPathComponent("added").appendingPathComponent("added-agents.yaml")
        if let agents { try agents.write(to: agentsFile, atomically: true, encoding: .utf8) }
        if let added {
            try FileManager.default.createDirectory(at: addedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try added.write(to: addedFile, atomically: true, encoding: .utf8)
        }
        return (agentsFile, addedFile, ["ALIFE_AGENTS_FILE": agentsFile.path, "ALIFE_ADDED_AGENTS_FILE": addedFile.path])
    }

    // MARK: Adding to the added agents

    func testAnAgentIsAddedToTheShippedFileBeforeItsExample() throws {
        let shipped = try String(contentsOf: Cast.shippedFile, encoding: .utf8)
        let (text, added) = try Cast.adding(plumber, to: shipped, from: "agents.yaml")
        XCTAssertEqual(added.id, "plumber")
        XCTAssertEqual(try Cast.decode(text, from: "agents.yaml"), [added])
        XCTAssertTrue(try XCTUnwrap(text.range(of: "- id: plumber")).lowerBound < XCTUnwrap(text.range(of: "# - id: app-engineer")).lowerBound)
        // Nothing of the file was lost.
        XCTAssertTrue(text.hasPrefix(String(shipped.prefix(upTo: try XCTUnwrap(shipped.range(of: "\nagents:"))?.lowerBound ?? shipped.startIndex))))
        XCTAssertTrue(text.hasSuffix(String(shipped.suffix(from: try XCTUnwrap(shipped.range(of: "  # An engineer for a project"))?.lowerBound ?? shipped.startIndex))))
    }

    func testTheFirstAgentIsAddedToAFileWithNoneYet() throws {
        for file in ["agents:\n", "agents: []\n", "# Nobody yet.\nagents:\n", "agents: [ ]\n"] {
            let (text, added) = try Cast.adding(plumber, to: file, from: "agents.yaml")
            XCTAssertEqual(try Cast.decode(text, from: "agents.yaml"), [added], file)
            XCTAssertTrue(text.hasPrefix(file.hasPrefix("# Nobody") ? "# Nobody yet.\nagents:\n" : "agents:\n"), text)
        }
        let (text, _) = try Cast.adding(plumber, to: Cast.addedFileHeader, from: "added-agents.yaml")
        XCTAssertTrue(text.hasPrefix(Cast.addedFileHeader.replacingOccurrences(of: "agents:\n", with: "")))
    }

    func testTheAddAgentCommandAddsToTheAddedFileAndNeverToTheAgentsFile() throws {
        let (agentsFile, addedFile, environment) = try files(agents: painter)
        let checkout = try XCTUnwrap(Cast.checkoutFile)
        let checkoutBefore = try String(contentsOf: checkout, encoding: .utf8)
        let shippedBefore = try String(contentsOf: Cast.shippedFile, encoding: .utf8)
        let builtInBefore = try String(contentsOf: Cast.builtInFile, encoding: .utf8)

        // The first agent makes the file, and the folder it is in.
        let added = AddAgent.run(entry: plumber, environment: environment)
        XCTAssertTrue(added.added, added.said)
        XCTAssertEqual(added.said, "Added the Plumber (plumber) to \(addedFile.path). They join the lot straight away if the server is running, and otherwise when it next starts.")
        XCTAssertEqual(try Cast.load(contentsOf: addedFile).map(\.id), ["plumber"])
        XCTAssertTrue(try String(contentsOf: addedFile, encoding: .utf8).hasPrefix(Cast.addedFileHeader.replacingOccurrences(of: "agents:\n", with: "")))

        // The agents file, the checkout's and the built-in ones are as they were.
        XCTAssertEqual(try String(contentsOf: agentsFile, encoding: .utf8), painter)
        XCTAssertEqual(try String(contentsOf: checkout, encoding: .utf8), checkoutBefore)
        XCTAssertEqual(try String(contentsOf: Cast.shippedFile, encoding: .utf8), shippedBefore)
        XCTAssertEqual(try String(contentsOf: Cast.builtInFile, encoding: .utf8), builtInBefore)

        // The server reads the cast from the same files: built in, then the
        // person's own, then the added.
        let layers = try Cast.layers(in: environment)
        XCTAssertEqual(layers.all.map(\.id), ["builder", "engineer", "team-lead", "conservationist", "painter", "plumber"])
        XCTAssertEqual(layers.added.map(\.id), ["plumber"])

        // A second one goes after the first.
        let roofer = plumber.replacingOccurrences(of: "plumber", with: "roofer").replacingOccurrences(of: "Plumber", with: "Roofer")
        XCTAssertTrue(AddAgent.run(entry: roofer, environment: environment).added)
        XCTAssertEqual(try Cast.load(contentsOf: addedFile).map(\.id), ["plumber", "roofer"])

        // The same again is refused, and the file left alone.
        let before = try String(contentsOf: addedFile, encoding: .utf8)
        let again = AddAgent.run(entry: plumber, environment: environment)
        XCTAssertFalse(again.added)
        XCTAssertEqual(again.said, "\(addedFile.path): agents[2].id \"plumber\" is agents[0]'s id too. Each agent needs an id of its own.\nNothing was changed.")
        XCTAssertEqual(try String(contentsOf: addedFile, encoding: .utf8), before)
    }

    func testAnIdOrANameThatIsAlreadyTakenIsRefusedWhoeverHasIt() throws {
        let (agentsFile, addedFile, environment) = try files(agents: painter, added: Cast.addedFileHeader)
        func refused(replacing old: String, with new: String) throws -> String {
            let result = AddAgent.run(entry: plumber.replacingOccurrences(of: old, with: new), environment: environment)
            XCTAssertFalse(result.added, result.said)
            XCTAssertTrue(result.said.hasSuffix("\nNothing was changed."), result.said)
            return result.said.replacingOccurrences(of: "\nNothing was changed.", with: "")
        }
        let theId = "Each agent needs an id and a name of its own."
        // The built-in agents, by id, by name, and by name in any case.
        XCTAssertEqual(try refused(replacing: "id: plumber", with: "id: builder"), "the id \"builder\" is already the built-in Builder (builder). \(theId)")
        XCTAssertEqual(try refused(replacing: "id: plumber", with: "id: engineer"), "the id \"engineer\" is already the built-in a*life Engineer (engineer). \(theId)")
        XCTAssertEqual(try refused(replacing: "name: Plumber", with: "name: team lead"), "the name \"team lead\" is already the built-in Team Lead (team-lead). \(theId)")
        XCTAssertEqual(try refused(replacing: "name: Plumber", with: "name: \"a*life Engineer\""), "the name \"a*life Engineer\" is already the built-in a*life Engineer (engineer). \(theId)")
        // The person's own.
        XCTAssertEqual(try refused(replacing: "id: plumber", with: "id: painter"), "the id \"painter\" is already the Painter (painter) in \(agentsFile.path). \(theId)")
        XCTAssertEqual(try refused(replacing: "name: Plumber", with: "name: Painter"), "the name \"Painter\" is already the Painter (painter) in \(agentsFile.path). \(theId)")
        XCTAssertEqual(try String(contentsOf: addedFile, encoding: .utf8), Cast.addedFileHeader)
        XCTAssertEqual(try String(contentsOf: agentsFile, encoding: .utf8), painter)
    }

    func testAnAgentCantBeAddedWhileAnAgentsFileIsWrong() throws {
        let (_, addedFile, environment) = try files(agents: "agents:\n  - id: painter\n")
        let result = AddAgent.run(entry: plumber, environment: environment)
        XCTAssertFalse(result.added)
        XCTAssertTrue(result.said.hasPrefix("\(environment["ALIFE_AGENTS_FILE"]!): "), result.said)
        XCTAssertFalse(FileManager.default.fileExists(atPath: addedFile.path))
    }

    // MARK: Taking an agent away

    /// Three agents, with a comment on the second and an example at the end.
    private let crew = """
        # The crew.
        agents:
          - id: painter
            name: Painter
            role: You paint.
            helper: {name: brush, tools: [Read], description: Paints., prompt: Paint.}

          # The plumber fixes the pipes.
          - id: plumber
            name: Plumber
            role: |
              You fix the pipes.

              # Not a comment, but part of the role.
            helper:
              name: wrench
              tools: [Read, Edit]
              description: Fixes pipes.
              prompt: You fix pipes.

          - id: team-lead
            name: Team Lead
            role: You lead.
            helper: {name: recruiter, tools: [Read], description: Recruits., prompt: Recruit.}

          # An example:
          # - id: roofer

        """

    func testAnAgentIsTakenAwayWithItsCommentLeavingTheOthersAsTheyAre() throws {
        let (text, removed) = try Cast.removing("plumber", from: crew, source: "agents.yaml")
        XCTAssertEqual(removed.name, "Plumber")
        XCTAssertEqual(text, """
            # The crew.
            agents:
              - id: painter
                name: Painter
                role: You paint.
                helper: {name: brush, tools: [Read], description: Paints., prompt: Paint.}

              - id: team-lead
                name: Team Lead
                role: You lead.
                helper: {name: recruiter, tools: [Read], description: Recruits., prompt: Recruit.}

              # An example:
              # - id: roofer

            """)

        // The first one, by its name, and the last one before the example.
        let withoutThePainter = try Cast.removing("painter", from: crew, source: "agents.yaml").text
        XCTAssertEqual(try Cast.decode(withoutThePainter, from: "agents.yaml").map(\.id), ["plumber", "team-lead"])
        XCTAssertTrue(withoutThePainter.hasPrefix("# The crew.\nagents:\n\n  # The plumber fixes the pipes.\n  - id: plumber\n"))
        XCTAssertEqual(try Cast.removing("Painter", from: crew, source: "agents.yaml").text, withoutThePainter)
    }

    // MARK: Taking an agent away from the added agents

    func testAnAddedAgentIsTakenAwayLeavingTheFileWithoutAgentsForTheServerToStartWith() throws {
        let (_, addedFile, environment) = try files(agents: painter)
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        let (agent, file) = try Cast.remove("Plumber", in: environment)
        XCTAssertEqual(agent.id, "plumber")
        XCTAssertEqual(file, addedFile)
        XCTAssertEqual(try Cast.load(contentsOf: addedFile), [])
        XCTAssertEqual(try Cast.layers(in: environment).all.map(\.id), ["builder", "engineer", "team-lead", "conservationist", "painter"])
        // Another can be added after it.
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        XCTAssertEqual(try Cast.load(contentsOf: addedFile).map(\.id), ["plumber"])
    }

    func testOnlyAddedAgentsAreTakenAway() throws {
        let (agentsFile, addedFile, environment) = try files(agents: painter)
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        let agentsBefore = try String(contentsOf: agentsFile, encoding: .utf8)
        let addedBefore = try String(contentsOf: addedFile, encoding: .utf8)

        // The built-in agents always stay, by id, name or any case.
        for (wanted, id, name) in [
            ("team-lead", "team-lead", "Team Lead"), ("Team Lead", "team-lead", "Team Lead"), ("builder", "builder", "Builder"),
            ("conservationist", "conservationist", "Conservationist"), ("engineer", "engineer", "a*life Engineer"),
            ("a*life Engineer", "engineer", "a*life Engineer"), ("A*LIFE ENGINEER", "engineer", "a*life Engineer"),
        ] {
            for confirmed in [false, true] {
                let result = RemoveAgent.run(id: wanted, confirmed: confirmed, environment: environment)
                XCTAssertFalse(result.succeeded, wanted)
                XCTAssertEqual(result.said, "The \(name) (\(id)) can't be taken away: it is built into the server, and always stays on the lot.\nNothing was changed.")
            }
        }
        // So does everyone in the agents file, which the person edits.
        for confirmed in [false, true] {
            let result = RemoveAgent.run(id: "painter", confirmed: confirmed, environment: environment)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.said, "The Painter (painter) can't be taken away: it is in \(agentsFile.path), where the person keeps their own agents, and always stays on the lot. To drop it, they take it out of that file themselves and restart the server.\nNothing was changed.")
        }
        // And nobody who isn't there.
        let nobody = RemoveAgent.run(id: "roofer", confirmed: true, environment: environment)
        XCTAssertFalse(nobody.succeeded)
        XCTAssertEqual(nobody.said, "There's no agent \"roofer\". The agents that can be taken away, the added ones, are plumber.\nNothing was changed.")
        XCTAssertEqual(try String(contentsOf: agentsFile, encoding: .utf8), agentsBefore)
        XCTAssertEqual(try String(contentsOf: addedFile, encoding: .utf8), addedBefore)

        // With no added file at all, there is nobody to take away.
        let (_, _, bare) = try files()
        XCTAssertEqual(RemoveAgent.run(id: "plumber", confirmed: true, environment: bare).said, "There's no agent \"plumber\". The agents that can be taken away, the added ones, are none right now.\nNothing was changed.")
    }

    func testTheRemoveAgentCommandOnlyTakesAnAgentAwayOnceConfirmed() throws {
        let (_, addedFile, environment) = try files(added: Cast.addedFileHeader)
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        let before = try String(contentsOf: addedFile, encoding: .utf8)

        // Without --confirmed, it only names the agent.
        let asked = RemoveAgent.run(id: "plumber", confirmed: false, environment: environment)
        XCTAssertTrue(asked.succeeded)
        XCTAssertEqual(asked.said, "The Plumber (plumber) can be taken away from \(addedFile.path), but nothing was changed. Ask the person whether to take the Plumber away, and only once they say yes, run this again with --confirmed.")
        XCTAssertEqual(try String(contentsOf: addedFile, encoding: .utf8), before)

        let removed = RemoveAgent.run(id: "plumber", confirmed: true, environment: environment)
        XCTAssertTrue(removed.succeeded)
        XCTAssertEqual(removed.said, "Took the Plumber (plumber) away from \(addedFile.path). They leave the lot straight away if the server is running, and otherwise are gone when it next starts.")
        XCTAssertEqual(try Cast.load(contentsOf: addedFile), [])
    }

    // MARK: The layers

    func testTheLayersAreTheBuiltInAgentsThenTheAgentsFilesThenTheAddedOnes() throws {
        let roofer = painter.replacingOccurrences(of: "painter", with: "roofer").replacingOccurrences(of: "Painter", with: "Roofer")
        let (_, _, environment) = try files(agents: painter, added: roofer)
        var warnings: [String] = []
        let layers = try Cast.layers(in: environment, warn: { warnings.append($0) })
        XCTAssertEqual(layers.builtIn, Cast.builtIn)
        XCTAssertEqual(layers.own.map(\.id), ["painter"])
        XCTAssertEqual(layers.added.map(\.id), ["roofer"])
        XCTAssertEqual(layers.all.map(\.id), ["builder", "engineer", "team-lead", "conservationist", "painter", "roofer"])
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(layers.agent("Roofer")?.origin, .added)
        XCTAssertEqual(layers.agent("painter")?.origin, .agentsFile)
        XCTAssertEqual(layers.agent("a*life engineer")?.origin, .builtIn)
        XCTAssertNil(layers.agent("nobody"))
    }

    func testAStaleCopyOfABuiltInAgentInTheAgentsFileIsIgnoredWithAWarning() throws {
        // What an agents file copied before the server had agents built in
        // looks like: the old Team Lead, with a role that can't take agents
        // away, and the Engineer under its old name, besides the person's own.
        let stale = """
            agents:
              - id: team-lead
                name: Team Lead
                color: "#111111"
                model: haiku
                role: You are the Team Lead, a character in a*life, a little life sim. You can't take agents away.
                helper: {name: recruiter, tools: [Read], description: Recruits., prompt: You are the Team Lead's recruiter.}

              - id: old-engineer
                name: a*life Engineer
                role: You are the a*life Engineer.
                helper: {name: expert, tools: [Read], description: Codes., prompt: You code.}

              - id: painter
                name: Painter
                role: You paint.
                helper: {name: brush, tools: [Read], description: Paints., prompt: Paint.}
            """
        let (agentsFile, _, environment) = try files(agents: stale)
        var warnings: [String] = []
        let layers = try Cast.layers(in: environment, warn: { warnings.append($0) })

        // The server's own are used, so the new roles reach everyone.
        XCTAssertEqual(layers.all.map(\.id), ["builder", "engineer", "team-lead", "conservationist", "painter"])
        let teamLead = try XCTUnwrap(layers.all.first { $0.id == "team-lead" })
        XCTAssertEqual(teamLead, Character.teamLead)
        XCTAssertEqual(teamLead.color, "#2A9D8F")
        XCTAssertFalse(teamLead.role.contains("You can't take agents away."))
        XCTAssertEqual(layers.own.map(\.id), ["painter"])
        XCTAssertEqual(warnings, [
            "\(agentsFile.path) has the Team Lead (team-lead), which is the server's built-in Team Lead (team-lead): the server's is used instead, and this entry is ignored. Take it out of the file.",
            "\(agentsFile.path) has the a*life Engineer (old-engineer), which is the server's built-in a*life Engineer (engineer): the server's is used instead, and this entry is ignored. Take it out of the file.",
        ])
        // The stale entry is no agent of the person's: it can't be removed
        // as one, and the Team Lead still can't take the built-in one.
        XCTAssertEqual(layers.agent("team-lead")?.origin, .builtIn)
    }

    func testTheAgentsFileCanListNoAgentsOrBeMissingAndThereAreStillTheBuiltInAgents() throws {
        for text in ["", "\n\n", "# Only comments.\n", "agents:\n", "agents: []\n", "agents:\n  # - id: app-engineer\n"] {
            XCTAssertEqual(try Cast.decode(text, from: "agents.yaml"), [], text)
            let (_, _, environment) = try files(agents: text)
            XCTAssertEqual(try Cast.layers(in: environment).all, Cast.builtIn, text)
        }
        let (agentsFile, _, missing) = try files()
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsFile.path))
        XCTAssertEqual(try Cast.layers(in: missing).all, Cast.builtIn)
        // Loading it by name still wants it to be there.
        XCTAssertThrowsError(try Cast.load(contentsOf: agentsFile))
        // Things that aren't an agents file are still refused.
        XCTAssertThrowsError(try Cast.decode("agents: nope", from: "agents.yaml"))
        XCTAssertThrowsError(try Cast.decode("agent: []", from: "agents.yaml"))
    }

    func testAnAddedAgentThatIsABuiltInOneIsIgnoredToo() throws {
        let (_, addedFile, environment) = try files(added: "agents:\n" + painter.dropFirst("agents:\n".count).replacingOccurrences(of: "id: painter", with: "id: builder").replacingOccurrences(of: "name: Painter", with: "name: Someone"))
        var warnings: [String] = []
        let layers = try Cast.layers(in: environment, warn: { warnings.append($0) })
        XCTAssertEqual(layers.all, Cast.builtIn)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("\(addedFile.path) has the Someone (builder), which is the server's built-in Builder (builder)") == true, "\(warnings)")
    }

    func testTheSameIdOrNameInTheAgentsFileAndTheAddedFileIsAnErrorNamingBoth() throws {
        let sameId = painter.replacingOccurrences(of: "name: Painter", with: "name: Decorator")
        let (agentsFile, addedFile, environment) = try files(agents: painter, added: sameId)
        XCTAssertThrowsError(try Cast.layers(in: environment)) { error in
            XCTAssertEqual("\(error)", "\(agentsFile.path) and \(addedFile.path) both have the id \"painter\", the Painter (painter) in the first and the Decorator (painter) in the second. Each agent needs an id and a name of its own: take one of them out.")
        }
        let sameName = painter.replacingOccurrences(of: "id: painter", with: "id: decorator").replacingOccurrences(of: "name: Painter", with: "name: painter")
        try sameName.write(to: addedFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Cast.layers(in: environment)) { error in
            XCTAssertEqual("\(error)", "\(agentsFile.path) and \(addedFile.path) both have the name \"painter\", the Painter (painter) in the first and the painter (decorator) in the second. Each agent needs an id and a name of its own: take one of them out.")
        }
    }

    func testALIFE_ADDED_AGENTS_FILEChoosesTheAddedAgentsFile() {
        XCTAssertEqual(Cast.addedFile(in: ["ALIFE_ADDED_AGENTS_FILE": "/srv/cast/added.yaml"]).path, "/srv/cast/added.yaml")
        XCTAssertEqual(
            Cast.addedFile(in: ["ALIFE_ADDED_AGENTS_FILE": "~/cast/added.yaml"]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cast/added.yaml").path
        )
        // Unless it is set, in the state directory.
        XCTAssertEqual(Cast.addedFile(in: ["ALIFE_STATE_DIR": "/srv/state"]).path, "/srv/state/added-agents.yaml")
        XCTAssertEqual(Cast.addedFile(in: ["ALIFE_STATE_DIR": "/srv/state", "ALIFE_ADDED_AGENTS_FILE": ""]).path, "/srv/state/added-agents.yaml")
        XCTAssertEqual(
            Cast.addedFile(in: [:]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-state/added-agents.yaml").path
        )
    }

    func testTheTeamLeadsSessionIsGivenTheFilesAndTheCommandTheRecruiterUses() async throws {
        // A stand-in for the claude command that says what it was given.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("claude")
        try """
            #!/bin/sh
            printf '{"agents":"%s","added":"%s","command":"%s"}\\n' "$ALIFE_AGENTS_FILE" "$ALIFE_ADDED_AGENTS_FILE" "$ALIFE_SERVER_COMMAND"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var launcher = ClaudeCode(executable: script, lot: directory)
        launcher.agentsFile = URL(fileURLWithPath: "/srv/agents.yaml")
        launcher.addedAgentsFile = URL(fileURLWithPath: "/srv/added-agents.yaml")
        launcher.serverCommand = URL(fileURLWithPath: "/srv/ALifeServer")

        let connection = try launcher.launch([], in: .lot)
        var said: JSONValue?
        for await message in connection.messages { said = message; break }
        XCTAssertEqual(said?["agents"]?.string, "/srv/agents.yaml")
        XCTAssertEqual(said?["added"]?.string, "/srv/added-agents.yaml")
        XCTAssertEqual(said?["command"]?.string, "/srv/ALifeServer")
        // The recruiter's prompt names each of them.
        for variable in ["ALIFE_AGENTS_FILE", "ALIFE_ADDED_AGENTS_FILE", "ALIFE_SERVER_COMMAND"] {
            XCTAssertTrue(Character.teamLead.helper.prompt.contains(variable), variable)
        }
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
                model: .opus,
                workspace: .aLife,
                // Without the line break a YAML block ends with.
                role: "You are the Painter.\n\nYou paint the house.",
                helper: Helper(name: "brush", description: "Paints walls.", prompt: "You paint walls.", tools: ["Read", "Edit"], model: .haiku)
            ),
        ])
    }

    func testAnAgentCanLeaveOutItsColourPermissionModeModelWorkspaceAndWhetherItChangesThings() throws {
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
        XCTAssertNil(painter.model) // Claude Code's own default
        XCTAssertNil(painter.helper.model) // its character's
        XCTAssertEqual(painter.helper.definition["model"], "inherit")
        XCTAssertEqual(painter.workspace, .lot)
        XCTAssertFalse(painter.changesThings)
    }

    func testAModelIsOneOfClaudeCodesSimpleNames() throws {
        for model in ClaudeModel.allCases {
            let yaml = amended(replacing: "model: opus", with: "model: \(model.rawValue)")
                .replacingOccurrences(of: "model: haiku", with: "model: \(model.rawValue)")
            let painter = try XCTUnwrap(Cast.decode(yaml, from: "agents.yaml").first)
            XCTAssertEqual(painter.model, model)
            XCTAssertEqual(painter.helper.model, model)
            XCTAssertEqual(painter.helper.definition["model"], .string(model.rawValue))
        }
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
            ("agents: nope", "agents.yaml: agents should be a list."),
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
                "agents.yaml: agents[0].colour isn't a field of an agent. The fields are id, name, color, permission_mode, model, works_in, project, changes_things, role and helper."
            ),
            (
                amended(replacing: "model: opus", with: "model: claude-opus-5-5"),
                "agents.yaml: agents[0].model \"claude-opus-5-5\" isn't one of the models a character can run on: fable, opus, sonnet or haiku. Leave it out for Claude Code's own default."
            ),
            (
                amended(replacing: "model: opus", with: "model: Opus"),
                "agents.yaml: agents[0].model \"Opus\" isn't one of the models a character can run on: fable, opus, sonnet or haiku. Leave it out for Claude Code's own default."
            ),
            (
                amended(replacing: "model: opus", with: "model:"),
                "agents.yaml: agents[0].model is empty. Leave it out, or give it a value; one that starts with # needs quotes."
            ),
            (
                amended(replacing: "model: haiku", with: "model: inherit"),
                "agents.yaml: agents[0].helper.model \"inherit\" isn't one of the models a character can run on: fable, opus, sonnet or haiku. Leave it out to run it on its character's model."
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
                "agents.yaml: agents[0].id \"The Painter\" won't do. An id has only lowercase letters, digits and hyphens, such as \"builder\"."
            ),
            (
                painter + "\n  - id: painter\n    name: Another\n    role: Again.\n    helper: {name: roller, tools: [Read], description: Rolls., prompt: Roll.}",
                "agents.yaml: agents[1].id \"painter\" is agents[0]'s id too. Each agent needs an id of its own."
            ),
            (
                painter + "\n  - id: another-painter\n    name: painter\n    role: Again.\n    helper: {name: roller, tools: [Read], description: Rolls., prompt: Roll.}",
                "agents.yaml: agents[1].name \"painter\" is agents[0]'s name too. Each agent needs a name of its own."
            ),
            (
                amended(replacing: "permission_mode: acceptEdits", with: "permission_mode: ask"),
                "agents.yaml: agents[0].permission_mode \"ask\" isn't one of Claude Code's permission modes: default, manual, acceptEdits, plan, auto, dontAsk, bypassPermissions."
            ),
            (
                amended(replacing: "works_in: a-life", with: "works_in: garden"),
                "agents.yaml: agents[0].works_in \"garden\" isn't somewhere a character can work. It can be lot, the lot the characters share, or a-life, a checkout of the a*life repository. For a project of your own, use project instead."
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
                "agents.yaml: agents[0].helper.descripton isn't a field of a helper. The fields are name, tools, model, description and prompt."
            ),
        ]
        for mistake in mistakes {
            XCTAssertThrowsError(try Cast.decode(mistake.file, from: "agents.yaml"), mistake.error) { error in
                XCTAssertEqual("\(error)", mistake.error)
            }
        }
    }

    // MARK: Projects

    /// The painter, working on `project` instead of a*life.
    private func painter(onProject project: String) -> String {
        amended(replacing: "works_in: a-life", with: "project: \(project)")
    }

    func testAProjectCanBeADirectoryOnThisMachine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let character = try XCTUnwrap(Cast.decode(painter(onProject: "{path: \(directory.path)}"), from: "agents.yaml").first)
        XCTAssertEqual(character.workspace, .project(Project(id: "painter", source: .directory(directory.standardizedFileURL))))

        // ~ is your home directory.
        let home = try XCTUnwrap(Cast.decode(painter(onProject: "{path: \"~\"}"), from: "agents.yaml").first)
        guard case .project(let project) = home.workspace, case .directory(let path) = project.source else {
            return XCTFail("\(home.workspace)")
        }
        XCTAssertEqual(path.path, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }

    func testAProjectCanBeAGitRepositoryWithABranch() throws {
        let repositories: [(project: String, source: Project.Source)] = [
            ("{repo: \"git@gitlab.com:someone/app\"}", .repository("git@gitlab.com:someone/app", branch: nil)),
            ("{repo: \"git@github.com:someone/app.git\", branch: develop}", .repository("git@github.com:someone/app.git", branch: "develop")),
            ("{repo: \"ssh://git@example.com/app.git\"}", .repository("ssh://git@example.com/app.git", branch: nil)),
            ("{repo: \"file:///tmp/app.git\", branch: release/1.0}", .repository("file:///tmp/app.git", branch: "release/1.0")),
        ]
        for (yaml, source) in repositories {
            let character = try XCTUnwrap(Cast.decode(painter(onProject: yaml), from: "agents.yaml").first, yaml)
            XCTAssertEqual(character.workspace, .project(Project(id: "painter", source: source)), yaml)
        }
    }

    func testAProjectCanBeSeveralGitRepositoriesClonedSideBySide() throws {
        let yaml = painter(onProject: """

              repos:
                - repo: git@github.com:someone/app.git
                - repo: "git@github.com:someone/app-server.git"
                  branch: develop
                - {repo: "file:///tmp/tools/"}
        """)
        let character = try XCTUnwrap(Cast.decode(yaml, from: "agents.yaml").first)
        let repositories = [
            Project.Repository(address: "git@github.com:someone/app.git"),
            Project.Repository(address: "git@github.com:someone/app-server.git", branch: "develop"),
            Project.Repository(address: "file:///tmp/tools/"),
        ]
        XCTAssertEqual(character.workspace, .project(Project(id: "painter", source: .repositories(repositories))))
        // Each is cloned into a directory named as git clone would name it.
        XCTAssertEqual(repositories.map(\.name), ["app", "app-server", "tools"])
    }

    func testTheShippedFilesProjectEngineerWorksOnceItsCommentsAreTakenOff() throws {
        // The example at the end of the shipped file, without its #s.
        let shipped = try String(contentsOf: Cast.shippedFile, encoding: .utf8)
        let start = try XCTUnwrap(shipped.range(of: "  # - id: app-engineer"))
        let example = shipped[start.lowerBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("  #") ? String($0.dropFirst(3)) : String($0) }
            .joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("my-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let onAPath = "agents:\n" + example.replacingOccurrences(of: "~/Development/my-app", with: directory.path)
        let engineer = try XCTUnwrap(Cast.decode(onAPath, from: "agents.yaml").first)
        XCTAssertEqual(engineer.name, "App Engineer")
        XCTAssertEqual(engineer.helper.name, "app-expert")
        XCTAssertEqual(engineer.workspace, .project(Project(id: "app-engineer", source: .directory(directory.standardizedFileURL))))

        let onARepository = onAPath
            .replacingOccurrences(of: "    path: \(directory.path)\n", with: "")
            .replacingOccurrences(of: "    # repo:", with: "    repo:")
            .replacingOccurrences(of: "    # branch:", with: "    branch:")
        XCTAssertEqual(
            try Cast.decode(onARepository, from: "agents.yaml").first?.workspace,
            .project(Project(id: "app-engineer", source: .repository("git@github.com:you/my-app.git", branch: "main")))
        )
    }

    func testMistakesInAProjectAreRefusedSayingWhereTheyAre() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nowhere-\(UUID().uuidString)").path
        let mistakes: [(file: String, error: String)] = [
            (
                painter(onProject: "{path: \(missing)}"),
                "agents.yaml: agents[0].project.path \(missing) isn't a directory on this machine. A project's path has to be there already; for one that isn't, give its repo instead."
            ),
            (
                painter(onProject: "{path: Development/app}"),
                "agents.yaml: agents[0].project.path \"Development/app\" should be a full path, such as ~/Development/my-app."
            ),
            (
                painter(onProject: "{repo: github.com/someone/app}"),
                "agents.yaml: agents[0].project.repo \"github.com/someone/app\" isn't a git repository's address. It can be like git@github.com:you/app.git, or start with ssh://, git:// or file://."
            ),
            (
                painter(onProject: "{repo: \"--upload-pack=touch /tmp/x\"}"),
                "agents.yaml: agents[0].project.repo \"--upload-pack=touch /tmp/x\" isn't a git repository's address. It can be like git@github.com:you/app.git, or start with ssh://, git:// or file://."
            ),
            (
                painter(onProject: "{repo: \"git@github.com:someone/app.git\", branch: \"-x\"}"),
                "agents.yaml: agents[0].project.branch \"-x\" won't do. A branch's name has no spaces and doesn't start with a hyphen, such as main."
            ),
            (
                painter(onProject: "{path: /tmp, branch: main}"),
                "agents.yaml: agents[0].project.branch is only for a repo. A project's path is used as it is, at whatever branch it is on."
            ),
            (
                painter(onProject: "{path: /tmp, repo: \"git@github.com:someone/app.git\"}"),
                "agents.yaml: agents[0].project.repo can't go with path. A project is either a directory on this machine or a git repository to clone, so leave one of them out."
            ),
            (
                painter(onProject: "{branch: main}"),
                "agents.yaml: agents[0].project needs a path, a directory on this machine, a repo, a git repository for the server to clone, or repos, several of them."
            ),
            (
                painter(onProject: "{url: \"git@github.com:someone/app.git\"}"),
                "agents.yaml: agents[0].project.url isn't a field of a project. The fields are path, repo, repos and branch."
            ),
            (
                painter(onProject: "/tmp"),
                "agents.yaml: agents[0].project should be a set of fields."
            ),
            (
                painter(onProject: "{repos: []}"),
                "agents.yaml: agents[0].project.repos is empty. List at least one repo for the server to clone."
            ),
            (
                painter(onProject: "{repos: \"git@github.com:someone/app.git\"}"),
                "agents.yaml: agents[0].project.repos should be a list."
            ),
            (
                painter(onProject: "{path: /tmp, repos: [{repo: \"git@github.com:someone/app.git\"}]}"),
                "agents.yaml: agents[0].project.repos can't go with path. A project is a directory on this machine, a git repository to clone, or several to clone side by side, so give only one of them."
            ),
            (
                painter(onProject: "{repo: \"git@github.com:someone/app.git\", repos: [{repo: \"git@github.com:someone/server.git\"}]}"),
                "agents.yaml: agents[0].project.repos can't go with repo. A project is a directory on this machine, a git repository to clone, or several to clone side by side, so give only one of them."
            ),
            (
                painter(onProject: "{branch: main, repos: [{repo: \"git@github.com:someone/app.git\"}]}"),
                "agents.yaml: agents[0].project.branch goes with each of the repos it is for, not with the project."
            ),
            (
                painter(onProject: "{repos: [{repo: \"git@github.com:someone/app.git\"}, {repo: github.com/someone/server}]}"),
                "agents.yaml: agents[0].project.repos[1].repo \"github.com/someone/server\" isn't a git repository's address. It can be like git@github.com:you/app.git, or start with ssh://, git:// or file://."
            ),
            (
                painter(onProject: "{repos: [{repo: \"git@github.com:someone/app.git\", branch: \"-x\"}]}"),
                "agents.yaml: agents[0].project.repos[0].branch \"-x\" won't do. A branch's name has no spaces and doesn't start with a hyphen, such as main."
            ),
            (
                painter(onProject: "{repos: [{repo: \"git@github.com:someone/.git\"}]}"),
                "agents.yaml: agents[0].project.repos[0].repo \"git@github.com:someone/.git\" doesn't end in a name to clone it as, such as app in git@github.com:you/app.git."
            ),
            (
                painter(onProject: "{repos: [{repo: \"git@github.com:someone/app.git\"}, {repo: \"git@gitlab.com:else/app\"}]}"),
                "agents.yaml: agents[0].project.repos[1].repo would be cloned into app, as repos[0] is. Each repo needs a directory of its own, so leave one of them out."
            ),
            (
                painter(onProject: "{repos: [{branch: main}]}"),
                "agents.yaml: agents[0].project.repos[0].repo is missing."
            ),
            (
                painter(onProject: "{repos: [{url: \"git@github.com:someone/app.git\"}]}"),
                "agents.yaml: agents[0].project.repos[0].url isn't a field of a repo. The fields are repo and branch."
            ),
            (
                amended(replacing: "works_in: a-life", with: "works_in: a-life\n    project: {path: /tmp}"),
                "agents.yaml: agents[0].project can't go with works_in. A character works on the lot, on a*life or on a project of its own, so leave one of them out."
            ),
        ]
        for mistake in mistakes {
            XCTAssertThrowsError(try Cast.decode(mistake.file, from: "agents.yaml"), mistake.error) { error in
                XCTAssertEqual("\(error)", mistake.error)
            }
        }
    }

    func testHttpsAddressesAreRefusedPointingToTheirSshAddress() {
        // The server clones without asking for a password, so an https
        // clone would fail when it starts.
        let mistakes: [(file: String, error: String)] = [
            (
                painter(onProject: "{repo: \"https://github.com/someone/app.git\"}"),
                "agents.yaml: agents[0].project.repo \"https://github.com/someone/app.git\" is an https address, which the server can't clone: it clones without asking for a password. Use the repository's ssh address instead, such as git@github.com:someone/app.git."
            ),
            (
                painter(onProject: "{repos: [{repo: \"git@github.com:someone/app.git\"}, {repo: \"http://me@gitlab.example.com/else/server\"}]}"),
                "agents.yaml: agents[0].project.repos[1].repo \"http://me@gitlab.example.com/else/server\" is an https address, which the server can't clone: it clones without asking for a password. Use the repository's ssh address instead, such as git@gitlab.example.com:else/server."
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
        // Unless it is set, the one in the checkout the server was built
        // from, which the shipped one is a copy of: no agents, only an example.
        let checkoutFile = try XCTUnwrap(Cast.checkoutFile)
        XCTAssertEqual(checkoutFile.lastPathComponent, "agents.yaml")
        XCTAssertEqual(try Cast.load(contentsOf: checkoutFile), [])
        XCTAssertEqual(try String(contentsOf: checkoutFile, encoding: .utf8), try String(contentsOf: Cast.shippedFile, encoding: .utf8))
        XCTAssertEqual(Cast.file(in: [:]), checkoutFile)
        XCTAssertEqual(Cast.file(in: ["ALIFE_AGENTS_FILE": ""]), checkoutFile)
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
        try "agents:\n  - id: painter\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Cast.load(contentsOf: file)) { error in
            XCTAssertEqual("\(error)", "\(file.path): agents[0].name is missing.")
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

        // Arguments of its own, rather than `.testing`'s, which some test

        // runners leave the test bundle in, for Vapor to take as a command.

        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
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
