import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ALifeClient

/// A notification's route, and `PushRegistration` against the stubbed
/// server, which answers each address as a server of its own, with its host
/// for its id.
@MainActor
final class PushRegistrationTests: XCTestCase {
    private let token = String(repeating: "a1b2c3d4", count: 8)
    private let otherToken = String(repeating: "0f1e2d3c", count: 8)

    private func makeRegistration(
        store: InMemoryPushRegistrationStore = InMemoryPushRegistrationStore()
    ) -> (PushRegistration, ServerConnection) {
        StubServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let urlSession = URLSession(configuration: configuration)
        let server = ServerConnection(
            serverURLStore: InMemoryServerURLStore(URL(string: "https://stub.invalid")),
            urlSession: urlSession,
            logSeenStore: InMemoryLogSeenStore()
        )
        let registration = PushRegistration(
            server: server, environment: .sandbox, bundleID: "dev.neoneon.alife", deviceName: "iPhone",
            store: store, urlSession: urlSession
        )
        return (registration, server)
    }

    /// What was asked of the devices' routes, as "PUT host /v1/devices/…".
    private var deviceRequests: [String] {
        StubServer.requests
            .filter { $0.url.path.hasPrefix("/v1/devices/") }
            .map { "\($0.method) \($0.url.host ?? "") \($0.url.path)" }
    }

    // MARK: The route

