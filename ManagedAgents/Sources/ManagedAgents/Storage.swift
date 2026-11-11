import Foundation
#if canImport(Security)
import Security
#endif

/// Where the Anthropic API key is kept.
public protocol APIKeyStoring: Sendable {
    func load() -> String?
    /// Stores `key`, or removes the stored key when `key` is `nil`.
    func save(_ key: String?)
}

/// Keeps the key in memory only. For tests and previews.
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) { self.key = key }

    public func load() -> String? { lock.withLock { key } }
    public func save(_ key: String?) { lock.withLock { self.key = key } }
}

#if canImport(Security)
/// Keeps the key in the Keychain as a generic password.
public struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    public init(service: String, account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
#endif

/// The IDs of the server-side objects the app works with. This is all the
/// client has to remember between launches: the agent, the environment and the
/// session itself live on Anthropic's side.
public struct SessionReference: Codable, Equatable, Sendable {
    public var agentID: String?
    public var environmentID: String?
    public var sessionID: String?

    public init(agentID: String? = nil, environmentID: String? = nil, sessionID: String? = nil) {
        self.agentID = agentID
        self.environmentID = environmentID
        self.sessionID = sessionID
    }
}

public protocol SessionReferenceStoring: Sendable {
    func load() -> SessionReference
    func save(_ reference: SessionReference)
}

public final class InMemorySessionReferenceStore: SessionReferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reference: SessionReference

    public init(_ reference: SessionReference = SessionReference()) { self.reference = reference }

    public func load() -> SessionReference { lock.withLock { reference } }
    public func save(_ reference: SessionReference) { lock.withLock { self.reference = reference } }
}

/// Keeps the IDs in `UserDefaults`. They are not secrets.
public struct UserDefaultsSessionReferenceStore: SessionReferenceStoring {
    private let key: String

    public init(key: String = "ManagedAgents.sessionReference") {
        self.key = key
    }

    public func load() -> SessionReference {
        guard let data = UserDefaults.standard.data(forKey: key),
              let reference = try? JSONDecoder().decode(SessionReference.self, from: data) else {
            return SessionReference()
        }
        return reference
    }

    public func save(_ reference: SessionReference) {
        UserDefaults.standard.set(try? JSONEncoder().encode(reference), forKey: key)
    }
}
