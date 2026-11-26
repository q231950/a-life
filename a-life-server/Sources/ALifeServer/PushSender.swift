import ALifeAPI
import APNS
import APNSCore
import Foundation
import Vapor

/// What became of a notification sent to one device.
enum PushResult: Equatable, Sendable {
    case delivered
    /// Apple says the device's token is no longer any good, such as after
    /// the app was deleted. The device is forgotten.
    case goneForGood
    /// It didn't go, this time, for `reason`. It isn't sent again: a
    /// finished job isn't worth piling up retries for.
    case failed(String)
}

/// Sends a notification to one device. `APNSPushSender` sends it through
/// Apple's push notification service; the tests use one that only records.
protocol PushSender: Sendable {
    func send(_ notice: PushNotice, to device: RegisteredDevice) async -> PushResult
    /// The server is stopping.
    func shutdown() async
}

extension PushSender {
    func shutdown() async {}
}

/// One notification, as it goes to a device: its title, subtitle and body,
/// and the route the app follows when it is tapped.
///
/// ```json
/// {
///   "aps": {
///     "alert": {"title": "Engineer", "subtitle": "Finished", "body": "Worked on …"},
///     "sound": "default",
///     "thread-id": "engineer",
///     "interruption-level": "active"
///   },
///   "alife": {"server_id": "6B0E…", "session": "engineer", "conversation": "1F3C…", "message": "9A21…", "seq": 482, "kind": "finished"}
/// }
/// ```
///
/// The body is the job's summary, never the character's reply: only the
/// reply's id is in it, under `alife.message`. There's no badge, since the
/// server can't know what you've seen.
struct PushNotice: Encodable, Equatable, Sendable {
    /// The most APNs takes.
    static let maxPayloadSize = 4096

    var title: String
    var subtitle: String?
    var body: String
    /// Groups a character's notifications together: its session id.
    var threadID: String?
    /// What it points at, if anything.
    var route: PushRoute?

    /// The notification for a job that ended: titled with the character's
    /// `name`, with the job's `summary`, or `fallback` if the payload would
    /// ever be too big.
    static func job(name: String, summary: String, fallback: String, route: PushRoute) -> PushNotice {
        var notice = PushNotice(
            title: name, subtitle: JobSummary.subtitle(for: route.kind), body: summary,
            threadID: route.session, route: route
        )
        if (try? notice.payload().count).map({ $0 > maxPayloadSize }) ?? true {
            notice.body = fallback
        }
        return notice
    }

    /// The notification the settings' Send a test button sends.
    static let test = PushNotice(title: "a*life", subtitle: nil, body: "a*life can reach you.", threadID: nil, route: nil)

    /// The payload, as it goes to APNs.
    func payload() throws -> Data {
        try JSONEncoder().encode(self)
    }

    private struct Alert: Encodable {
        let title: String
        let subtitle: String?
        let body: String
    }

    private struct APS: Encodable {
        let alert: Alert
        let sound = "default"
        let threadID: String?
        let interruptionLevel = "active"

        enum CodingKeys: String, CodingKey {
            case alert, sound
            case threadID = "thread-id"
            case interruptionLevel = "interruption-level"
        }
    }

    enum CodingKeys: String, CodingKey {
        case aps, alife
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(APS(alert: Alert(title: title, subtitle: subtitle, body: body), threadID: threadID), forKey: .aps)
        try container.encodeIfPresent(route, forKey: .alife)
    }
}

extension PushNotice: APNSMessage {}

/// The settings for sending notifications through Apple, from the
/// environment. All four are needed for pushes to be on:
///
/// - `ALIFE_APNS_KEY_FILE`: the `.p8` key file from your Apple developer
///   account.
/// - `ALIFE_APNS_KEY_ID`: its key id.
/// - `ALIFE_APNS_TEAM_ID`: your team id.
/// - `ALIFE_APNS_TOPIC`: the app's bundle id.
///
/// With none of them set, pushes are off. With some but not all, or a key
/// that can't be read, they're off too, and `problem` says why: a phone that
/// doesn't buzz shouldn't keep the characters from working.
struct PushSettings: Equatable, Sendable {
    /// What APNs needs of you.
    struct Credentials: Equatable, Sendable {
        /// The key, in PEM, as the `.p8` file has it.
        var key: String
        var keyID: String
        var teamID: String
        /// The app's bundle id, which notifications are sent for.
        var topic: String
    }

    static let keyFileSetting = "ALIFE_APNS_KEY_FILE"
    static let keyIDSetting = "ALIFE_APNS_KEY_ID"
    static let teamIDSetting = "ALIFE_APNS_TEAM_ID"
    static let topicSetting = "ALIFE_APNS_TOPIC"

    /// `nil` while pushes are off.
    var credentials: Credentials?
    /// The bundle id devices must register with, if it is set, even while
    /// pushes are off.
    var topic: String?
    /// Why pushes are off, if some of the settings were given.
    var problem: String?

    /// Pushes off, with nothing set.
    static let off = PushSettings()

