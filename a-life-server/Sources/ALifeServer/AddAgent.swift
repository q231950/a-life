import Foundation

/// `ALifeServer add-agent`: adds a new agent to the agents file, which joins
/// the lot when the server next starts. The Team Lead's recruiter runs it,
/// with the command and the file the server gives its session in
/// `ALIFE_SERVER_COMMAND` and `ALIFE_AGENTS_FILE`.
///
/// The new agent's fields come on standard input, or from the file named
/// after the command, and are checked as the server checks the file; the
/// agents already there, and the file's comments, are left as they are.
/// Nothing else of the server starts.
enum AddAgent {
    /// The command's name, as it is given to the server.
    static let command = "add-agent"

    /// Adds the agent `entry` describes to the agents file the environment
    /// says (see `Cast.file(in:)`), and says what became of it: whether it
    /// was added, and what to say about it.
    static func run(entry: String, environment: [String: String]) -> (added: Bool, said: String) {
        let file = Cast.file(in: environment)
        do {
            let agent = try Cast.add(entry, toFileAt: file)
            return (true, "Added the \(agent.name) (\(agent.id)) to \(file.path). They join the lot when the server restarts.")
        } catch {
            return (false, "\(error)\nNothing was changed in \(file.path).")
        }
    }

    /// Runs the command with what came after its name on the command line,
    /// and returns the status to exit with.
    static func main(_ arguments: [String]) -> Int32 {
        let entry: String
        if let path = arguments.first, path != "-" {
            guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else {
                FileHandle.standardError.write(Data("Couldn't read the new agent from \(path).\n".utf8))
                return 1
            }
            entry = text
        } else {
            entry = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let (added, said) = run(entry: entry, environment: ProcessInfo.processInfo.environment)
        (added ? FileHandle.standardOutput : FileHandle.standardError).write(Data((said + "\n").utf8))
        return added ? 0 : 1
    }
}
