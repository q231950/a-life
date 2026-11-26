import Foundation

/// Which of Apple's push notification servers a device's token belongs to.
/// A development build of the app gets sandbox tokens; TestFlight and the
/// App Store ones get production tokens.
public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
    /// A value this version doesn't know. The server refuses it.
    case unknown

    public init(from decoder: Decoder) throws {
        self = PushEnvironment(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// `PUT /v1/devices/{token}`: a device that would like to hear when a
/// character finishes its work. The token, in hex, is in the path.
public struct DeviceRegistrationRequest: Codable, Equatable, Sendable {
    public var environment: PushEnvironment
    /// The app's bundle id, which must be the one the server sends for.
    public var bundleID: String
    /// The device's name, for the server's log only.
    public var name: String?

    public init(environment: PushEnvironment, bundleID: String, name: String? = nil) {
        self.environment = environment
        self.bundleID = bundleID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case environment, name
        case bundleID = "bundle_id"
    }
}

/// The server's answer to registering a device.
public struct DeviceRegistration: Codable, Equatable, Sendable {
    /// The server's own id, made once and kept, so a notification from
    /// this server can be told from one sent by another.
    public var serverID: String
    /// Whether the server is set up to send notifications. A device is
    /// registered all the same, so it hears once the server is.
    public var pushEnabled: Bool

    public init(serverID: String, pushEnabled: Bool) {
        self.serverID = serverID
        self.pushEnabled = pushEnabled
    }

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case pushEnabled = "push_enabled"
    }
}

/// What a notification points at, under its payload's `alife` key: the
/// character, its conversation, and the reply to open it at. Only the
/// reply's id travels, never its text; the app loads the reply from the
/// server.
public struct PushRoute: Codable, Equatable, Sendable {
    /// Why the notification was sent.
    public enum Kind: String, Codable, Sendable {
        /// The character finished its work.
        case finished
        /// The character stopped on an error, and needs you.
        case error
        /// A kind this version doesn't know.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// The id of the server that sent it.
    public var serverID: String
    /// The character's session id, such as `engineer`.
    public var session: String
    /// The conversation the job was in.
    public var conversation: String?
    /// The id of the reply, or of the error, that ended the job, if there
    /// was one.
    public var message: String?
    /// The sequence number of the `session.status` event that ended the job.
    public var seq: Int
    public var kind: Kind

    public init(serverID: String, session: String, conversation: String?, message: String?, seq: Int, kind: Kind) {
        self.serverID = serverID
        self.session = session
        self.conversation = conversation
        self.message = message
        self.seq = seq
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case session, conversation, message, seq, kind
        case serverID = "server_id"
    }
}
