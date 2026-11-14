import Foundation
import Vapor

/// Who plays the characters.
enum Players: Sendable {
    /// Each character is a Claude Code session of its own.
    case claudeCode(any ClaudeCodeLauncher)
    /// Each character plays a short script, and no model is called. Each
    /// step of the script takes `step`.
    case dummies(step: Duration)

    /// From the environment:
    ///
    /// - `ALIFE_BACKEND`: `claude` (the default) or `dummy`.
    /// - `ALIFE_LOT_DIR`: the directory the characters work in, `~/a-life-lot`
    ///   unless set. It is made if it isn't there.
    /// - `ALIFE_CLAUDE_PATH`: the `claude` command, if it isn't on the `PATH`.
    /// - `ALIFE_CLAUDE_MODEL`: the model for every character, such as
    ///   `sonnet`. Claude Code's own default unless set.
    static func fromEnvironment(logger: Logger) throws -> Players {
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
            let model = environment["ALIFE_CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            logger.notice("The characters are Claude Code sessions (\(executable.path)), working on the lot in \(lot.path)")
            return .claudeCode(ClaudeCode(executable: executable, lot: lot, model: model))
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

/// Sets the server up with a session per character, played by `players`,
/// or as the environment says if `nil`.
func configure(_ app: Application, players: Players? = nil) async throws {
    let players = try players ?? Players.fromEnvironment(logger: app.logger)

    var sessions: [HostedSession] = []
    for character in cast {
        let hub = SessionHub(id: character.id, name: character.name)
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
