import ALifeAPI
import Vapor

extension SessionState: @retroactive Content {}
extension Lot: @retroactive Content {}

func routes(_ app: Application, sessions: [HostedSession], lot: LotHub, voice: URL? = nil) {
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

    /// The session a request names in its path.
    @Sendable func session(_ request: Request) throws -> HostedSession {
        guard let id = request.parameters.get("session"), let session = byID[id] else {
            throw Abort(.notFound, reason: "No such session")
        }
        return session
    }

    app.get("health") { _ in
        ["status": "ok"]
    }

    let all = app.grouped("v1", "sessions")

    // Every session as it is right now, one per character. Front ends read
    // this to learn who is on the lot, then follow each session's events.
    all.get { _ -> [SessionState] in
        var states: [SessionState] = []
        for session in sessions {
            states.append(await session.hub.state)
        }
        return states
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
        let hub = try session(request).hub
        let after = (try? request.query.get(Int.self, at: "after")) ?? 0
        let conversationID = try? request.query.get(String.self, at: "conversation")
        let events = await hub.subscribe(conversationID: conversationID, after: after)
        return eventStream(events) { envelope in
            try serverSentEvent(id: envelope.seq, type: envelope.event.type, data: envelope)
        }
    }

    one.post("messages") { request -> HTTPStatus in
        let backend = try session(request).backend
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
        let backend = try session(request).backend
        let id = try request.parameters.require("approval")
        let decision = try request.content.decode(ApprovalDecision.self)
        try await backend.decide(approvalID: id, allow: decision.allow)
        return .accepted
    }

    // Auto approve, on or off, for this session only.
    one.put("auto-approve") { request -> HTTPStatus in
        let backend = try session(request).backend
        let setting = try request.content.decode(AutoApproveRequest.self)
        await backend.setAutoApprove(setting.enabled)
        return .accepted
    }

    one.post("reset") { request -> HTTPStatus in
        try await session(request).backend.reset()
        return .accepted
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