    static func read(from environment: [String: String] = ProcessInfo.processInfo.environment) -> PushSettings {
        func value(_ name: String) -> String? {
            environment[name].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let names = [keyFileSetting, keyIDSetting, teamIDSetting, topicSetting]
        let missing = names.filter { value($0) == nil }
        var settings = PushSettings(topic: value(topicSetting))
        guard missing.count < names.count else { return settings }
        guard missing.isEmpty else {
            settings.problem = "Push notifications are off: \(list(missing)) \(missing.count == 1 ? "isn't" : "aren't") set. See Push notifications in the README."
            return settings
        }
        let path = ((value(keyFileSetting) ?? "") as NSString).expandingTildeInPath
        let key: String
        do {
            key = try String(contentsOfFile: path, encoding: .utf8)
            _ = try P256.Signing.PrivateKey(pemRepresentation: key)
        } catch {
            settings.problem = "Push notifications are off: couldn't read the key in \(path) (\(error)). It's the .p8 file from your Apple developer account."
            return settings
        }
        settings.credentials = Credentials(key: key, keyID: value(keyIDSetting) ?? "", teamID: value(teamIDSetting) ?? "", topic: value(topicSetting) ?? "")
        return settings
    }

    /// "A", "A and B", "A, B and C".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

/// Sends notifications through Apple's push notification service, with
/// token authentication from your `.p8` key, to whichever of Apple's
/// servers each device's token belongs to. A client for each is made the
/// first time it is needed.
///
/// What Apple says back: a token that is gone for good is `goneForGood`, so
/// the device is forgotten. A setup that's wrong (a bad key, team or key id,
/// or a topic the key may not send to) is logged once as an error, and the
/// devices kept. Anything else, such as Apple being busy, is logged, and
/// the notification isn't sent again.
actor APNSPushSender: PushSender {
    private let credentials: PushSettings.Credentials
    private let eventLoopGroup: any EventLoopGroup
    private let logger: Logger
    private var clients: [PushEnvironment: APNSClient<JSONDecoder, JSONEncoder>] = [:]
    private var setupProblemSaid = false

    init(credentials: PushSettings.Credentials, eventLoopGroup: any EventLoopGroup, logger: Logger) {
        self.credentials = credentials
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    func send(_ notice: PushNotice, to device: RegisteredDevice) async -> PushResult {
        let client: APNSClient<JSONDecoder, JSONEncoder>
        do {
            client = try self.client(for: device.environment)
        } catch {
            return setupIsWrong("couldn't use the key: \(error)")
        }
        let request = APNSRequest(
            message: notice,
            deviceToken: device.token,
            pushType: .alert,
            // A phone that's off for longer doesn't need yesterday's news.
            expiration: .timeIntervalSince1970InSeconds(Int(Date().timeIntervalSince1970) + 24 * 60 * 60),
            priority: .immediately,
            apnsID: nil,
            topic: credentials.topic,
            collapseID: nil
        )
        do {
            _ = try await client.send(request)
            return .delivered
        } catch let error as APNSError {
            let reason = error.reason?.reason ?? "no reason given"
            switch (error.responseStatus, reason) {
            case (410, _), (400, "BadDeviceToken"), (400, "DeviceTokenNotForTopic"):
                return .goneForGood
            case (403, _), (400, "TopicDisallowed"), (400, "BadTopic"):
                return setupIsWrong("Apple said \(error.responseStatus) \(reason)")
            default:
                logger.warning("Couldn't send a notification to \(device.name ?? "a device"): Apple said \(error.responseStatus) \(reason)")
                return .failed("\(error.responseStatus) \(reason)")
            }
        } catch {
            logger.warning("Couldn't send a notification to \(device.name ?? "a device"): \(error)")
            return .failed("\(error)")
        }
    }

    func shutdown() async {
        for client in clients.values {
            try? await client.shutdown()
        }
        clients = [:]
    }

    /// The client for one of Apple's servers, made the first time.
    private func client(for environment: PushEnvironment) throws -> APNSClient<JSONDecoder, JSONEncoder> {
        if let client = clients[environment] { return client }
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.key)
        let client = APNSClient(
            configuration: APNSClientConfiguration(
                authenticationMethod: .jwt(privateKey: key, keyIdentifier: credentials.keyID, teamIdentifier: credentials.teamID),
                environment: environment == .production ? .production : .development
            ),
            eventLoopGroupProvider: .shared(eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder()
        )
        clients[environment] = client
        return client
    }

    /// Says once that the setup is wrong, rather than for every notification.
    private func setupIsWrong(_ reason: String) -> PushResult {
        if !setupProblemSaid {
            setupProblemSaid = true
            logger.error("Notifications can't be sent: \(reason). Check ALIFE_APNS_KEY_FILE, ALIFE_APNS_KEY_ID, ALIFE_APNS_TEAM_ID and ALIFE_APNS_TOPIC, and that the key is for Apple Push Notifications. See Push notifications in the README.")
        }
        return .failed(reason)
    }
}
