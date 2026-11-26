import ALifeAPI
import Foundation
import Vapor

/// What a character did in one job, which its notification's summary is
/// made from. Only what is safe to send through Apple is kept: never the
/// reply, the commands, the other tools' inputs or the errors.
struct JobRecord: Equatable, Sendable {
    /// What you asked: your last message before the job started.
    var task: String?
    /// When the job started, if known.
    var startedAt: Date?
    /// The distinct paths of the files it changed, in the order it changed
    /// them.
    var filesChanged: [String] = []
    /// How many commands it ran.
    var commands = 0
    /// How many helpers it sent off.
    var helpers = 0
}

/// Decides, from one session's events in order, when a character has
/// finished a job and so when to send a notification, and keeps the job's
/// record meanwhile. Plain code, with no actors or I/O, so the tests can
/// drive it with events.
///
/// A job starts with `session.status` `running`. It notifies when it ends
/// with `end_turn`: as `finished`, or as `error` if the last thing it said
/// was an error. A job that ends on an interrupt or the usage limit, or a
/// conversation that starts over, sends nothing; a character waiting for
/// your answer to a tool call is still on its job. So each job sends one
/// notification at most, and only one that was seen running.
struct JobWatch: Sendable {
    /// The tools that change a file, whose input is the file's path.
    static let fileTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    /// The tool that runs a command.
    static let commandTool = "Bash"

    /// A job that ended, to tell your devices about.
    struct Ending: Equatable, Sendable {
        var kind: PushRoute.Kind
        var record: JobRecord
        /// How long it took, if known.
        var duration: TimeInterval?
        var conversationID: String?
        /// The reply or error that ended it, if there was one.
        var messageID: String?
        /// The sequence number of the status that ended it.
        var seq: Int
    }

    private var conversationID: String?
    /// Your last message, which the next job takes as its task.
    private var lastTask: String?
    /// The job under way, if one is.
    private var job: JobRecord?
    /// The job's last reply or error, and whether it was an error.
    private var lastSaid: (id: String, isError: Bool)?

    /// Starts from the session as it is: its conversation, your last
    /// message, and a job under way if it is running, which started no
    /// later than `now`.
    init(seededFrom state: SessionState? = nil, now: Date = Date()) {
        guard let state else { return }
        conversationID = state.conversationID
        lastTask = state.messages.last(where: Self.isFromYou)?.text
        if state.status == .running {
            job = JobRecord(task: lastTask, startedAt: now)
        }
    }

    /// Takes in the session's next event, and returns the job it ended, if
    /// it ended one that should be told about.
    mutating func feed(_ envelope: EventEnvelope) -> Ending? {
        switch envelope.event {
        case .conversationStarted(let id):
            conversationID = id
            lastTask = nil
            job = nil
            lastSaid = nil
        case .statusChanged(.running, _, _):
            if job == nil {
                job = JobRecord(task: lastTask, startedAt: envelope.time)
                lastSaid = nil
            }
        case .statusChanged(.idle, .requiresAction, _):
            break // waiting for you, still on the job
        case .statusChanged(.idle, .endTurn, _):
            guard let job else { return nil }
            defer {
                self.job = nil
                lastSaid = nil
            }
            var duration: TimeInterval?
            if let start = job.startedAt, let end = envelope.time {
                duration = max(0, end.timeIntervalSince(start))
            }
            return Ending(
                kind: lastSaid?.isError == true ? .error : .finished,
                record: job,
                duration: duration,
                conversationID: conversationID,
                messageID: lastSaid?.id,
                seq: envelope.seq
            )
        case .statusChanged:
            // Interrupted, waiting out the usage limit, or anything else:
            // not the end of the work as far as you're concerned.
            job = nil
            lastSaid = nil
        case .message(let message):
            if Self.isFromYou(message) {
                lastTask = message.text
            } else if message.kind != .user, job != nil {
                lastSaid = (message.id, message.kind == .error)
            }
        case .toolUsed(let toolUse):
            note(toolUse.toolName, input: toolUse.input, counts: true)
        case .approvalRequested(let approval):
            // A helper's own tool uses aren't events, but what it asks is.
            note(approval.toolName, input: Self.path(asked: approval.input), counts: false)
        case .subagentStarted:
            job?.helpers += 1
        default:
            break
        }
        return nil
    }

