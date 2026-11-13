import Foundation

/// Where the address of the a-life-server is kept between launches.
public protocol ServerURLStoring: Sendable {
    func load() -> URL?
    /// Stores `url`, or forgets the stored one when `url` is `nil`.
    func save(_ url: URL?)
}

public struct UserDefaultsServerURLStore: ServerURLStoring {
    private let key: String

    public init(key: String = "ALife.serverURL") {
        self.key = key
    }

    public func load() -> URL? {
        UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:))
    }

    public func save(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString, forKey: key)
    }
}

/// Keeps the address in memory only. For tests and previews.
public final class InMemoryServerURLStore: ServerURLStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    public init(_ url: URL? = nil) { self.url = url }

    public func load() -> URL? { lock.withLock { url } }
    public func save(_ url: URL?) { lock.withLock { self.url = url } }
}
