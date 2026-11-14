import Foundation

/// Starts Claude Code sessions. `ClaudeCode` runs the real CLI; the tests
/// put a stand-in here.
protocol ClaudeCodeLauncher: Sendable {
    /// Starts a Claude Code CLI with these arguments, talking stream-json,
    /// working in `workspace`.
    func launch(_ arguments: [String], in workspace: Workspace) throws -> any ClaudeCodeConnection
}

/// One running Claude Code CLI, as the Agent SDK talks to it: messages go
/// in on its stdin and come out of its stdout, one JSON object per line.
protocol ClaudeCodeConnection: AnyObject, Sendable {
    /// What the CLI writes, one message per line. It ends when the CLI exits.
    var messages: AsyncStream<JSONValue> { get }
    /// Writes one message to the CLI. Throws once it has gone away.
    func send(_ message: JSONValue) throws
    /// Stops the CLI, whatever it is doing.
    func close()
    /// The last few lines the CLI wrote to stderr, to explain a failure.
    func diagnostics() -> String
}

/// The Claude Code installed on this machine: the `claude` command, run in
/// the directory its character works in, with whatever login and settings
/// it already has.
struct ClaudeCode: ClaudeCodeLauncher {
    /// The `claude` command.
    let executable: URL
    /// The working directory of the characters who work on the lot, which
    /// they share.
    let lot: URL
    /// The working directory of the characters who work on a*life itself,
    /// such as the Engineer: a checkout of the a*life repository. `nil` if
    /// there is none, and then they can't start.
    var repository: URL?
    /// The model for every character, or `nil` for Claude Code's default.
    var model: String?

    func launch(_ arguments: [String], in workspace: Workspace) throws -> any ClaudeCodeConnection {
        let directory: URL
        switch workspace {
        case .lot:
            directory = lot
        case .aLife:
            guard let repository else {
                throw ConfigurationError("There's no a*life checkout to work in. Set ALIFE_REPO_DIR to one and restart the server.")
            }
            directory = repository
        }

        var environment = ProcessInfo.processInfo.environment
        // A server started from inside a Claude Code session inherits these;
        // they'd make the character think it runs inside that session.
        environment["CLAUDECODE"] = nil
        environment["CLAUDE_CODE_ENTRYPOINT"] = nil
        // Helpers run in the foreground: the character waits for each one to
        // report back before it carries on, the way the lot shows it.
        environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"

        var arguments = arguments
        if let model { arguments += ["--model", model] }
        return try ClaudeCodeProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment
        )
    }

    /// The a*life checkout the characters who work on a*life work in:
    /// `ALIFE_REPO_DIR` if it is set, otherwise the checkout this server was
    /// built from, if it is still there. Throws if `ALIFE_REPO_DIR` isn't a
    /// directory.
    static func findRepository(in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        if let path = environment["ALIFE_REPO_DIR"], !path.isEmpty {
            let repository = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError("ALIFE_REPO_DIR is \(path), which isn't a directory. Set it to a checkout of a*life.")
            }
            return repository
        }
        return builtFrom
    }

    /// The a*life checkout this server was built from, if it is still there:
    /// the one this file is in, at `a-life-server/Sources/ALifeServer/`.
    static var builtFrom: URL? {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ALifeServer
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // a-life-server
            .deletingLastPathComponent()
        let server = checkout.appendingPathComponent("a-life-server/Package.swift").path
        return FileManager.default.fileExists(atPath: server) ? checkout : nil
    }

    /// The `claude` command: `ALIFE_CLAUDE_PATH` if it is set, otherwise the
    /// first `claude` on the `PATH` or in the places the installers use.
    static func findExecutable(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["ALIFE_CLAUDE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("claude").path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

enum ClaudeCodeError: Error, CustomStringConvertible {
    case closed

    var description: String {
        switch self {
        case .closed: return "The Claude Code session has ended"
        }
    }
}

/// A `claude` child process with its stdin, stdout and stderr on pipes.
final class ClaudeCodeProcess: ClaudeCodeConnection, @unchecked Sendable {
    let messages: AsyncStream<JSONValue>

    private let process: Process
    private let input: FileHandle
    /// Guards `closed`, writes to `input` and `stderrTail`.
    private let lock = NSLock()
    private var closed = false
    private var stderrTail: [String] = []

    /// A write to a CLI that has exited must fail, not kill the server.
    private static let ignoreBrokenPipes: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) throws {
        Self.ignoreBrokenPipes

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting

        let (messages, continuation) = AsyncStream<JSONValue>.makeStream()
        self.messages = messages

        try process.run()

        // Plain threads, since reading a pipe blocks.
        let output = stdout.fileHandleForReading
        Thread.detachNewThread {
            Self.readLines(from: output) { line in
                if let message = try? JSONValue.decode(line) {
                    continuation.yield(message)
                }
            }
            continuation.finish() // the CLI has exited
        }
        let errors = stderr.fileHandleForReading
        Thread.detachNewThread { [self] in
            Self.readLines(from: errors) { line in
                remember(String(decoding: line, as: UTF8.self))
            }
        }
    }

    func send(_ message: JSONValue) throws {
        var line = try message.encoded()
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw ClaudeCodeError.closed }
        try input.write(contentsOf: line)
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }

        try? input.close()
        // SIGTERM lets the CLI stop its tools and save the session. One that
        // is still around a few seconds later is killed.
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func diagnostics() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTail.joined(separator: "\n")
    }

    private func remember(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        stderrTail.append(line)
        if stderrTail.count > 10 { stderrTail.removeFirst() }
    }

    /// Calls `body` with each line read from `handle`, until the other end
    /// closes it.
    private static func readLines(from handle: FileHandle, _ body: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // end of file
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { body(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { body(buffer) }
    }
}
