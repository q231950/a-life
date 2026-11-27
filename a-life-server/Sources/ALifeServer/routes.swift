import ALifeAPI
import Vapor

extension SessionState: @retroactive Content {}
extension Lot: @retroactive Content {}
extension Usage: @retroactive Content {}
extension ModelOption: @retroactive Content {}
extension DeviceRegistration: @retroactive Content {}
extension InitialState: @retroactive Content {}

func routes(
    _ app: Application,
    team: Team,
    lot: LotHub,
    usage: UsageHub = UsageHub(file: nil),
    models: ModelCatalog = ModelCatalog(),
    voice: URL? = nil,
    push: PushNotifier = PushNotifier(registry: DeviceRegistry(file: nil), sender: nil, topic: nil)
) {
    /// The session a request names in its path.
    @Sendable func session(_ request: Request) async throws -> HostedSession {
        guard let id = request.parameters.get("session"), let session = await team.session(id) else {
            throw Abort(.notFound, reason: "No such session")
        }
        return session
    }

    app.get("health") { _ in
        ["status": "ok"]
    }

    // Everything as it is right now: every session, the lot and the usage.
    // Front ends take it on in one go when they launch or reconnect, then
    // follow each session's events from the `last_seq` it gives.
    app.get("v1", "init") { _ -> InitialState in
        var states: [SessionState] = []
        for session in await team.sessions {
            states.append(await session.hub.state)
        }
        return InitialState(sessions: states, lot: await lot.lot, usage: await usage.usage)
    }

    let all = app.grouped("v1", "sessions")

    // Every session as it is right now, one per character. Front ends read
    // this to learn who is on the lot, then follow each session's events.
    all.get { _ -> [SessionState] in
        var states: [SessionState] = []
        for session in await team.sessions {
            states.append(await session.hub.state)
        }
        return states
    }

    // Server-sent events: who is on the lot now, as a roster, then again each
    // time an agent joins or leaves, such as when the Team Lead adds one.
    // A front end that sees it differ from the sessions it follows takes on
    // everything again with `GET /v1/init`.
    all.get("events") { _ -> Response in
        eventStream(await team.subscribe()) { roster in
            try serverSentEvent(id: roster.revision, type: "roster", data: roster)
        }
    }

    let one = all.grouped(":session")

    // One session as it is right now. Handy with curl.
    one.get { request in
        try await session(request).hub.state
    }

    // Server-sent events: what the client missed, then live events.
    //   ?after=<seq>              the last sequence number the client has seen
    //   ?conversation=<id>        the conversation that number belongs to
    one.get("events") { request -> Response in
        let hub = try await session(request).hub
        let after = (try? request.query.get(Int.self, at: "after")) ?? 0
        let conversationID = try? request.query.get(String.self, at: "conversation")
        let events = await hub.subscribe(conversationID: conversationID, after: after)
        return eventStream(events) { envelope in
            try serverSentEvent(id: envelope.seq, type: envelope.event.type, data: envelope)
        }
    }

    one.post("messages") { request -> HTTPStatus in
        let backend = try await session(request).backend
        let body = try request.content.decode(SendMessageRequest.self)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Abort(.badRequest, reason: "The message is empty") }
        try await backend.handleMessage(text)
        return .accepted
    }

    one.post("interrupt") { request -> HTTPStatus in
        try await session(request).backend.interrupt()
        return .accepted
    }

    one.post("approvals", ":approval") { request -> HTTPStatus in
        let backend = try await session(request).backend
        let id = try request.parameters.require("approval")
        let decision = try request.content.decode(ApprovalDecision.self)
        try await backend.decide(approvalID: id, allow: decision.allow)
        return .accepted
    }

    // Auto approve, on or off, for this session only.
    one.put("auto-approve") { request -> HTTPStatus in
        let backend = try await session(request).backend
        let setting = try request.content.decode(AutoApproveRequest.self)
        await backend.setAutoApprove(setting.enabled)
        return .accepted
    }

    // The model the character runs on, for every front end; null goes back
    // to the agents file's.
    one.put("model") { request -> HTTPStatus in
        let backend = try await session(request).backend
        let choice = try request.content.decode(ModelChoiceRequest.self)
        try await backend.setModel(choice.model)
        return .accepted
    }

    one.post("reset") { request -> HTTPStatus in
        try await session(request).backend.reset()
        return .accepted
    }

    // The models a character can be switched to, strongest first, with the
    // versions they stand for once Claude Code has said.
    app.get("v1", "models") { _ -> [ModelOption] in
        await models.optionsWhenKnown()
    }

    // Everything the characters have built and planted on the lot.
    app.get("v1", "lot") { _ in
        await lot.lot
    }

    // Server-sent events: the lot as it is now, then the whole lot again
    // each time something on it changes.
    app.get("v1", "lot", "events") { _ -> Response in
        eventStream(await lot.subscribe()) { lot in
            try serverSentEvent(id: lot.revision, type: "lot", data: lot)
        }
    }

    // How much of Claude's 5-hour usage window is used, as the server last
    // heard from its characters' runs.
    app.get("v1", "usage") { _ in
        await usage.usage
    }

    // Server-sent events: the usage as it is now, then again each time it
    // changes.
    app.get("v1", "usage", "events") { _ -> Response in
        eventStream(await usage.subscribe()) { usage in
            try serverSentEvent(id: usage.revision, type: "usage", data: usage)
        }
    }

    // A device that wants to hear when a character finishes its work, by
    // its APNs token in hex. Registering again updates it and says it was
    // seen, so the app does it on every launch. Taken while notifications
    // are off, too, so the devices are there once they're on.
    let device = app.grouped("v1", "devices", ":token")

    /// The token a request names in its path, if it looks like one.
    @Sendable func deviceToken(_ request: Request) throws -> String {
        guard let token = request.parameters.get("token"), DeviceRegistry.isToken(token) else {
            throw Abort(.badRequest, reason: "That isn't a device token: it's the APNs token, in hex.")
        }
        return token.lowercased()
    }

    device.put { request -> DeviceRegistration in
        let token = try deviceToken(request)
        let registration = try request.content.decode(DeviceRegistrationRequest.self)
        guard registration.environment != .unknown else {
            throw Abort(.badRequest, reason: "The environment can be sandbox or production.")
        }
        if let topic = push.topic, registration.bundleID != topic {
            throw Abort(.badRequest, reason: "This server sends notifications for \(topic), not \(registration.bundleID). See Push notifications in a-life-server/README.md.")
        }
        await push.registry.register(token: token, registration)
        return DeviceRegistration(serverID: push.registry.serverID, pushEnabled: push.isEnabled)
    }

    device.delete { request -> HTTPStatus in
        let token = try deviceToken(request)
        await push.registry.unregister(token: token)
        return .noContent
    }

    // Sends the device a test notification, to see that it can be reached.
    device.post("test") { request -> HTTPStatus in
        guard push.isEnabled else {
            throw Abort(.serviceUnavailable, reason: "This server isn't set up to send notifications. See Push notifications in a-life-server/README.md.")
        }
        let token = try deviceToken(request)
        guard let registered = await push.registry.device(token) else {
            throw Abort(.notFound, reason: "That device isn't registered for notifications.")
        }
        switch await push.sendTest(to: registered) {
        case .delivered:
            return .noContent
        case .goneForGood:
            throw Abort(.gone, reason: "Apple says the device's token is no longer valid, so it was forgotten. Register it again.")
        case .failed(let reason):
            throw Abort(.badGateway, reason: "Apple didn't take the notification: \(reason)")
        case nil:
            throw Abort(.serviceUnavailable, reason: "This server isn't set up to send notifications.")
        }
    }

    // The voice model the front ends speak the characters' lines with: a
    // Phonon model bundle, `bundle.json` and the files it lists, served as
    // they are from `voice`. Not found if there's no model there.
    app.get("v1", "voice", "**") { request -> Response in
        guard let voice, let file = voiceFile(at: request.url.path, in: voice) else {
            throw Abort(.notFound, reason: "The server has no voice model. See Voices in a-life-server/README.md.")
        }
        return try await request.fileio.asyncStreamFile(at: file.path)
    }
}

