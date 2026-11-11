import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin HTTP client for the parts of the Managed Agents API that one
/// multiagent session needs. There is no official Swift SDK, so this talks to
/// the REST endpoints directly.
public struct ManagedAgentsClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    private let apiKey: String
    private let baseURL: URL
    private let urlSession: URLSession

    public init(apiKey: String, baseURL: URL = ManagedAgentsClient.defaultBaseURL, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    // MARK: Setup (once)

    /// Creates the sandbox environment and returns its ID.
    public func createEnvironment(_ blueprint: TeamBlueprint) async throws -> String {
        try await id(of: send("POST", "/v1/environments", body: blueprint.environmentBody))
    }

    /// Creates the coordinator agent and returns its ID. Agents are stored,
    /// versioned objects: call this once and keep the ID.
    public func createAgent(_ blueprint: TeamBlueprint) async throws -> String {
        try await id(of: send("POST", "/v1/agents", body: blueprint.agentBody))
    }

    // MARK: Sessions

    public func createSession(
        agentID: String,
        environmentID: String,
        title: String? = nil,
        budgetCents: Int? = nil
    ) async throws -> Session {
        var body: [String: JSONValue] = ["agent": .string(agentID), "environment_id": .string(environmentID)]
        if let title { body["title"] = .string(title) }
        if let budgetCents {
            body["budget"] = ["type": "limit", "max_list_cost": ["amount": .string(String(budgetCents)), "currency": "USD"]]
        }
        return try session(from: await send("POST", "/v1/sessions", body: .object(body)))
    }

    public func retrieveSession(_ sessionID: String) async throws -> Session {
        try session(from: await send("GET", "/v1/sessions/\(sessionID)"))
    }

    /// Every thread in the session, the coordinator's first.
    public func listThreads(sessionID: String) async throws -> [SessionThread] {
        try await listAll("/v1/sessions/\(sessionID)/threads").compactMap(SessionThread.init(json:))
    }

    // MARK: Events

    /// The session's whole event history, oldest first.
    public func listEvents(sessionID: String) async throws -> [SessionEvent] {
        try await listAll("/v1/sessions/\(sessionID)/events").map { SessionEvent(payload: $0) }
    }

    public func sendEvents(_ events: [OutgoingEvent], sessionID: String) async throws {
        _ = try await send("POST", "/v1/sessions/\(sessionID)/events", body: ["events": .array(events.map(\.json))])
    }

    /// Opens the session's live event stream. Returns once the server has
    /// accepted the connection, so anything that happens after this call
    /// returns is delivered. The stream has no replay: pair every (re)connect
    /// with `listEvents` and drop the events you have already seen.
    public func streamEvents(sessionID: String) async throws -> AsyncThrowingStream<SessionEvent, Error> {
        var request = makeRequest("GET", "/v1/sessions/\(sessionID)/events/stream")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The timeout is an idle one. The server sends heartbeats; if it goes
        // quiet for this long the stream errors and the caller reconnects.
        request.timeoutInterval = 300
        return try await EventStreamConnection().open(request, configuration: urlSession.configuration)
    }

    // MARK: Plumbing

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("managed-agents-2026-04-01", forHTTPHeaderField: "anthropic-beta")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        return request
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let (data, response) = try await urlSession.data(for: makeRequest(method, path, query: query, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.apiError(status: status, body: data) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ManagedAgentsError.unexpectedResponse("\(method) \(path) did not return JSON")
        }
        return json
    }

    /// Follows `next_page` until the list is exhausted.
    private func listAll(_ path: String) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var page: String?
        repeat {
            let query = page.map { [URLQueryItem(name: "page", value: $0)] } ?? []
            let json = try await send("GET", path, query: query)
            items += json["data"]?.arrayValue ?? []
            page = json["next_page"]?.stringValue
        } while page != nil
        return items
    }

    private func id(of json: JSONValue) throws -> String {
        guard let id = json["id"]?.stringValue else { throw ManagedAgentsError.unexpectedResponse("no id in response") }
        return id
    }

    private func session(from json: JSONValue) throws -> Session {
        guard let session = Session(json: json) else { throw ManagedAgentsError.unexpectedResponse("not a session") }
        return session
    }

    static func apiError(status: Int, body: Data) -> ManagedAgentsError {
        let error = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]
        let message = error?["message"]?.stringValue
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .api(status: status, type: error?["type"]?.stringValue, message: message)
    }
}

/// One server-sent-events connection, driven by `URLSession` delegate
/// callbacks (which, unlike `URLSession.bytes`, also exist on Linux).
private final class EventStreamConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // All state is touched only on the session's serial delegate queue.
    private var parser = ServerSentEventParser()
    private var opened: CheckedContinuation<Void, Error>?
    private var events: AsyncThrowingStream<SessionEvent, Error>.Continuation?
    private var failureStatus: Int?
    private var failureBody = Data()

    func open(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> AsyncThrowingStream<SessionEvent, Error> {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)

        let (stream, continuation) = AsyncThrowingStream<SessionEvent, Error>.makeStream()
        continuation.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (opened: CheckedContinuation<Void, Error>) in
                    queue.addOperation {
                        self.opened = opened
                        self.events = continuation
                        task.resume()
                    }
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            continuation.finish()
            throw error
        }
        return stream
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            opened?.resume()
            opened = nil
        } else {
            failureStatus = status // keep reading: the body says what went wrong
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failureStatus == nil else {
            failureBody.append(data)
            return
        }
        for message in parser.feed(data) {
            guard let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(message.data.utf8)) else { continue }
            events?.yield(SessionEvent(payload: payload, fallbackType: message.event))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure: Error? = failureStatus.map { ManagedAgentsClient.apiError(status: $0, body: failureBody) } ?? error
        if let opened {
            // Never got a 2xx, so the caller is still waiting in `open`.
            opened.resume(throwing: failure ?? URLError(.badServerResponse))
            self.opened = nil
        } else {
            events?.finish(throwing: failure)
        }
        events = nil
        session.finishTasksAndInvalidate() // the session holds its delegate until then
    }
}
