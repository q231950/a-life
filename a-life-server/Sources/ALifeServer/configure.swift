import Vapor

/// The characters on the lot. Each one gets a session of its own.
let cast = [
    DummyCharacter.Profile(id: "gardener", name: "Gardener", changesThings: false),
    DummyCharacter.Profile(id: "builder", name: "Builder", changesThings: true),
]

/// Sets the server up with a session per character, each played by a dummy.
///
/// `dummyStep` is how long each step of a dummy's script takes. It defaults
/// to `ALIFE_DUMMY_STEP_MS` from the environment, or 1.5 seconds.
func configure(_ app: Application, dummyStep: Duration? = nil) async throws {
    let step = dummyStep
        ?? Environment.get("ALIFE_DUMMY_STEP_MS").flatMap(Int.init).map(Duration.milliseconds)
        ?? .milliseconds(1500)

    var sessions: [HostedSession] = []
    for profile in cast {
        let hub = SessionHub(id: profile.id, name: profile.name)
        // The one place to swap in a real session later.
        let backend: any SessionBackend = DummyCharacter(profile, hub: hub, step: step)
        await backend.reset() // starts the first conversation
        sessions.append(HostedSession(id: profile.id, hub: hub, backend: backend))
    }

    app.lifecycle.use(CloseStreamsOnShutdown(hubs: sessions.map(\.hub)))
    routes(app, sessions: sessions)
}

/// Ends the open event streams when the server stops, so shutdown doesn't
/// wait on clients that are still listening.
private struct CloseStreamsOnShutdown: LifecycleHandler {
    let hubs: [SessionHub]

    func shutdownAsync(_ application: Application) async {
        for hub in hubs {
            await hub.closeStreams()
        }
    }
}
