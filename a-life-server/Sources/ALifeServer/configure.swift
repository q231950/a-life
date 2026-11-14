import Foundation
import Vapor

/// Who plays the characters.
enum Players: Sendable {
    /// Each character is a Claude Code session of its own.
    case claudeCode(any ClaudeCodeLauncher)
    /// Each character plays a short script, and no model is called. Each
    /// step of the script takes `step`.
    case dummies(step: Duration)

    /// From the environment, for `cast`:
    ///
    /// - `ALIFE_BACKEND`: `claude` (the default) or `dummy`.
    /// - `ALIFE_LOT_DIR`: the directory the characters work in, `~/a-life-lot`
    ///   unless set. It is made if it isn't there.
    /// - `ALIFE_REPO_DIR`: the a*life checkout the characters who work on
    ///   a*life work in, such as the Engineer. The checkout the server was
    ///   built from unless set.
    /// - `ALIFE_CLAUDE_PATH`: the `claude` command, if it isn't on the `PATH`.
    /// - `ALIFE_CLAUDE_MODEL`: the model for every character, such as
    ///   `sonnet`. Claude Code's own default unless set.
    static func fromEnvironment(for cast: [Character], logger: Logger) throws -> Players {
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
            let lot = environment["ALIFE_LOT_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-lot")
            try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
            let repository = try ClaudeCode.findRepository(in: environment)
            let model = environment["ALIFE_CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            logger.notice("The characters are Claude Code sessions (\(executable.path)), working on the lot in \(lot.path)")
            let onALife = cast.filter { $0.workspace == .aLife }.map(\.name).joined(separator: ", ")
            if !onALife.isEmpty {
                if let repository {
                    logger.notice("Working on a*life, in \(repository.path): \(onALife)")
                } else {
                    logger.warning("There's no a*life checkout for \(onALife) to work in. Set ALIFE_REPO_DIR to one.")
                }
            }
            return .claudeCode(ClaudeCode(executable: executable, lot: lot, repository: repository, model: model))
        case let other:
            throw ConfigurationError("ALIFE_BACKEND is \(other); it can be claude or dummy.")
        }
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Sets the server up with a session per character in `cast`, played by
/// `players`. Each is as the environment says if `nil`: the cast is read
/// from the agents file, `ALIFE_AGENTS_FILE` or the shipped `agents.yaml`.
func configure(_ app: Application, players: Players? = nil, cast: [Character]? = nil) async throws {
    let cast = try cast ?? loadCast(logger: app.logger)
    let players = try players ?? Players.fromEnvironment(for: cast, logger: app.logger)

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

    app.lifecycle.use(EndSessionsOnShutdown(sessions: sessions))
    routes(app, sessions: sessions)
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
/// wait on clients that are still listening, and stops each session.
private struct EndSessionsOnShutdown: LifecycleHandler {
    let sessions: [HostedSession]

    func shutdownAsync(_ application: Application) async {
        for session in sessions {
            await session.hub.closeStreams()
            await session.backend.shutdown()
        }
    }
}