    /// Notes a tool used, or asked about, in the job under way. Commands
    /// are counted only once, from their use.
    private mutating func note(_ toolName: String, input: String, counts: Bool) {
        guard job != nil else { return }
        if Self.fileTools.contains(toolName), !input.isEmpty, job?.filesChanged.contains(input) == false {
            job?.filesChanged.append(input)
        } else if counts, toolName == Self.commandTool {
            job?.commands += 1
        }
    }

    /// A message from you, rather than from a*life on your behalf.
    private static func isFromYou(_ message: Message) -> Bool {
        message.kind == .user && message.speaker != Message.aLife
    }

    /// The path in what a helper asks, which comes after its name, such as
    /// "Explore: /lot/README.md".
    private static func path(asked input: String) -> String {
        guard let range = input.range(of: ": /") else { return input }
        return String(input[input.index(before: range.upperBound)...])
    }
}

/// Sends a notification to every registered device when any character
/// finishes a job. It follows each session's live events, as a front end
/// would, with a `JobWatch` for each, and sends in a task of its own, so a
/// slow Apple doesn't hold up the session, and one device failing doesn't
/// stop the others. A device whose token Apple says is gone is forgotten.
///
/// With no sender, pushes are off: devices can still register, and hear
/// once the server is set up and restarted.
actor PushNotifier {
    let registry: DeviceRegistry
    /// What sends, or `nil` while pushes are off.
    let sender: (any PushSender)?
    /// The bundle id devices must register with, if it is known.
    let topic: String?
    private let logger: Logger
    private var following: [Task<Void, Never>] = []

    init(registry: DeviceRegistry, sender: (any PushSender)?, topic: String?, logger: Logger = Logger(label: "a-life.push")) {
        self.registry = registry
        self.sender = sender
        self.topic = topic
        self.logger = logger
    }

    /// Whether this server sends notifications.
    nonisolated var isEnabled: Bool { sender != nil }

    /// Starts following `sessions`, from now on, if pushes are on.
    func follow(_ sessions: [HostedSession]) async {
        guard sender != nil else { return }
        for session in sessions {
            let (state, events) = await session.hub.follow()
            let id = session.id
            following.append(Task { [weak self] in
                var watch = JobWatch(seededFrom: state)
                for await envelope in events {
                    guard let ending = watch.feed(envelope) else { continue }
                    await self?.notify(ending, name: state.name, sessionID: id)
                }
            })
        }
    }

    /// Sends the notification for a job that ended.
    private func notify(_ ending: JobWatch.Ending, name: String, sessionID: String) async {
        let route = PushRoute(
            serverID: registry.serverID,
            session: sessionID,
            conversation: ending.conversationID,
            message: ending.messageID,
            seq: ending.seq,
            kind: ending.kind
        )
        let notice = PushNotice.job(
            name: name,
            summary: JobSummary.body(of: ending.record, duration: ending.duration, kind: ending.kind, name: name),
            fallback: JobSummary.fallback(kind: ending.kind, name: name),
            route: route
        )
        let registered = await registry.all
        let devices = registered.filter { topic == nil || $0.bundleID == topic }
        guard !devices.isEmpty else { return }
        logger.info("Telling \(devices.count) device(s) that \(name) \(ending.kind == .error ? "stopped" : "finished")")
        Task { await self.deliver(notice, to: devices) }
    }

    /// Sends `notice` to each of `devices` at once, and forgets the ones
    /// Apple says are gone.
    private func deliver(_ notice: PushNotice, to devices: [RegisteredDevice]) async {
        guard let sender else { return }
        await withTaskGroup(of: (RegisteredDevice, PushResult).self) { group in
            for device in devices {
                group.addTask { (device, await sender.send(notice, to: device)) }
            }
            for await (device, result) in group where result == .goneForGood {
                await registry.drop(token: device.token)
            }
        }
    }

    /// Sends one device the test notification. `nil` if pushes are off.
    func sendTest(to device: RegisteredDevice) async -> PushResult? {
        guard let sender else { return nil }
        let result = await sender.send(.test, to: device)
        if result == .goneForGood {
            await registry.drop(token: device.token)
        }
        return result
    }

    /// The server is stopping.
    func stop() async {
        for task in following { task.cancel() }
        following = []
        await sender?.shutdown()
    }
}
