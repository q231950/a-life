import ALifeAPI
import Vapor

extension SessionState: @retroactive Content {}

func routes(_ app: Application, hub: SessionHub, team: any TeamBackend) {
    app.get("health") { _ in
        ["status": "ok"]
    }

    let session = app.grouped("v1", "session")

    // The session as it is right now. Handy with curl; front ends follow
    // the event stream instead.
    session.get { _ in
        await hub.state
    }

    // Server-sent events: what the client missed, then live events.
    //   ?after=<seq>      the last sequence number the client has seen
    //   ?session=<id>     the session that number belongs to
    session.get("events") { request -> Response in
        let after = (try? request.query.get(Int.self, at: "after")) ?? 0
        let sessionID = try? request.query.get(String.self, at: "session")
        let events = await hub.subscribe(sessionID: sessionID, after: after)

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

    session.post("messages") { request -> HTTPStatus in
        let body = try request.content.decode(SendMessageRequest.self)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Abort(.badRequest, reason: "The message is empty") }
        await team.handleMessage(text)
        return .accepted
    }

    session.post("interrupt") { request -> HTTPStatus in
        // The body is optional: no body stops the whole team.
        let body = try? request.content.decode(InterruptRequest.self)
        await team.interrupt(agentID: body?.agentID)
        return .accepted
    }

    session.post("approvals", ":id") { request -> HTTPStatus in
        let id = try request.parameters.require("id")
        let decision = try request.content.decode(ApprovalDecision.self)
        try await team.decide(approvalID: id, allow: decision.allow)
        return .accepted
    }

    session.post("reset") { _ -> HTTPStatus in
        await team.reset()
        return .accepted
    }
}

/// One event in `text/event-stream` framing.
private func serverSentEvent(_ envelope: EventEnvelope) throws -> String {
    let json = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    return "id: \(envelope.seq)\nevent: \(envelope.event.type)\ndata: \(json)\n\n"
}