/// The file in the voice model directory `voice` that `path`, such as
/// `/v1/voice/voices/Sir%20Bramwell.safetensors`, asks for, if there is
/// one. Nothing outside `voice` is ever served, nor any hidden file.
func voiceFile(at path: String, in voice: URL) -> URL? {
    let prefix = "/v1/voice/"
    guard path.hasPrefix(prefix) else { return nil }
    var file = voice
    for component in path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false) {
        guard let name = String(component).removingPercentEncoding,
              !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else { return nil }
        file.appendPathComponent(name)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
    return file
}

/// A `text/event-stream` response with a frame for each of `events`, and a
/// heartbeat in between, until `events` ends or the client goes away.
private func eventStream<Event: Sendable>(
    _ events: AsyncStream<Event>,
    frame: @escaping @Sendable (Event) throws -> String
) -> Response {
    let response = Response(status: .ok)
    response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    response.body = .init(asyncStream: { writer in
        // Events and heartbeats are funnelled into one stream of frames,
        // so there is a single writer.
        let (frames, sink) = AsyncStream<String>.makeStream()
        let forwarding = Task {
            for await event in events {
                sink.yield(try frame(event))
            }
            sink.finish()
        }
        // A comment line every so often keeps proxies from closing an
        // idle connection, and shows up a client that has gone away.
        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(15))
                sink.yield(": ping\n\n")
            }
        }
        defer {
            forwarding.cancel()
            heartbeat.cancel()
        }
        do {
            try await writer.write(.buffer(ByteBuffer(string: ": connected\n\n")))
            for await frame in frames {
                try await writer.write(.buffer(ByteBuffer(string: frame)))
            }
            try await writer.write(.end)
        } catch {
            try? await writer.write(.error(error)) // the client went away
        }
    })
    return response
}

/// One event in `text/event-stream` framing.
private func serverSentEvent(id: Int, type: String, data: some Encodable) throws -> String {
    let json = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
    return "id: \(id)\nevent: \(type)\ndata: \(json)\n\n"
}
