import ALifeAPI
import XCTest

final class SessionStateTests: XCTestCase {
    func testEventsSurviveARoundTripThroughJSON() throws {
        let events: [SessionEvent] = [
            .sessionStarted(sessionID: "s1"),
            .statusChanged(.idle, stopReason: .requiresAction),
            .statusChanged(.running, stopReason: nil),
            .agentUpdated(Agent(id: "a1", name: "Team lead", status: .running, isCoordinator: true, activity: "bash")),
            .agentRemoved(agentID: "a1"),
            .message(Message(id: "m1", kind: .handoff, speaker: "Team lead → Gardener", text: "Trim the bushes")),
            .approvalRequested(Approval(id: "p1", agentID: "a2", agentName: "Builder", toolName: "bash", input: "ls")),
            .approvalResolved(approvalID: "p1"),
        ]
        for (index, event) in events.enumerated() {
            let envelope = EventEnvelope(seq: index + 1, event: event)
            let decoded = try JSONDecoder().decode(EventEnvelope.self, from: JSONEncoder().encode(envelope))
            XCTAssertEqual(decoded, envelope)
        }
    }

    func testWireFormatUsesSnakeCaseAndATypeField() throws {
        let agent = Agent(id: "a1", name: "Team lead", status: .idle, isCoordinator: true)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EventEnvelope(seq: 7, event: .agentUpdated(agent)))) as? [String: Any]
        let event = json?["event"] as? [String: Any]
        XCTAssertEqual(json?["seq"] as? Int, 7)
        XCTAssertEqual(event?["type"] as? String, "agent.updated")
        XCTAssertEqual((event?["agent"] as? [String: Any])?["is_coordinator"] as? Bool, true)
    }

    func testUnknownEventsAndValuesAreTolerated() throws {
        let json = #"[{"seq":1,"event":{"type":"weather.changed","sky":"rain"}},{"seq":2,"event":{"type":"session.status","status":"napping","stop_reason":"bored"}}]"#
        let envelopes = try JSONDecoder().decode([EventEnvelope].self, from: Data(json.utf8))
        XCTAssertEqual(envelopes.map(\.event), [.unknown(type: "weather.changed"), .statusChanged(.unknown, stopReason: .unknown)])
    }

    func testApplyingEventsBuildsTheState() {
        var state = SessionState()
        let lead = Agent(id: "lead", name: "Team lead", isCoordinator: true)
        let approval = Approval(id: "p1", agentID: "b", agentName: "Builder", toolName: "bash", input: "ls")
        let events: [SessionEvent] = [
            .sessionStarted(sessionID: "s1"),
            .agentUpdated(lead),
            .message(Message(id: "m1", kind: .user, speaker: "You", text: "Hi")),
            .message(Message(id: "m1", kind: .user, speaker: "You", text: "Hi")), // a repeat changes nothing
            .statusChanged(.running, stopReason: nil),
            .agentUpdated(Agent(id: "lead", name: "Team lead", status: .running, isCoordinator: true)),
            .agentUpdated(Agent(id: "b", name: "Builder")),
            .approvalRequested(approval),
        ]
        for (index, event) in events.enumerated() {
            state.apply(EventEnvelope(seq: index + 1, event: event))
        }
        XCTAssertEqual(state.sessionID, "s1")
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.agents.map(\.name), ["Team lead", "Builder"])
        XCTAssertEqual(state.agents.first?.status, .running)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.approvals, [approval])
        XCTAssertEqual(state.lastSeq, 8)

        state.apply(EventEnvelope(seq: 9, event: .approvalResolved(approvalID: "p1")))
        state.apply(EventEnvelope(seq: 10, event: .agentRemoved(agentID: "b")))
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertEqual(state.agents, [Agent(id: "lead", name: "Team lead", status: .running, isCoordinator: true)])

        // A new session wipes what was known about the old one.
        state.apply(EventEnvelope(seq: 11, event: .sessionStarted(sessionID: "s2")))
        XCTAssertEqual(state.sessionID, "s2")
        XCTAssertTrue(state.agents.isEmpty && state.messages.isEmpty)
        XCTAssertEqual(state.lastSeq, 11)
    }
}