    func testARouteRoundTrips() throws {
        let route = PushRoute(serverID: "6B0E", session: "engineer", conversation: "1F3C", message: "9A21", seq: 482, kind: .finished)
        let json = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(PushRoute.self, from: json), route)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["server_id", "session", "conversation", "message", "seq", "kind"])

        // A job that said nothing has no message to point at.
        let quiet = PushRoute(serverID: "6B0E", session: "engineer", conversation: "1F3C", message: nil, seq: 7, kind: .error)
        XCTAssertEqual(try JSONDecoder().decode(PushRoute.self, from: JSONEncoder().encode(quiet)), quiet)
    }

    func testAKindThisVersionDoesntKnowIsUnknown() throws {
        let json = #"{"server_id":"6B0E","session":"engineer","seq":3,"kind":"waiting"}"#
        let route = try JSONDecoder().decode(PushRoute.self, from: Data(json.utf8))
        XCTAssertEqual(route.kind, .unknown)
        XCTAssertNil(route.message)
        XCTAssertNil(route.conversation)
    }

    func testTheRouteIsReadFromANotificationsUserInfo() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Engineer", "subtitle": "Finished", "body": "Worked on “Tidy up” for 2 min."]],
            "alife": [
                "server_id": "6B0E", "session": "engineer", "conversation": "1F3C",
                "message": "9A21", "seq": 482, "kind": "finished",
            ] as [String: Any],
        ]
        XCTAssertEqual(
            PushRoute(userInfo: userInfo),
            PushRoute(serverID: "6B0E", session: "engineer", conversation: "1F3C", message: "9A21", seq: 482, kind: .finished)
        )
        // The test notification, and anyone else's, have none.
        XCTAssertNil(PushRoute(userInfo: ["aps": ["alert": ["body": "a*life can reach you."]]]))
        XCTAssertNil(PushRoute(userInfo: ["alife": ["session": "engineer"]]))
    }

    // MARK: Registering

    func testRegistersOnceItHasATokenAndAServer() async throws {
        let store = InMemoryPushRegistrationStore()
        let (registration, server) = makeRegistration(store: store)
        XCTAssertEqual(registration.status, .off)

        await registration.setWanted(true)
        XCTAssertEqual(registration.status, .waitingForToken)
        XCTAssertTrue(deviceRequests.isEmpty)

        await registration.setDeviceToken(hex: token.uppercased())
        XCTAssertEqual(registration.status, .registered)
        XCTAssertEqual(deviceRequests, ["PUT stub.invalid /v1/devices/\(token)"])
        let put = try XCTUnwrap(StubServer.requests.first { $0.method == "PUT" })
        XCTAssertEqual(
            try JSONDecoder().decode(DeviceRegistrationRequest.self, from: XCTUnwrap(put.body)),
            DeviceRegistrationRequest(environment: .sandbox, bundleID: "dev.neoneon.alife", name: "iPhone")
        )
        XCTAssertEqual(registration.serverID, "stub.invalid")
        XCTAssertEqual(store.load(), PushRegistrationRecord(token: token, serverURL: URL(string: "https://stub.invalid")!, serverID: "stub.invalid"))
        XCTAssertTrue(store.loadWanted())

        // Only this server's notifications are its own.
        XCTAssertTrue(registration.isFromThisServer(PushRoute(serverID: "stub.invalid", session: "engineer", conversation: nil, message: nil, seq: 1, kind: .finished)))
        XCTAssertFalse(registration.isFromThisServer(PushRoute(serverID: "elsewhere", session: "engineer", conversation: nil, message: nil, seq: 1, kind: .finished)))

        // Again on the next launch, which says the device is still about.
        await registration.refresh()
        XCTAssertEqual(deviceRequests, ["PUT stub.invalid /v1/devices/\(token)", "PUT stub.invalid /v1/devices/\(token)"])
        server.disconnect()
    }

    func testTheTokenIsSentInHex() async {
        let (registration, server) = makeRegistration()
        await registration.setWanted(true)
        await registration.setDeviceToken(Data([0xAB, 0x01, 0x00, 0xFF, 0x10, 0x20, 0x30, 0x40]))
        XCTAssertEqual(registration.deviceToken, "ab0100ff10203040")
        XCTAssertEqual(deviceRequests, ["PUT stub.invalid /v1/devices/ab0100ff10203040"])
        server.disconnect()
    }

    func testMovesToANewServer() async {
        let store = InMemoryPushRegistrationStore()
        let (registration, server) = makeRegistration(store: store)
        await registration.setWanted(true)
        await registration.setDeviceToken(hex: token)

        XCTAssertTrue(server.setServerURL("https://other.invalid"))
        await registration.refresh()
        XCTAssertEqual(deviceRequests, [
            "PUT stub.invalid /v1/devices/\(token)",
            "DELETE stub.invalid /v1/devices/\(token)",
            "PUT other.invalid /v1/devices/\(token)",
        ])
        XCTAssertEqual(registration.serverID, "other.invalid")
        XCTAssertEqual(store.load()?.serverURL, URL(string: "https://other.invalid"))

        // No server at all: nothing is registered anywhere.
        server.setServerURL("")
        await registration.refresh()
        XCTAssertEqual(deviceRequests.last, "DELETE other.invalid /v1/devices/\(token)")
        XCTAssertEqual(registration.status, .noServer)
        XCTAssertNil(registration.serverID)
        XCTAssertNil(store.load())
        server.disconnect()
    }

    func testSwapsATokenThatChanged() async {
        let (registration, server) = makeRegistration()
        await registration.setWanted(true)
        await registration.setDeviceToken(hex: token)
        await registration.setDeviceToken(hex: otherToken)
        XCTAssertEqual(deviceRequests, [
            "PUT stub.invalid /v1/devices/\(token)",
            "DELETE stub.invalid /v1/devices/\(token)",
            "PUT stub.invalid /v1/devices/\(otherToken)",
        ])
        XCTAssertEqual(registration.status, .registered)
        server.disconnect()
    }

    func testTurningItOffTakesTheRegistrationBack() async {
        let store = InMemoryPushRegistrationStore()
        let (registration, server) = makeRegistration(store: store)
        await registration.setWanted(true)
        await registration.setDeviceToken(hex: token)

        await registration.setWanted(false)
        XCTAssertEqual(deviceRequests.last, "DELETE stub.invalid /v1/devices/\(token)")
        XCTAssertEqual(registration.status, .off)
        XCTAssertNil(registration.serverID)
        XCTAssertNil(store.load())
        XCTAssertFalse(store.loadWanted())

        // Nothing more once it's off.
        let asked = deviceRequests.count
        await registration.refresh()
        XCTAssertEqual(deviceRequests.count, asked)
        server.disconnect()
    }

    func testSaysWhenTheServerIsntSetUpToSend() async {
        let (registration, server) = makeRegistration()
        StubServer.pushEnabled = false
        await registration.setWanted(true)
        await registration.setDeviceToken(hex: token)
        XCTAssertEqual(registration.status, .serverHasNoPush)
        // Registered all the same, to hear once it is.
        XCTAssertEqual(registration.serverID, "stub.invalid")
        server.disconnect()
    }

    func testSaysWhenYouSaidNo() async {
        let (registration, server) = makeRegistration()
        await registration.setWanted(true)
        await registration.notAllowed()
        XCTAssertEqual(registration.status, .notAllowed)
        XCTAssertTrue(deviceRequests.isEmpty)
        server.disconnect()
    }

    func testRemembersTheServerItRegisteredWith() {
        let record = PushRegistrationRecord(token: token, serverURL: URL(string: "https://stub.invalid")!, serverID: "6B0E")
        let (registration, server) = makeRegistration(store: InMemoryPushRegistrationStore(record, wanted: true))
        // Before anything is asked, a tapped notification can be told apart.
        XCTAssertEqual(registration.serverID, "6B0E")
        XCTAssertTrue(registration.isWanted)
        XCTAssertEqual(registration.status, .waitingForToken)
        server.disconnect()
    }
}
