import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What this device last registered for notifications, and where: kept so
/// the registration can be taken back once the server or the token changes.
public struct PushRegistrationRecord: Codable, Equatable, Sendable {
    /// The device's APNs token, in hex.
    public var token: String
    /// The server it registered with.
    public var serverURL: URL
    /// That server's own id, which its notifications carry.
    public var serverID: String

    public init(token: String, serverURL: URL, serverID: String) {
        self.token = token
        self.serverURL = serverURL
        self.serverID = serverID
    }
}

/// Where whether you want notifications, and what was last registered, are
/// kept between launches.
public protocol PushRegistrationStoring: Sendable {
    func load() -> PushRegistrationRecord?
    /// Stores `record`, or forgets the stored one when it is `nil`.
    func save(_ record: PushRegistrationRecord?)
    /// Whether you turned notifications on.
    func loadWanted() -> Bool
    func saveWanted(_ wanted: Bool)
}

public struct UserDefaultsPushRegistrationStore: PushRegistrationStoring {
    private let key: String

    public init(key: String = "ALife.pushRegistration") {
        self.key = key
    }

    public func load() -> PushRegistrationRecord? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PushRegistrationRecord.self, from: $0) }
    }

    public func save(_ record: PushRegistrationRecord?) {
        UserDefaults.standard.set(record.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    public func loadWanted() -> Bool {
        UserDefaults.standard.bool(forKey: key + ".wanted")
    }

    public func saveWanted(_ wanted: Bool) {
        UserDefaults.standard.set(wanted, forKey: key + ".wanted")
    }
}

/// Keeps it in memory only. For tests and previews.
public final class InMemoryPushRegistrationStore: PushRegistrationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: PushRegistrationRecord?
    private var wanted: Bool

    public init(_ record: PushRegistrationRecord? = nil, wanted: Bool = false) {
        self.record = record
        self.wanted = wanted
    }

    public func load() -> PushRegistrationRecord? { lock.withLock { record } }
    public func save(_ record: PushRegistrationRecord?) { lock.withLock { self.record = record } }
    public func loadWanted() -> Bool { lock.withLock { wanted } }
    public func saveWanted(_ wanted: Bool) { lock.withLock { self.wanted = wanted } }
}

/// Registers this device with the server the app is connected to, so it
/// hears when a character finishes its work, and only while you want it to.
///
/// The app hands it what only the platform knows: the device's token once
/// the system has given one, and that you said no to notifications. It
/// registers once it has a token, you want notifications and there's a
/// server; moves to a new server, taking the registration back from the old
/// one as best it can; swaps a token that changed; and takes the
/// registration back when you turn notifications off. Call `refresh()` on
/// every launch and whenever the server changes: registering again tells
/// the server the device is still about.
@MainActor
@Observable
public final class PushRegistration {
    public enum Status: Equatable, Sendable {
        /// You haven't turned notifications on.
        case off
        /// Turned on, waiting for the system to give the device a token.
        case waitingForToken
        /// You said no to notifications in the system's settings.
        case notAllowed
        /// There's no server to register with.
        case noServer
        case registering
        /// The server will tell this device when a character finishes.
        case registered
        /// Registered, but the server isn't set up to send notifications.
        case serverHasNoPush
        /// Registering failed, for this reason.
        case failed(String)
    }

    public private(set) var status: Status
    /// Whether you want notifications.
    public private(set) var isWanted: Bool
    /// The device's APNs token, in hex, once the system has given one.
    public private(set) var deviceToken: String?
    /// The id of the server this device is registered with, if it is.
    public private(set) var serverID: String?

    @ObservationIgnored private let server: ServerConnection
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let deviceName: String?
    @ObservationIgnored private let store: any PushRegistrationStoring
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var isNotAllowed = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshesAgain = false

