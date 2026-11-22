import ALifeAPI
import Foundation
import Vapor

/// How much of Claude's 5-hour usage window is used, as the server last
/// heard, and the clients following it.
///
/// Claude Code reads the `anthropic-ratelimit-unified-*` headers of every
/// response and passes them on in stream-json, as a `rate_limit_event`, on
/// every turn. Each character hands what it reads here (`record`), and the
/// latest to arrive wins, whoever it came from: they all share one account,
/// and one window. Each change goes out to every open stream, with the next
/// revision.
///
/// The server only hears while one of its characters is running, so usage
/// from Claude sessions elsewhere isn't seen until the next run here.
///
/// The last reading is kept in `usage.json` in the server's state
/// directory, so a restart still knows it:
///
/// ```json
/// {
///   "read_at" : 1795359600,
///   "resets_at" : 1795366800,
///   "started_at" : 1795348800,
///   "utilization" : 0.46
/// }
/// ```
actor UsageHub {
    /// The file the last reading is kept in, or `nil` to keep it in memory
    /// only.
    let file: URL?
    private(set) var usage = Usage()
    private var streams: [UUID: AsyncStream<Usage>.Continuation] = [:]
    private let logger: Logger

    /// Reads the last reading from `file`, if it is there.
    init(file: URL?, logger: Logger = Logger(label: "a-life.usage")) {
        self.file = file
        self.logger = logger
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let window = try JSONDecoder().decode(UsageWindow.self, from: Data(contentsOf: file))
            usage = Usage(revision: 1, window: window)
        } catch {
            logger.error("Couldn't read the last usage reading from \(file.path): \(error)")
        }
    }

    /// Takes `reading` as the latest. One that doesn't say how much is used
    /// keeps what the last one said about the same window.
    func record(_ reading: UsageWindow) {
        var reading = reading
        if reading.utilization == nil, let current = usage.window, current.resetsAt == reading.resetsAt {
            reading.utilization = current.utilization
        }
        guard reading != usage.window else { return }
        usage = Usage(revision: usage.revision + 1, window: reading)
        for stream in streams.values {
            stream.yield(usage)
        }
        save()
    }

    /// A made-up reading for the dummy characters, at `now`: a little more
    /// used each time, in a window that starts with the first and resets
    /// five hours later.
    func recordMadeUpUse(at now: Date) {
        if let window = usage.window, now < window.resetsAt {
            record(UsageWindow(utilization: min(1, (window.utilization ?? 0) + 0.04), resetsAt: window.resetsAt, readAt: now))
        } else {
            record(UsageWindow(utilization: 0.04, resetsAt: now.addingTimeInterval(UsageWindow.length), readAt: now))
        }
    }

    /// A stream of the usage as it is now, then as it is after each change.
    func subscribe() -> AsyncStream<Usage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Usage>.makeStream()
        continuation.yield(usage)
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    /// Ends the open streams.
    func stop() {
        for stream in streams.values {
            stream.finish()
        }
        streams = [:]
    }

    private func save() {
        guard let file, let window = usage.window else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(window).write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't write the usage reading to \(file.path): \(error)")
        }
    }

    private func forget(_ id: UUID) {
        streams[id] = nil
    }
}
