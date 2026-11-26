import ALifeAPI
import Foundation
import Vapor

/// A phone or tablet that asked to hear when a character finishes its work.
struct RegisteredDevice: Codable, Equatable, Sendable {
    /// Its APNs device token, in lowercase hex.
    var token: String
    /// Which of Apple's servers its token belongs to.
    var environment: PushEnvironment
    /// The app's bundle id, which notifications are sent for.
    var bundleID: String
    /// The device's name, for the log only.
    var name: String?
    var registeredAt: Date
    /// When it last registered, which the app does on every launch.
    var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case token, environment, name
        case bundleID = "bundle_id"
        case registeredAt = "registered_at"
        case lastSeen = "last_seen"
    }
}

/// The devices registered with this server for push notifications, and the
/// server's own id, kept in a small JSON file so a restart of the server
/// doesn't forget them.
///
/// The file, `devices.json` in the server's state directory:
///
/// ```json
/// {
///   "devices" : [
///     {
///       "bundle_id" : "dev.neoneon.alife",
///       "environment" : "sandbox",
///       "last_seen" : 1763820000,
///       "name" : "iPhone",
///       "registered_at" : 1763820000,
///       "token" : "a1b2…"
///     }
///   ],
///   "server_id" : "6B0E…"
/// }
/// ```
///
/// Times are in seconds since 1970. A device not seen for 90 days is
/// forgotten when the file is read, so a phone you no longer have doesn't
/// stay for ever. Without a file, they're kept in memory only, and the
/// server's id is new each time it starts.
actor DeviceRegistry {
    /// How long a device that hasn't registered again is kept.
    static let forgottenAfter: TimeInterval = 90 * 24 * 60 * 60

    /// What the file holds.
    private struct Saved: Codable {
        var serverID: String
        var devices: [RegisteredDevice]

        enum CodingKeys: String, CodingKey {
            case devices
            case serverID = "server_id"
        }
    }

    /// The file they're kept in, or `nil` to keep them in memory only.
    let file: URL?
    /// The server's own id, which goes in every notification, so the app
    /// can tell this server's from another's.
    let serverID: String
    private var devices: [String: RegisteredDevice] = [:]
    private let logger: Logger

    /// Reads what `file` holds, if it is there, and forgets the devices not
    /// seen since 90 days before `now`.
    init(file: URL?, logger: Logger = Logger(label: "a-life.devices"), now: Date = Date()) {
        self.file = file
        self.logger = logger
        var saved: Saved?
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                saved = try decoder.decode(Saved.self, from: Data(contentsOf: file))
            } catch {
                logger.error("Couldn't read the devices registered for notifications from \(file.path), so they have to register again: \(error)")
            }
        }
        serverID = saved?.serverID ?? UUID().uuidString
        let kept = (saved?.devices ?? []).filter { now.timeIntervalSince($0.lastSeen) < Self.forgottenAfter }
        devices = Dictionary(kept.map { ($0.token, $0) }, uniquingKeysWith: { _, last in last })
        if let saved, kept.count < saved.devices.count {
            logger.notice("Forgot \(saved.devices.count - kept.count) device(s) not seen for 90 days")
            Self.write(Saved(serverID: serverID, devices: kept), to: file, logger: logger)
        }
    }

    /// Every device registered, the earliest first.
    var all: [RegisteredDevice] {
        devices.values.sorted { ($0.registeredAt, $0.token) < ($1.registeredAt, $1.token) }
    }

    /// The device with this token, if it is registered.
    func device(_ token: String) -> RegisteredDevice? {
        devices[token.lowercased()]
    }

    /// Registers a device, or updates the one with the same token, and says
    /// it was seen at `now`.
    @discardableResult
    func register(token: String, _ request: DeviceRegistrationRequest, now: Date = Date()) -> RegisteredDevice {
        let token = token.lowercased()
        let device = RegisteredDevice(
            token: token,
            environment: request.environment,
            bundleID: request.bundleID,
            name: request.name,
            registeredAt: devices[token]?.registeredAt ?? now,
            lastSeen: now
        )
        if devices[token] == nil {
            logger.notice("Registered \(device.name ?? "a device") for notifications (\(device.environment.rawValue))")
        }
        devices[token] = device
        save()
        return device
    }

    /// Forgets a device, as the app asks when you turn notifications off.
    func unregister(token: String) {
        guard let device = devices.removeValue(forKey: token.lowercased()) else { return }
        logger.notice("\(device.name ?? "A device") no longer wants notifications")
        save()
    }

    /// Forgets a device whose token APNs says is no longer any good.
    func drop(token: String) {
        guard let device = devices.removeValue(forKey: token.lowercased()) else { return }
        logger.notice("Dropped \(device.name ?? "a device") from notifications: Apple says its token is no longer valid")
        save()
    }

    /// Whether `token` looks like an APNs device token: hex, a whole number
    /// of bytes, and of a sensible length.
    static func isToken(_ token: String) -> Bool {
        (16...400).contains(token.count) && token.count.isMultiple(of: 2) && token.allSatisfy(\.isHexDigit)
    }

    private func save() {
        Self.write(Saved(serverID: serverID, devices: all), to: file, logger: logger)
    }

    private static func write(_ saved: Saved, to file: URL?, logger: Logger) {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't write the devices registered for notifications to \(file.path): \(error)")
        }
    }
}
