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
    /// - `ALIFE_PROJECTS_DIR`: where the projects that are git repositories
    ///   are cloned, a directory per character. `~/a-life-projects` unless set.
    ///
    /// It clones each such project that isn't cloned yet, and says where
    /// each character works.
    static func fromEnvironment(for cast: [Character], lot: URL, logger: Logger) throws -> Players {
        let environment = ProcessInfo.processInfo.environment
        if let model = environment["ALIFE_CLAUDE_MODEL"], !model.isEmpty {
            // It chose the model for every character, before each had its own.
            logger.warning("ALIFE_CLAUDE_MODEL (\(model)) isn't read any more: give each agent a model in the agents file, or choose one in the app")
        }
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
            logger.notice("The characters are Claude Code sessions (\(executable.path))")
            var claudeCode = ClaudeCode(executable: executable, lot: lot, repository: repository)
            // So the Team Lead can see who is on the lot, and add agents to it
            // and take them away.
            claudeCode.agentsFile = Cast.file(in: environment)
            claudeCode.addedAgentsFile = Cast.addedFile(in: environment)
            claudeCode.serverCommand = Bundle.main.executableURL
            for character in cast {
                prepare(character, for: &claudeCode, logger: logger)
            }
            return .claudeCode(claudeCode)
        case let other:
            throw ConfigurationError("ALIFE_BACKEND is \(other); it can be claude or dummy.")
        }
    }


    /// Gets `character` ready to start in `claudeCode`: says where it works,
    /// and clones its project first if that is a git repository (or several)
    /// that isn't cloned yet. A clone that fails only keeps its own
    /// character from starting. Used for each character when the server
    /// starts, and for each one that joins the lot later.
    static func prepare(_ character: Character, for claudeCode: inout ClaudeCode, logger: Logger) {
        let lot = claudeCode.lot
        let repository = claudeCode.repository
        let projects = ClaudeCode.projectsDirectory(in: ProcessInfo.processInfo.environment)
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
            case .repositories(let repositories):
                // As with one repository: if any can't be cloned,
                // only this character is kept from starting.
                var problems: [String] = []
                for (repository, checkout) in zip(repositories, ClaudeCode.checkOut(repositories, for: project.id, in: projects)) {
                    switch checkout {
                    case .success(.cloned(let clone)):
                        logger.notice("\(name) works on \(repository.address), cloned just now into \(clone.path)")
                    case .success(.reused(let clone)):
                        logger.notice("\(name) works on \(repository.address), in its clone from before, \(clone.path), as it is")
                    case .failure(let problem):
                        logger.error("\(name) can't start until this is fixed: \(problem)")
                        if !problems.contains(problem.description) { problems.append(problem.description) }
                    }
                }
                let directory = projects.appendingPathComponent(project.id, isDirectory: true)
                if problems.isEmpty {
                    logger.notice("\(name) works on its \(repositories.count) repos side by side, in \(directory.path)")
                    claudeCode.clones[project.id] = .success(directory)
                } else {
                    claudeCode.clones[project.id] = .failure(ConfigurationError(problems.joined(separator: " ")))
                }
            }
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

    /// Where the server keeps what it must remember between starts, such as
    /// the characters waiting for the usage limit to reset
    /// (`continues.json`), the last usage reading (`usage.json`), the
    /// models chosen in the app (`models.json`) and the devices registered
    /// for notifications (`devices.json`):
    /// `ALIFE_STATE_DIR`, or `~/a-life-state` unless it
    /// is set. It is made when there is something to keep.
    static func stateDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["ALIFE_STATE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-state", isDirectory: true)
    }

    /// Where the voice model the front ends speak with is: `ALIFE_VOICE_DIR`,
    /// or `~/a-life-voice` unless it is set. It may not be there at all.
    static func voiceDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["ALIFE_VOICE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-voice")
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// How the server sends push notifications: what sends them, or `nil` while
/// they're off, and the app's bundle id devices must register with, if it
/// is known.
struct PushSetup: Sendable {
    var sender: (any PushSender)?
    var topic: String?

    /// No notifications, and any bundle id may register.
    static let off = PushSetup(sender: nil, topic: nil)

    /// From the `ALIFE_APNS_*` settings: notifications through Apple if all
    /// four are set, or else off, saying why.
    static func fromEnvironment(_ app: Application) -> PushSetup {
        let settings = PushSettings.read()
        guard let credentials = settings.credentials else {
            app.logger.notice("\(settings.problem ?? "Push notifications are off. See Push notifications in the README.")")
            return PushSetup(sender: nil, topic: settings.topic)
        }
        app.logger.notice("Push notifications are on, for \(credentials.topic), with key \(credentials.keyID)")
        let sender = APNSPushSender(credentials: credentials, eventLoopGroup: app.eventLoopGroup, logger: app.logger)
        return PushSetup(sender: sender, topic: credentials.topic)
    }
}

