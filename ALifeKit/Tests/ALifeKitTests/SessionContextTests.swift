import ALifeAPI
@testable import ALifeClient
import XCTest

/// How full a character's session is: on the wire, in the session's state,
/// and as the context panel reads it.
final class SessionContextTests: XCTestCase {
    private let full = SessionContext(model: "claude-opus-4-7", usedTokens: 84_213, compactsAt: 167_000, contextWindow: 200_000, autoCompact: true)

    // MARK: The wire

    func testTheContextTravelsAsSnakeCase() throws {
        let envelope = EventEnvelope(seq: 7, event: .contextChanged(full))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        let event = json?["event"] as? [String: Any]
        XCTAssertEqual(event?["type"] as? String, "session.context")
        let context = event?["context"] as? [String: Any]
        XCTAssertEqual(context?["model"] as? String, "claude-opus-4-7")
        XCTAssertEqual(context?["used_tokens"] as? Int, 84_213)
        XCTAssertEqual(context?["compacts_at"] as? Int, 167_000)
        XCTAssertEqual(context?["context_window"] as? Int, 200_000)
        XCTAssertEqual(context?["auto_compact"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(EventEnvelope.self, from: JSONEncoder().encode(envelope)), envelope)
    }

    func testAContextSaysOnlyWhatItKnows() throws {
        let json = #"{"seq":2,"event":{"type":"session.context","context":{"model":"claude-opus-4-7","used_tokens":"lots","mood":"calm"}}}"#
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.event, .contextChanged(SessionContext(model: "claude-opus-4-7")))

        let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionContext())) as? [String: Any]
        XCTAssertEqual(empty?.isEmpty, true)
    }

    // MARK: The session's state

    func testTheSessionKeepsItsContextUntilItStartsOver() throws {
        var state = SessionState(id: "builder", name: "Builder")
        state.apply(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "c1")))
        XCTAssertNil(state.context)
        state.apply(EventEnvelope(seq: 2, event: .contextChanged(full)))
        XCTAssertEqual(state.context, full)

        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.context, full)

        state.apply(EventEnvelope(seq: 3, event: .conversationStarted(conversationID: "c2")))
        XCTAssertNil(state.context)
    }

    func testASnapshotFromBeforeThereWasAContextStillDecodes() throws {
        let old = #"{"id":"builder","name":"Builder","status":"idle","messages":[],"approvals":[],"last_seq":4}"#
        let state = try JSONDecoder().decode(SessionState.self, from: Data(old.utf8))
        XCTAssertNil(state.context)
    }

    // MARK: Reading it

    func testItIsMeasuredAgainstTheCompactionPoint() {
        XCTAssertEqual(full.measure, .compaction(at: 167_000))
        XCTAssertEqual(full.percent, 50)
        XCTAssertEqual(full.band, .plenty)
        XCTAssertEqual(full.tokensText, "84k of 167k")
        XCTAssertEqual(full.spokenTokens, "84 thousand of 167 thousand tokens")
    }

    func testWithoutAutoCompactOrACompactionPointItIsMeasuredAgainstTheWindow() {
        var off = full
        off.autoCompact = false
        XCTAssertEqual(off.measure, .window(of: 200_000))
        XCTAssertEqual(off.percent, 42)

        let noPoint = SessionContext(model: "claude-opus-4-7", usedTokens: 150_000, contextWindow: 200_000)
        XCTAssertEqual(noPoint.measure, .window(of: 200_000))
        XCTAssertEqual(noPoint.band, .getting)
        XCTAssertEqual(noPoint.tokensText, "150k of 200k")
    }

    func testWhatIsntKnownIsntGuessed() {
        let started = SessionContext(model: "claude-opus-4-7", usedTokens: 12_400)
        XCTAssertNil(started.measure)
        XCTAssertNil(started.share)
        XCTAssertNil(started.percent)
        XCTAssertNil(started.band)
        XCTAssertEqual(started.tokensText, "12k")
        XCTAssertEqual(started.spokenTokens, "12 thousand tokens")

        let nothing = SessionContext()
        XCTAssertNil(nothing.tokensText)
        XCTAssertNil(nothing.modelName)
    }

    func testItIsHeldAtFullPastTheCompactionPoint() {
        let past = SessionContext(usedTokens: 170_000, compactsAt: 167_000)
        XCTAssertEqual(past.share, 1)
        XCTAssertEqual(past.percent, 100)
        XCTAssertEqual(past.band, .nearlyFull)
    }

    func testTokensAreShortened() {
        XCTAssertEqual(SessionContext.short(950), "950")
        XCTAssertEqual(SessionContext.short(1_499), "1k")
        XCTAssertEqual(SessionContext.short(167_000), "167k")
        XCTAssertEqual(SessionContext.short(999_700), "1M")
        XCTAssertEqual(SessionContext.short(1_200_000), "1.2M")
        XCTAssertEqual(SessionContext.spoken(1_200_000), "1.2 million")
    }

    func testModelsHaveFriendlyNames() {
        func name(_ model: String) -> String? { SessionContext(model: model).modelName }
        XCTAssertEqual(name("claude-opus-4-7"), "Opus 4.7")
        XCTAssertEqual(name("claude-opus-4-7[1m]"), "Opus 4.7, 1M")
        XCTAssertEqual(name("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(name("claude-haiku-5"), "Haiku 5")
        XCTAssertEqual(name("dummy"), "Dummy")
        XCTAssertEqual(name("opus"), "opus")
        XCTAssertEqual(name("claude-3-5-sonnet-20241022"), "claude-3-5-sonnet-20241022")
        XCTAssertEqual(name("gpt-oss"), "gpt-oss")
        XCTAssertNil(name(""))
    }

    func testAModelsSimpleNameIsShownAsTheVersionItStandsFor() {
        let options = [ModelOption(model: .opus, name: "Opus 5.5", resolved: "claude-opus-5-5"), ModelOption(model: .haiku)]
        XCTAssertEqual(SessionContext(model: "claude-opus-5-5").modelName(among: options), "Opus 5.5")
        XCTAssertEqual(SessionContext(model: "opus").modelName(among: options), "Opus 5.5")
        XCTAssertEqual(SessionContext(model: "haiku").modelName(among: options), "Haiku")
        XCTAssertEqual(SessionContext(model: "claude-fable-5-2").modelName(among: []), "Fable 5.2")
        XCTAssertEqual(SessionContext(model: "dummy").modelName(among: options), "Dummy")
        XCTAssertNil(SessionContext().modelName(among: options))
    }
}
