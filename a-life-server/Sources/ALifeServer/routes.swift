import ALifeAPI
import Vapor

extension SessionState: @retroactive Content {}

func routes(_ app: Application, sessions: [HostedSession]) {
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

        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.body = .init(asyncStream: { writer in
            // Events and heartbeats are funnelled into one stream of frames,
            // so there is a single writer.
            let (frames, sink) = AsyncStream<String>.makeStream()
            let forwarding = Task {
                for await envelope in events {
                    sink.yield(try serverSentEvent(envelope))
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

    one.post("reset") { request -> HTTPStatus in
        try await session(request).backend.reset()
        return .accepted
    }
}

/// One event in `text/event-stream` framing.
private func serverSentEvent(_ envelope: EventEnvelope) throws -> String {
    let json = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    return "id: \(envelope.seq)\nevent: \(envelope.event.type)\ndata: \(json)\n\n"
}