/// Sets the server up with a session per character in `cast`, played by
/// `players`, the lot in `lotDirectory`, the voice model in
/// `voiceDirectory`, what it remembers between starts in `stateDirectory`,
/// and push notifications as `push` says. Each is as the environment says
/// if `nil`: the cast is the built-in agents, the agents file's and the
/// added agents file's (see `Cast`), the lot is `ALIFE_LOT_DIR`, the voice
/// model `ALIFE_VOICE_DIR`, the state `ALIFE_STATE_DIR` and push
/// notifications the `ALIFE_APNS_*` settings. Given `players` but no
/// `lotDirectory`, the lot stays empty, with no `voiceDirectory` there's no
/// voice model either, with no `stateDirectory` nothing is remembered, and
/// with no `push` no notifications are sent.
///
/// A `cast` that is given is everyone there is, and nobody joins or leaves
/// the lot unless `addedAgentsFile` names a file to watch, every
/// `teamWatchInterval`, for agents the Team Lead adds.
func configure(
    _ app: Application,
    players playersGiven: Players? = nil,
    cast: [Character]? = nil,
    addedAgentsFile: URL? = nil,
    lotDirectory: URL? = nil,
    voiceDirectory: URL? = nil,
    stateDirectory: URL? = nil,
    push pushGiven: PushSetup? = nil,
    lotSurveyInterval: Duration = .seconds(1),
    teamWatchInterval: Duration = .seconds(1)
) async throws {
    let layers: Cast.Layers
    var addedFile = addedAgentsFile
    if let cast {
        layers = Cast.Layers(builtIn: cast, own: [], added: [])
    } else {
        layers = try loadCast(logger: app.logger)
        addedFile = Cast.addedFile(in: ProcessInfo.processInfo.environment)
    }
    let cast = layers.all
    var lotDirectory = lotDirectory
    var voiceDirectory = voiceDirectory
    var stateDirectory = stateDirectory
    let players: Players
    if let given = playersGiven {
        players = given
    } else {
        let directory = try lotDirectory ?? Players.lotDirectory()
        lotDirectory = directory
        voiceDirectory = voiceDirectory ?? Players.voiceDirectory()
        stateDirectory = stateDirectory ?? Players.stateDirectory()
        players = try Players.fromEnvironment(for: cast, lot: directory, logger: app.logger)
    }
    let pushSetup = pushGiven ?? (playersGiven == nil ? PushSetup.fromEnvironment(app) : .off)

    // The characters' voices, for the front ends to download.
    if let voiceDirectory {
        if FileManager.default.fileExists(atPath: voiceDirectory.appendingPathComponent("bundle.json").path) {
            app.logger.notice("The characters speak with the voice model in \(voiceDirectory.path)")
        } else {
            app.logger.notice("There's no voice model in \(voiceDirectory.path), so the characters don't speak. See Voices in the README.")
        }
    }

    // What the characters build and plant shows up in the front ends.
    let lot = LotHub(directory: lotDirectory)
    if let lotDirectory {
        app.logger.notice("The lot is in \(lotDirectory.path). What's built in buildings/ and planted in garden/ there shows in the front ends.")
        await lot.survey()
        await lot.watch(every: lotSurveyInterval)
    }

    // Who was waiting for the usage limit to reset when the server stopped.
    let continues = PendingContinues(file: stateDirectory?.appendingPathComponent("continues.json"), logger: app.logger)
    let waiting = await continues.all
    if let file = continues.file, !waiting.isEmpty {
        app.logger.notice("Waiting for the usage limit to reset, from \(file.path): \(waiting.keys.sorted().joined(separator: ", "))")
    }

    // How much of the 5-hour usage window is used, as the characters' runs
    // say, and as it was when the server stopped. The dummies' made-up
    // readings aren't kept.
    var usageFile: URL?
    if case .claudeCode = players { usageFile = stateDirectory?.appendingPathComponent("usage.json") }
    let usage = UsageHub(file: usageFile, logger: app.logger)
    if let file = usageFile, let window = await usage.usage.window {
        app.logger.notice("The last usage reading, from \(file.path): \(window.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown") used, resetting at \(window.resetsAt)")
    }

    // The models chosen in the app, which outlast a restart; the dummies'
    // aren't kept. And which versions the models stand for, as the
    // server's Claude Code says.
    var choicesFile: URL?
    if case .claudeCode = players { choicesFile = stateDirectory?.appendingPathComponent("models.json") }
    let choices = ModelChoices(file: choicesFile, logger: app.logger)
    let models = ModelCatalog()
    if case .claudeCode(let claudeCode) = players {
        await models.ask(claudeCode, logger: app.logger)
    }

    /// Makes the session of `character`: its hub, and what plays it. One
    /// that joins the lot while the server runs gets prepared first, as the
    /// ones there at the start were (`Players.prepare`).
    @Sendable func makeSession(_ character: Character, joining: Bool) async -> HostedSession {
        let model = await choices.model(for: character)
        if model != character.model, let model {
            app.logger.notice("\(character.name) runs on \(model.rawValue), as chosen in the app, rather than the agents file's \(character.model?.rawValue ?? "default")")
        }
        let hub = SessionHub(id: character.id, name: character.name, color: character.color, model: model, fileModel: character.model)
        // The one place that chooses what plays each character.
        let backend: any SessionBackend
        switch players {
        case .claudeCode(var launcher):
            if joining, let claudeCode = launcher as? ClaudeCode {
                // Cloning can take a while, so not on the team's own time.
                let logger = app.logger
                launcher = await Task.detached {
                    var prepared = claudeCode
                    Players.prepare(character, for: &prepared, logger: logger)
                    return prepared
                }.value
            }
            backend = ClaudeCharacter(
                character, hub: hub, claudeCode: launcher, logger: app.logger, continues: continues, usage: usage,
                model: model, choices: choices, models: models
            )
        case .dummies(let step):
            backend = DummyCharacter(character, hub: hub, step: step, usage: usage)
        }
        await backend.reset() // starts the first conversation, and forgets what it waited for
        if !joining, let claude = backend as? ClaudeCharacter, let entry = waiting[character.id] {
            await claude.carryOn(after: entry)
        }
        return HostedSession(id: character.id, hub: hub, backend: backend)
    }

    var sessions: [HostedSession] = []
    for character in cast {
        sessions.append(await makeSession(character, joining: false))
    }

    // The devices registered for notifications, and telling them when any
    // character finishes its work. They're kept whoever plays the
    // characters, since they're the phones', not the characters'.
    let devices = DeviceRegistry(file: stateDirectory?.appendingPathComponent("devices.json"), logger: app.logger)
    let push = PushNotifier(registry: devices, sender: pushSetup.sender, topic: pushSetup.topic, logger: app.logger)
    await push.follow(sessions)
    if push.isEnabled {
        let count = await devices.all.count
        app.logger.notice("\(count) device(s) registered for notifications")
    }

    // Who is on the lot from here on: agents the Team Lead adds join it,
    // and ones it takes away leave it, as the added agents file says.
    let team = Team(
        sessions: sessions, cast: layers, ownSource: Cast.file(in: ProcessInfo.processInfo.environment).path, addedFile: addedFile,
        make: { await makeSession($0, joining: true) },
        joined: { await push.follow([$0]) },
        left: { await push.unfollow($0.id) },
        logger: app.logger
    )
    if let addedFile {
        app.logger.notice("The agents the Team Lead adds are in \(addedFile.path); they join and leave the lot as it changes")
        await team.watch(every: teamWatchInterval)
    }

    app.lifecycle.use(EndSessionsOnShutdown(team: team, lot: lot, usage: usage, push: push))
    routes(app, team: team, lot: lot, usage: usage, models: models, voice: voiceDirectory, push: push)
}

