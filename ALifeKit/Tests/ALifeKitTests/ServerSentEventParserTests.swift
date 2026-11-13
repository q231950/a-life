import XCTest
@testable import ALifeClient

final class ServerSentEventParserTests: XCTestCase {
    func testParsesEventsSplitAcrossChunks() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data("event: agent.mess".utf8)), [])
        XCTAssertEqual(parser.feed(Data("age\ndata: {\"a\":".utf8)), [])
        let events = parser.feed(Data("1}\n\nevent: x\r\ndata: one\r\ndata: two\r\n\r\n".utf8))
        XCTAssertEqual(events, [
            ServerSentEvent(event: "agent.message", data: "{\"a\":1}"),
            ServerSentEvent(event: "x", data: "one\ntwo"),
        ])
    }

    func testIgnoresHeartbeatCommentsAndEmptyEvents() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data(": ping\n\n\ndata:no-space\n\n".utf8)), [
            ServerSentEvent(event: nil, data: "no-space"),
        ])
    }

    func testKeepsMultiByteCharactersSplitAcrossChunks() {
        var parser = ServerSentEventParser()
        let bytes = Array("data: héllo\n\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), [ServerSentEvent(event: nil, data: "héllo")])
    }
}
