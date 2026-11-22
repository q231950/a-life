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

    func testTheShippedFileStartsWithTheBuilderTheEngineerTheFlamingoEngineerAndTheTeamLead() throws {
        let cast = try Cast.load(contentsOf: Cast.shippedFile)
        // The Team Lead adds agents after the last one, so the file can grow,
        // but these four always come first, as they are.
        let founders = Array(cast.prefix(4))
        XCTAssertEqual(founders.map(\.id), ["builder", "engineer", "flamingo-engineer", "team-lead"])
        XCTAssertEqual(founders.map(\.name), ["Builder", "Engineer", "Flamingo Engineer", "Team Lead"])
        XCTAssertEqual(founders.map(\.color), ["#F2A633", "#8050C8", "#F27BA8", "#2A9D8F"])
        XCTAssertEqual(founders.map(\.permissionMode), ["default", "default", "default", "default"])
        // The Engineer works on a*life itself, in its checkout, and the
        // Flamingo Engineer on the three repositories of Flamingo Chess.
        let flamingoChess = Project(id: "flamingo-engineer", source: .repositories([
            Project.Repository(address: "git@github.com:q231950/flamingo.git"),
            Project.Repository(address: "git@github.com:q231950/flamingo-chess-light.git"),
            Project.Repository(address: "git@github.com:q231950/neoneon.git"),
        ]))
        XCTAssertEqual(founders.map(\.workspace), [.lot, .aLife, .project(flamingoChess), .lot])
        XCTAssertEqual(founders.map(\.changesThings), [true, true, true, true])
        XCTAssertEqual(founders.map(\.helper.name), ["construction-worker", "a-life-expert", "flamingo-expert", "recruiter"])
        XCTAssertEqual(founders.map(\.helper.tools), [
            ["Read", "Glob", "Grep", "Write", "Edit"],
            ["Read", "Glob", "Grep", "Write", "Edit", "Bash"],
            ["Read", "Glob", "Grep", "Write", "Edit", "Bash"],
            // The recruiter adds agents with the server's command, never by
            // writing the agents file itself.
            ["Read", "Glob", "Grep", "Bash"],
        ])

        // Every agent, the four and any added since, has a name and a helper
        // of its own, and a role and helper that say who they are.
        XCTAssertEqual(Set(cast.map(\.id)).count, cast.count)
        XCTAssertEqual(Set(cast.map(\.name)).count, cast.count)
        XCTAssertEqual(Set(cast.map(\.helper.name)).count, cast.count)
        for character in cast {
            XCTAssertTrue(character.role.hasPrefix("You are the \(character.name), a character in a*life, a little life sim."))
            // Each paragraph of a role is one line, as Claude Code is given it.
            let paragraphs = character.role.components(separatedBy: "\n\n")
            XCTAssertFalse(paragraphs.contains { $0.isEmpty || $0.contains("\n") }, "\(character.name)'s role")
            XCTAssertTrue(character.helper.prompt.hasPrefix("You are the \(character.name)'s "))
            XCTAssertFalse(character.helper.description.isEmpty)
        }

        // The lines a helper writes at the top of a file keep their lines.
        XCTAssertTrue(Character.conservationist.helper.prompt.contains("garden/rose-bed.md, starting with these lines, which put it on the lot:\n\n---\nkind: rose\ncolor: red\n"))
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

        // The Flamingo Engineer sends its expert for any change to Flamingo
        // Chess, and the expert knows which checkout is which.
        XCTAssertTrue(Character.flamingoEngineer.role.contains("`flamingo-expert`"))
        XCTAssertTrue(Character.flamingoEngineer.helper.description.contains("Use it whenever Flamingo Chess is to be changed."))
        let flamingoExpert = Character.flamingoEngineer.helper.prompt
        for part in ["flamingo/ is the iOS app", "flamingo-chess-light/ is the app for the Light Phone", "neoneon/ is the server"] {
            XCTAssertTrue(flamingoExpert.contains(part), "the Flamingo expert doesn't know \(part)")
        }
        XCTAssertTrue(flamingoExpert.contains("\n1. Run git status in each repository you'll touch, first."))
        XCTAssertTrue(flamingoExpert.contains("Don't commit, push or switch branches"))

        // The Team Lead sends its recruiter to add agents, and leaves the
        // lot's work to the others; the recruiter adds them with the
        // server's command, from what the server tells its session.
        let teamLead = Character.teamLead
        XCTAssertTrue(teamLead.role.contains("`recruiter`"))
        XCTAssertTrue(teamLead.role.contains("leave the lot to the Builder and the Conservationist"))
        XCTAssertTrue(teamLead.helper.description.contains("Use it whenever an agent is to be added."))
        let recruiter = teamLead.helper.prompt
        for part in ["cat \"$ALIFE_AGENTS_FILE\"", "\"$ALIFE_SERVER_COMMAND\" add-agent <<'AGENT'\nid: painter\n", "Never write or edit the file yourself"] {
            XCTAssertTrue(recruiter.contains(part), "the recruiter doesn't know \(part)")
        }
    }

    // MARK: Adding an agent

    /// The fields of a new agent, the plumber, as the recruiter gives them.
    private let plumber = """
        id: plumber
        name: Plumber
        color: "#2266AA"
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
            workspace: .lot,
            role: "You are the Plumber.\n\nYou fix the pipes.",
            helper: Helper(name: "wrench", description: "Fixes pipes.", prompt: "You fix pipes.", tools: ["Read", "Edit"])
        ))

        // Given as a list item, indented, it is the same agent.
        let asAnItem = "    - " + plumber.replacingOccurrences(of: "\n", with: "\n      ")
        XCTAssertEqual(try Cast.adding(asAnItem, to: file, from: "agents.yaml").text, text)
    }

    func testAnAgentIsAddedToTheShippedFileBeforeItsExample() throws {
        let shipped = try String(contentsOf: Cast.shippedFile, encoding: .utf8)
        let (text, added) = try Cast.adding(plumber, to: shipped, from: "agents.yaml")
        XCTAssertEqual(added.id, "plumber")
        // Everyone else is as they were, and the new agent comes last.
        let cast = try Cast.decode(text, from: "agents.yaml")
        XCTAssertEqual(Array(cast.dropLast()), shippedCast)
        XCTAssertEqual(cast.last, added)
        // Nothing of the file was lost, and the example is still at its end.
        XCTAssertEqual(text.replacingOccurrences(of: "\n  - id: plumber\n" + plumber.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n") + "\n", with: ""), shipped)
        XCTAssertTrue(try XCTUnwrap(text.range(of: "- id: plumber")).lowerBound < XCTUnwrap(text.range(of: "# - id: app-engineer")).lowerBound)
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
                "agents.yaml: agents[1].colour isn't a field of an agent. The fields are id, name, color, permission_mode, works_in, project, changes_things, role and helper."
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
        XCTAssertThrowsError(try Cast.adding(plumber, to: "agents: []", from: "agents.yaml")) { error in
            XCTAssertEqual("\(error)", "agents.yaml: agents is empty. There has to be at least one agent.")
        }
    }

    func testTheAddAgentCommandAddsToTheAgentsFileAndLeavesItBeIfItCant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.yaml")
        try painter.write(to: file, atomically: true, encoding: .utf8)
        let environment = ["ALIFE_AGENTS_FILE": file.path]

        let added = AddAgent.run(entry: plumber, environment: environment)
        XCTAssertTrue(added.added)
        XCTAssertEqual(added.said, "Added the Plumber (plumber) to \(file.path). They join the lot when the server restarts.")
        XCTAssertEqual(try Cast.load(contentsOf: file).map(\.id), ["painter", "plumber"])

        let before = try String(contentsOf: file, encoding: .utf8)
        let again = AddAgent.run(entry: plumber, environment: environment)
        XCTAssertFalse(again.added)
        XCTAssertEqual(again.said, "\(file.path): agents[2].id \"plumber\" is agents[1]'s id too. Each agent needs an id of its own.\nNothing was changed in \(file.path).")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
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
                "agents.yaml: agents[0].colour isn't a field of an agent. The fields are id, name, color, permission_mode, works_in, project, changes_things, role and helper."
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
                "agents.yaml: agents[0].helper.descripton isn't a field of a helper. The fields are name, tools, description and prompt."
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
        // from, which the shipped one is a copy of.
        let checkoutFile = try XCTUnwrap(Cast.checkoutFile)
        XCTAssertEqual(checkoutFile.lastPathComponent, "agents.yaml")
        XCTAssertEqual(try Cast.load(contentsOf: checkoutFile), shippedCast)
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
