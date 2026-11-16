import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The voice model the server offers the front ends, over HTTP on a local
/// port, fetched from the address the client package says it is at.
@MainActor
final class VoiceModelTests: XCTestCase {
    private var app: Application!
    private var baseURL: URL!
    private var voice: URL!

    override func setUp() async throws {
        voice = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: voice.appendingPathComponent("voices"), withIntermediateDirectories: true)
        try Data(#"{"built":1,"files":[]}"#.utf8).write(to: voice.appendingPathComponent("bundle.json"))
        try Data("bramwell".utf8).write(to: voice.appendingPathComponent("voices/Sir Bramwell.safetensors"))
        try Data("secret".utf8).write(to: voice.appendingPathComponent(".hidden"))
        try Data("outside".utf8).write(to: voice.deletingLastPathComponent().appendingPathComponent("outside-\(voice.lastPathComponent)"))
        try await start(voiceDirectory: voice)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: voice)
        try? FileManager.default.removeItem(at: voice.deletingLastPathComponent().appendingPathComponent("outside-\(voice.lastPathComponent)"))
    }

    private func start(voiceDirectory: URL?) async throws {
        app = try await Application.make(.testing)
        try await configure(app, players: .dummies(step: .milliseconds(20)), voiceDirectory: voiceDirectory)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0 // any free port
        try await app.startup()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }

    private var voiceModelURL: URL {
        ALifeServerClient(baseURL: baseURL).voiceModelURL
    }

    /// The status and body of a GET to `url`.
    private func get(_ url: URL) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testServesTheModelsFilesAsTheyAre() async throws {
        let manifest = try await get(voiceModelURL.appendingPathComponent("bundle.json"))
        XCTAssertEqual(manifest.status, 200)
        XCTAssertEqual(manifest.body, #"{"built":1,"files":[]}"#)

        // Voices have spaces in their names.
        let bramwell = try await get(voiceModelURL.appendingPathComponent("voices/Sir Bramwell.safetensors"))
        XCTAssertEqual(bramwell.status, 200)
        XCTAssertEqual(bramwell.body, "bramwell")
    }

    func testServesNothingElse() async throws {
        let outside = "outside-\(voice.lastPathComponent)"
        for path in ["missing.json", "voices", ".hidden", "../\(outside)", "%2E%2E/\(outside)", "voices/..%2F..%2F\(outside)"] {
            let url = try XCTUnwrap(URL(string: voiceModelURL.absoluteString + path))
            let answer = try await get(url)
            XCTAssertEqual(answer.status, 404, path)
            XCTAssertFalse(answer.body.contains("outside") || answer.body.contains("secret"), path)
        }
        XCTAssertNil(voiceFile(at: "/v1/voice/../\(outside)", in: voice))
        XCTAssertNil(voiceFile(at: "/v1/voice/voices/%2E%2E/%2E%2E/\(outside)", in: voice))
        XCTAssertEqual(voiceFile(at: "/v1/voice/voices/Sir%20Bramwell.safetensors", in: voice)?.lastPathComponent, "Sir Bramwell.safetensors")
    }

    func testWithoutAModelThereIsNothingToFetch() async throws {
        try await app.asyncShutdown()
        try await start(voiceDirectory: nil)
        let answer = try await get(voiceModelURL.appendingPathComponent("bundle.json"))
        XCTAssertEqual(answer.status, 404)
        XCTAssertTrue(answer.body.contains("no voice model"), answer.body)
    }
}