    /// `environment` is which of Apple's servers the device's tokens belong
    /// to, and `bundleID` the app's, which the server must send for.
    public init(
        server: ServerConnection,
        environment: PushEnvironment,
        bundleID: String,
        deviceName: String? = nil,
        store: any PushRegistrationStoring = UserDefaultsPushRegistrationStore(),
        urlSession: URLSession = .shared
    ) {
        self.server = server
        self.environment = environment
        self.bundleID = bundleID
        self.deviceName = deviceName
        self.store = store
        self.urlSession = urlSession
        isWanted = store.loadWanted()
        status = store.loadWanted() ? .waitingForToken : .off
        // So a notification tapped before anything else happens can be
        // told to be from this server.
        if let record = store.load(), record.serverURL == server.serverURL {
            serverID = record.serverID
        }
    }

    /// Turns notifications on or off, and registers or takes the
    /// registration back.
    public func setWanted(_ wanted: Bool) async {
        isWanted = wanted
        store.saveWanted(wanted)
        if wanted { isNotAllowed = false } // asked again
        await refresh()
    }

    /// The token the system gave the device.
    public func setDeviceToken(_ token: Data) async {
        await setDeviceToken(hex: token.map { String(format: "%02x", $0) }.joined())
    }

    /// The token the system gave the device, in hex.
    public func setDeviceToken(hex: String) async {
        deviceToken = hex.lowercased()
        await refresh()
    }

    /// The system couldn't give the device a token, for `reason`, such as
    /// a build without the Push Notifications capability.
    public func couldNotGetToken(_ reason: String) {
        guard isWanted else { return }
        status = .failed(reason)
    }

    /// You said no to notifications in the system's settings.
    public func notAllowed() async {
        isNotAllowed = true
        await refresh()
    }

    /// Whether a notification came from the server this device is
    /// registered with.
    public func isFromThisServer(_ route: PushRoute) -> Bool {
        serverID != nil && route.serverID == serverID
    }

    /// Asks the server to send this device a test notification. Returns
    /// what went wrong, if anything.
    public func sendTest() async -> String? {
        guard let token = deviceToken, let url = server.serverURL else { return "There's no device token or server yet." }
        do {
            try await ALifeServerClient(baseURL: url, urlSession: urlSession).sendTestNotification(token: token)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Makes the server's registration match what is wanted now. One at a
    /// time: a call while one is under way has it go round again.
    public func refresh() async {
        guard !isRefreshing else {
            refreshesAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshesAgain = false
            await reconcile()
        } while refreshesAgain
        isRefreshing = false
    }

    private func reconcile() async {
        let isOn = isWanted && !isNotAllowed
        let token = isOn ? deviceToken : nil
        let url = isOn ? server.serverURL : nil

        // What was registered before and isn't wanted any more goes, as
        // best it can: the old server may be out of reach.
        if let record = store.load(), record.token != token || record.serverURL != url {
            try? await ALifeServerClient(baseURL: record.serverURL, urlSession: urlSession).unregisterDevice(token: record.token)
            store.save(nil)
            serverID = nil
        }

        guard isWanted else { status = .off; return }
        guard !isNotAllowed else { status = .notAllowed; return }
        guard let token else { status = .waitingForToken; return }
        guard let url else { status = .noServer; return }
        status = .registering
        do {
            let request = DeviceRegistrationRequest(environment: environment, bundleID: bundleID, name: deviceName)
            let answer = try await ALifeServerClient(baseURL: url, urlSession: urlSession).registerDevice(token: token, request)
            store.save(PushRegistrationRecord(token: token, serverURL: url, serverID: answer.serverID))
            serverID = answer.serverID
            status = answer.pushEnabled ? .registered : .serverHasNoPush
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

extension PushRoute {
    /// The route in a notification's payload, under `alife`, if it has one
    /// this version can read.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let alife = userInfo["alife"] as? [String: Any],
              JSONSerialization.isValidJSONObject(alife),
              let data = try? JSONSerialization.data(withJSONObject: alife),
              let route = try? JSONDecoder().decode(PushRoute.self, from: data)
        else { return nil }
        self = route
    }
}
