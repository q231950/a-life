@_exported import ALifeAPI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ALifeClientError: Error, Equatable, LocalizedError {
    /// The server answered with a non-2xx status.
    case server(status: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .server(let status, let reason): return "\(reason) (HTTP \(status))"
        }
    }
}

/// The HTTP calls an a-life-server offers.
public struct ALifeServerClient: Sendable {
    private let baseURL: URL
    private let urlSession: URLSession

    public init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// Every session on the server, one per character, as it is right now.
    public func sessions() async throws -> [SessionState] {
        try JSONDecoder().decode([SessionState].self, from: await send("GET", "/v1/sessions"))
    }

    /// One session as the server knows it right now.
    public func state(of sessionID: String) async throws -> SessionState {
        try JSONDecoder().decode(SessionState.self, from: await send("GET", path(sessionID)))
    }

    /// Says something to a session's character. It works while the character
    /// is busy, too: the character takes it up at its next step. Refused
    /// while the character waits for an approval.
    public func sendMessage(_ text: String, to sessionID: String) async throws {
        try await send("POST", path(sessionID, "messages"), body: SendMessageRequest(text: text))
    }

    /// Stops whatever a session's character is doing.
    public func interrupt(_ sessionID: String) async throws {
        try await send("POST", path(sessionID, "interrupt"))
    }

    /// Answers a tool call that is waiting for approval.
    public func decide(approvalID: String, allow: Bool, in sessionID: String) async throws {
        try await send("POST", path(sessionID, "approvals", approvalID), body: ApprovalDecision(allow: allow))
    }

    /// Ends a session's conversation and starts an empty one.
    public func startOver(_ sessionID: String) async throws {
        try await send("POST", path(sessionID, "reset"))
    }

    /// Follows a session. Pass what you last saw and the server first sends
    /// everything after it, then live events as they happen; pass nothing and
    /// it starts from the beginning of the session's current conversation.
    /// Returns once the server has accepted the connection.
    public func events(of sessionID: String, conversationID: String? = nil, after seq: Int = 0) async throws -> AsyncThrowingStream<EventEnvelope, Error> {
        var query = [URLQueryItem(name: "after", value: String(seq))]
        if let conversationID { query.append(URLQueryItem(name: "conversation", value: conversationID)) }
        var request = makeRequest("GET", path(sessionID, "events"), query: query)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // An idle timeout. The server sends a heartbeat every few seconds; if
        // it goes quiet this long the stream errors and the caller reconnects.
        request.timeoutInterval = 60
        return try await EventStreamConnection().open(request, configuration: urlSession.configuration)
    }

    // MARK: Plumbing

    /// `/v1/sessions/{id}`, then `components`.
    private func path(_ sessionID: String, _ components: String...) -> String {
        "/v1/sessions/" + ([sessionID] + components).joined(separator: "/")
    }

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        return request
    }

    @discardableResult
    private func send(_ method: String, _ path: String) async throws -> Data {
        try await perform(makeRequest(method, path))
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: some Encodable) async throws -> Data {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.serverError(status: status, body: data) }
        return data
    }

    static func serverError(status: Int, body: Data) -> ALifeClientError {
        struct Failure: Decodable { let reason: String }
        let reason = (try? JSONDecoder().decode(Failure.self, from: body))?.reason
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .server(status: status, reason: reason)
    }
}

/// One server-sent-events connection, driven by `URLSession` delegate
/// callbacks (which, unlike `URLSession.bytes`, also exist on Linux).
private final class EventStreamConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // All state is touched only on the session's serial delegate queue.
    private var parser = ServerSentEventParser()
    private var opened: CheckedContinuation<Void, Error>?
    private var events: AsyncThrowingStream<EventEnvelope, Error>.Continuation?
    private var failureStatus: Int?
    private var failureBody = Data()

    func open(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> AsyncThrowingStream<EventEnvelope, Error> {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)

        let (stream, continuation) = AsyncThrowingStream<EventEnvelope, Error>.makeStream()
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
            guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(message.data.utf8)) else { continue }
            events?.yield(envelope)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure: Error? = failureStatus.map { ALifeServerClient.serverError(status: $0, body: failureBody) } ?? error
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
