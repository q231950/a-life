import Foundation

/// `ALifeServer remove-agent <id> --confirmed`: takes an agent away from the
/// added agents file, which the running server watches, so the agent leaves
/// the lot at once; with no server running, it is gone when the server next
/// starts. The Team Lead's recruiter runs it, once the person has said yes,
/// with the command and the files the server gives its session in
/// `ALIFE_SERVER_COMMAND`, `ALIFE_AGENTS_FILE` and `ALIFE_ADDED_AGENTS_FILE`.
///
/// Without `--confirmed` it only says who would be taken away, and changes
/// nothing, so that the agent can be named to the person before it goes. It
/// only takes away added agents: the built-in agents and the agents in the
/// agents file always stay, and it says so (see `Cast.removable(_:in:)`). The
/// other agents, and the file's comments, are left as they are. Nothing else
/// of the server starts.
enum RemoveAgent {
    /// The command's name, as it is given to the server.
    static let command = "remove-agent"

    /// What has to follow the agent's id for it to be taken away: that the
    /// person has said yes.
    static let confirmed = "--confirmed"

    /// Takes the agent `id` names, by its id or its name, away from the added
    /// agents file the environment says (see `Cast.addedFile(in:)`), if
    /// `confirmed`, or else only says who it would be; and says what became
    /// of it: whether it went well, and what to say about it.
    static func run(id: String, confirmed: Bool, environment: [String: String]) -> (succeeded: Bool, said: String) {
        do {
            guard confirmed else {
                let (agent, file) = try Cast.removable(id, in: environment)
                return (true, "The \(agent.name) (\(agent.id)) can be taken away from \(file.path), but nothing was changed. Ask the person whether to take the \(agent.name) away, and only once they say yes, run this again with \(Self.confirmed).")
            }
            let (agent, file) = try Cast.remove(id, in: environment)
            return (true, "Took the \(agent.name) (\(agent.id)) away from \(file.path). They leave the lot straight away if the server is running, and otherwise are gone when it next starts.")
        } catch {
            return (false, "\(error)\nNothing was changed.")
        }
    }

    /// Runs the command with what came after its name on the command line,
    /// and returns the status to exit with.
    static func main(_ arguments: [String]) -> Int32 {
        let ids = arguments.filter { $0 != confirmed }
        guard ids.count == 1, let id = ids.first, !id.hasPrefix("-") else {
            FileHandle.standardError.write(Data("Give the id of the agent to take away, such as: remove-agent painter \(confirmed)\n".utf8))
            return 1
        }
        let (succeeded, said) = run(id: id, confirmed: arguments.contains(confirmed), environment: ProcessInfo.processInfo.environment)
        (succeeded ? FileHandle.standardOutput : FileHandle.standardError).write(Data((said + "\n").utf8))
        return succeeded ? 0 : 1
    }
}
