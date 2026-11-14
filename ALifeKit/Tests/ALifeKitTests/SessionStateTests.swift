import ALifeAPI
import XCTest

final class SessionStateTests: XCTestCase {
    func testEventsSurviveARoundTripThroughJSON() throws {
        let events: [SessionEvent] = [
            .conversationStarted(conversationID: "c1"),
            .statusChanged(.idle, stopReason: .requiresAction),
            .statusChanged(.running, stopReason: nil),
            .activityChanged("bash"),
            .activityChanged(nil),
            .message(Message(id: "m1", kind: .agent, speaker: "Gardener", text: "Trimmed the bushes")),
            .approvalRequested(Approval(id: "p1", toolName: "bash", input: "ls")),
            .approvalResolved(approvalID: "p1"),
            .subagentStarted(Subagent(id: "s1", task: "Search the flower beds")),
            .subagentFinished(subagentID: "s1"),
        ]
        for (index, event) in events.enumerated() {
            let envelope = EventEnvelope(seq: index + 1, event: event)
            let decoded = try JSONDecoder().decode(EventEnvelope.self, from: JSONEncoder().encode(envelope))
            XCTAssertEqual(decoded, envelope)
        }
    }

    func testWireFormatUsesSnakeCaseAndATypeField() throws {
        let approval = Approval(id: "p1", toolName: "bash", input: "ls")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EventEnvelope(seq: 7, event: .approvalRequested(approval)))) as? [String: Any]
        let event = json?["event"] as? [String: Any]
        XCTAssertEqual(json?["seq"] as? Int, 7)
        XCTAssertEqual(event?["type"] as? String, "approval.requested")
        XCTAssertEqual((event?["approval"] as? [String: Any])?["tool_name"] as? String, "bash")

        let started = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionEvent.subagentStarted(Subagent(id: "s1", task: "Count the snails")))) as? [String: Any]
        XCTAssertEqual(started?["type"] as? String, "subagent.started")
        XCTAssertEqual((started?["subagent"] as? [String: Any])?["task"] as? String, "Count the snails")
        let finished = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionEvent.subagentFinished(subagentID: "s1"))) as? [String: Any]
        XCTAssertEqual(finished?["type"] as? String, "subagent.finished")
        XCTAssertEqual(finished?["subagent_id"] as? String, "s1")

        var state = SessionState(id: "builder", name: "Builder")
        state.apply(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "c1")))
        state.apply(EventEnvelope(seq: 2, event: .statusChanged(.idle, stopReason: .endTurn)))
        let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertEqual(snapshot?["id"] as? String, "builder")
        XCTAssertEqual(snapshot?["name"] as? String, "Builder")
        XCTAssertEqual(snapshot?["conversation_id"] as? String, "c1")
        XCTAssertEqual(snapshot?["stop_reason"] as? String, "end_turn")
        XCTAssertEqual(snapshot?["last_seq"] as? Int, 2)
    }

    func testUnknownEventsAndValuesAreTolerated() throws {
        let json = #"[{"seq":1,"event":{"type":"weather.changed","sky":"rain"}},{"seq":2,"event":{"type":"session.status","status":"napping","stop_reason":"bored"}}]"#
        let envelopes = try JSONDecoder().decode([EventEnvelope].self, from: Data(json.utf8))
        XCTAssertEqual(envelopes.map(\.event), [.unknown(type: "weather.changed"), .statusChanged(.unknown, stopReason: .unknown)])
    }

    func testASnapshotFromBeforeThereWereHelpersStillDecodes() throws {
        let json = #"{"id":"gardener","name":"Gardener","status":"idle","messages":[],"approvals":[],"last_seq":3}"#
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertEqual(state.id, "gardener")
        XCTAssertEqual(state.lastSeq, 3)
        XCTAssertTrue(state.subagents.isEmpty)
    }

    func testHelpersComeAndGo() {
        var state = SessionState(id: "gardener", name: "Gardener")
        let beds = Subagent(id: "s1", task: "Search the flower beds")
        let snails = Subagent(id: "s2", task: "Count the snails")
        let events: [SessionEvent] = [
            .conversationStarted(conversationID: "c1"),
            .subagentStarted(beds),
            .subagentStarted(snails),
            .subagentStarted(beds), // a repeat changes nothing
        ]
        for (index, event) in events.enumerated() {
            state.apply(EventEnvelope(seq: index + 1, event: event))
        }
        XCTAssertEqual(state.subagents, [beds, snails])

        // One that has reported back is no longer listed.
        state.apply(EventEnvelope(seq: 5, event: .subagentFinished(subagentID: "s1")))
        XCTAssertEqual(state.subagents, [snails])

        // A new conversation has no helpers out.
        state.apply(EventEnvelope(seq: 6, event: .conversationStarted(conversationID: "c2")))
        XCTAssertTrue(state.subagents.isEmpty)
    }

    func testApplyingEventsBuildsTheState() {
        var state = SessionState(id: "builder", name: "Builder")
        let approval = Approval(id: "p1", toolName: "bash", input: "ls")
        let events: [SessionEvent] = [
            .conversationStarted(conversationID: "c1"),
            .message(Message(id: "m1", kind: .user, speaker: "You", text: "Move the shed")),
            .message(Message(id: "m1", kind: .user, speaker: "You", text: "Move the shed")), // a repeat changes nothing
            .statusChanged(.running, stopReason: nil),
            .activityChanged("read"),
            .activityChanged(nil),
            .approvalRequested(approval),
            .statusChanged(.idle, stopReason: .requiresAction),
        ]
        for (index, event) in events.enumerated() {
            state.apply(EventEnvelope(seq: index + 1, event: event))
        }
        XCTAssertEqual(state.conversationID, "c1")
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.stopReason, .requiresAction)
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.approvals, [approval])
        XCTAssertEqual(state.lastSeq, 8)

        state.apply(EventEnvelope(seq: 9, event: .approvalResolved(approvalID: "p1")))
        state.apply(EventEnvelope(seq: 10, event: .activityChanged("bash")))
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertEqual(state.activity, "bash")

        // A new conversation wipes what was known about the old one, but the
        // session is still the same character's.
        state.apply(EventEnvelope(seq: 11, event: .conversationStarted(conversationID: "c2")))
        XCTAssertEqual(state.id, "builder")
        XCTAssertEqual(state.name, "Builder")
        XCTAssertEqual(state.conversationID, "c2")
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.activity)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.lastSeq, 11)
    }
}