/// The cast: the built-in agents, the agents file's (see `Cast.file(in:)`)
/// and the added agents file's (see `Cast.addedFile(in:)`), each of which
/// may not be there. Says in the log who is on the lot, and warns about each
/// entry in either file that is a built-in agent, which is left out.
private func loadCast(logger: Logger) throws -> Cast.Layers {
    let environment = ProcessInfo.processInfo.environment
    let agentsFile = Cast.file(in: environment)
    let addedFile = Cast.addedFile(in: environment)
    let layers = try Cast.layers(in: environment, warn: { logger.warning("\($0)") })
    logger.notice("On the lot: \(layers.all.map(\.name).joined(separator: ", "))")
    logger.notice("Built in: \(layers.builtIn.map(\.name).joined(separator: ", "))")
    if !FileManager.default.fileExists(atPath: agentsFile.path) {
        logger.notice("There's no agents file at \(agentsFile.path), so only the built-in agents and the added ones are on the lot")
    } else {
        logger.notice("From the agents file \(agentsFile.path): \(layers.own.isEmpty ? "no agents" : layers.own.map(\.name).joined(separator: ", "))")
    }
    logger.notice("From the added agents file \(addedFile.path): \(layers.added.isEmpty ? "no agents" : layers.added.map(\.name).joined(separator: ", "))")
    return layers
}

/// When the server stops, ends the open event streams, so shutdown doesn't
/// wait on clients that are still listening, and stops each session,
/// watching the lot and the team, and sending notifications.
private struct EndSessionsOnShutdown: LifecycleHandler {
    let team: Team
    let lot: LotHub
    let usage: UsageHub
    let push: PushNotifier

    func shutdownAsync(_ application: Application) async {
        await team.stop()
        await lot.stop()
        await usage.stop()
        await push.stop()
        for session in await team.sessions {
            await session.hub.closeStreams()
            await session.backend.shutdown()
        }
    }
}
