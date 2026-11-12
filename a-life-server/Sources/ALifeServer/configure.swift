import Vapor

/// Sets the server up with the dummy team.
///
/// `dummyStep` is how long each step of the dummy team's script takes. It
/// defaults to `ALIFE_DUMMY_STEP_MS` from the environment, or 1.5 seconds.
func configure(_ app: Application, dummyStep: Duration? = nil) async throws {
    let step = dummyStep
        ?? Environment.get("ALIFE_DUMMY_STEP_MS").flatMap(Int.init).map(Duration.milliseconds)
        ?? .milliseconds(1500)

    let hub = SessionHub()
    // The one place to swap in a real team later.
    let team: any TeamBackend = DummyTeam(hub: hub, step: step)
    await team.reset() // starts the first session

    app.lifecycle.use(CloseStreamsOnShutdown(hub: hub))
    routes(app, hub: hub, team: team)
}

/// Ends the open event streams when the server stops, so shutdown doesn't
/// wait on clients that are still listening.
private struct CloseStreamsOnShutdown: LifecycleHandler {
    let hub: SessionHub

    func shutdownAsync(_ application: Application) async {
        await hub.closeStreams()
    }
}
