import Foundation
import Vapor

/// Who plays the characters.
enum Players: Sendable {
    /// Each character is a Claude Code session of its own.
    case claudeCode(any ClaudeCodeLauncher)
    /// Each character plays a short script, and no model is called. Each
    /// step of the script takes `step`.
    case dummies(step: Duration)

    /// From the environment, for `cast` working on `lot`:
    ///
    /// - `ALIFE_BACKEND`: `claude` (the default) or `dummy`.
    /// - `ALIFE_REPO_DIR`: the a*life checkout the characters who work on
    ///   a*life work in, such as the Engineer. The checkout the server was
    ///   built from unless set.
    /// - `ALIFE_CLAUDE_PATH`: the `claude` command, if it isn't on the `PATH`.
    /// - `ALIFE_CLAUDE_MODEL`: the model for every character, such as
    ///   `sonnet`. Claude Code's own default unless set.
    /// - `ALIFE_PROJECTS_DIR`: where the projects that are git repositories
    ///   are cloned. `~/a-life-projects` unless set.
    ///
    /// It clones each such project that isn't cloned yet, and says where
    /// each character works.
    static func fromEnvironment(for cast: [Character], lot: URL, logger: Logger) throws -> Players {
        let environment = ProcessInfo.processInfo.environment
        switch environment["ALIFE_BACKEND"]?.lowercased() ?? "claude" {
        case "dummy", "dummies":
            return .dummies(step: .milliseconds(1500))
        case "claude":
            guard let executable = ClaudeCode.findExecutable(in: environment) else {
                throw ConfigurationError(
                    "Couldn't find the claude command. Install Claude Code, or set ALIFE_CLAUDE_PATH to it. "
                        + "To try the server without it, set ALIFE_BACKEND=dummy."
                )
            }
            let repository = try ClaudeCode.findRepository(in: environment)
            let model = environment["ALIFE_CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            logger.notice("The characters are Claude Code sessions (\(executable.path))")
            var claudeCode = ClaudeCode(executable: executable, lot: lot, repository: repository, model: model)
            let projects = ClaudeCode.projectsDirectory(in: environment)
            for character in cast {
                let name = character.name
                switch character.workspace {
                case .lot:
                    logger.notice("\(name) works on the lot, in \(lot.path)")
                case .aLife:
                    if let repository {
                        logger.notice("\(name) works on a*life, in \(repository.path)")
                    } else {
                        logger.warning("There's no a*life checkout for \(name) to work in. Set ALIFE_REPO_DIR to one.")
                    }
                case .project(let project):
                    switch project.source {
                    case .directory(let directory):
                        logger.notice("\(name) works on a project, in \(directory.path)")
                    case .repository(let address, let branch):
                        // A clone that fails only keeps its own character
                        // from starting, as a missing a*life checkout does.
                        do {
                            switch try ClaudeCode.checkOut(address, branch: branch, for: project.id, in: projects) {
                            case .cloned(let clone):
                                logger.notice("\(name) works on \(address), cloned just now into \(clone.path)")
                                claudeCode.clones[project.id] = .success(clone)
                            case .reused(let clone):
                                logger.notice("\(name) works on \(address), in its clone from before, \(clone.path), as it is")
                                claudeCode.clones[project.id] = .success(clone)
                            }
                        } catch {
                            let problem = error as? ConfigurationError ?? ConfigurationError("\(error)")
                            logger.error("\(name) can't start until this is fixed: \(problem)")
                            claudeCode.clones[project.id] = .failure(problem)
                        }
                    }
                }
            }
            return .claudeCode(claudeCode)
        case let other:
            throw ConfigurationError("ALIFE_BACKEND is \(other); it can be claude or dummy.")
        }
    }

    /// The directory the characters work in: `ALIFE_LOT_DIR`, or
    /// `~/a-life-lot` unless it is set. It is made if it isn't there.
    static func lotDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let lot = environment["ALIFE_LOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-lot")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
        return lot
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Sets the server up with a session per character in `cast`, played by
/// `players`, and the lot in `lotDirectory`. Each is as the environment says
/// if `nil`: the cast is read from the agents file, `ALIFE_AGENTS_FILE` or
/// the shipped `agents.yaml`, and the lot is `ALIFE_LOT_DIR`. Given
/// `players` but no `lotDirectory`, the lot stays empty.
func configure(
    _ app: Application,
    players playersGiven: Players? = nil,
    cast: [Character]? = nil,
    lotDirectory: URL? = nil,
    lotSurveyInterval: Duration = .seconds(1)
) async throws {
    let cast = try cast ?? loadCast(logger: app.logger)
    var lotDirectory = lotDirectory
    let players: Players
    if let given = playersGiven {
        players = given
    } else {
        let directory = try lotDirectory ?? Players.lotDirectory()
        lotDirectory = directory
        players = try Players.fromEnvironment(for: cast, lot: directory, logger: app.logger)
    }

    // What the characters build and plant shows up in the front ends.
    let lot = LotHub(directory: lotDirectory)
    if let lotDirectory {
        app.logger.notice("The lot is in \(lotDirectory.path). What's built in buildings/ and planted in garden/ there shows in the front ends.")
        await lot.survey()
        await lot.watch(every: lotSurveyInterval)
    }

    var sessions: [HostedSession] = []
    for character in cast {
        let hub = SessionHub(id: character.id, name: character.name, color: character.color)
        // The one place that chooses what plays each character.
        let backend: any SessionBackend
        switch players {
        case .claudeCode(let claudeCode):
            backend = ClaudeCharacter(character, hub: hub, claudeCode: claudeCode, logger: app.logger)
        case .dummies(let step):
            backend = DummyCharacter(character, hub: hub, step: step)
        }
        await backend.reset() // starts the first conversation
        sessions.append(HostedSession(id: character.id, hub: hub, backend: backend))
    }

    app.lifecycle.use(EndSessionsOnShutdown(sessions: sessions, lot: lot))
    routes(app, sessions: sessions, lot: lot)
}

/// The cast the agents file lists: the one `ALIFE_AGENTS_FILE` names, or the
/// shipped one.
private func loadCast(logger: Logger) throws -> [Character] {
    let file = Cast.file(in: ProcessInfo.processInfo.environment)
    let cast = try Cast.load(contentsOf: file)
    logger.notice("On the lot: \(cast.map(\.name).joined(separator: ", ")), from \(file.path)")
    return cast
}

/// When the server stops, ends the open event streams, so shutdown doesn't
/// wait on clients that are still listening, and stops each session and
/// watching the lot.
private struct EndSessionsOnShutdown: LifecycleHandler {
    let sessions: [HostedSession]
    let lot: LotHub

    func shutdownAsync(_ application: Application) async {
        await lot.stop()
        for session in sessions {
            await session.hub.closeStreams()
            await session.backend.shutdown()
        }
    }
}
