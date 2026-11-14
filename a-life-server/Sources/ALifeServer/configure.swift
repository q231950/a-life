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

/// Sets the server up with a session per character in `cast`, played by
/// `players`. Each is as the environment says if `nil`: the cast is read
/// from the agents file, `ALIFE_AGENTS_FILE` or the shipped `agents.yaml`.
func configure(_ app: Application, players: Players? = nil, cast: [Character]? = nil) async throws {
    let cast = try cast ?? loadCast(logger: app.logger)
    let players = try players ?? Players.fromEnvironment(logger: app.logger)
    if case .claudeCode = players {
        reportCloudSession(for: cast, logger: app.logger)
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

/// Says where the cloud jobs go, if any character's instructions use
/// `ALIFE_CLOUD_SESSION`, such as the Engineer's. The characters' shells
/// inherit it from the server.
private func reportCloudSession(for cast: [Character], logger: Logger) {
    let names = cast
        .filter { $0.role.contains("ALIFE_CLOUD_SESSION") || $0.helper.prompt.contains("ALIFE_CLOUD_SESSION") }
        .map(\.name)
        .joined(separator: ", ")
    guard !names.isEmpty else { return }
    if let session = ProcessInfo.processInfo.environment["ALIFE_CLOUD_SESSION"], !session.isEmpty {
        logger.notice("Cloud jobs from \(names) go to the cloud session \(session)")
    } else {
        logger.warning("ALIFE_CLOUD_SESSION isn't set, so \(names) can't send jobs to the cloud. Set it to a session in the a*life cloud environment.")
    }
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
