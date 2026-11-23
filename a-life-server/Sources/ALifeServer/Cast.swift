import ALifeAPI
import Foundation
import Yams

/// Someone on the lot. Each character gets a session of its own: a Claude
/// Code session, or a dummy that plays a script.
///
/// The characters are listed in the agents file; see `Cast`.
struct Character: Equatable, Sendable {
    /// Used in the session's URLs, such as `builder`.
    let id: String
    let name: String
    /// The character's colour, as `#RRGGBB`: its shirt on the lot, which its
    /// helpers wear too. `nil` leaves it to the front ends.
    let color: String?
    /// Whether the character changes things, and so asks before it does.
    /// The dummy picks its script by this.
    let changesThings: Bool
    /// Claude Code's permission mode for the character's session, which
    /// decides what it asks you about before it goes ahead.
    let permissionMode: String
    /// The model Claude Code plays the character on, unless it is changed in
    /// a front end's model picker. `nil` is Claude Code's own default.
    let model: ClaudeModel?
    /// Where the character's session works: on the lot, on a*life itself, or
    /// on a project of your own.
    let workspace: Workspace
    /// Who the character is, added to Claude Code's own system prompt.
    let role: String
    /// The helper the character sends off to do its work: a Claude Code
    /// subagent, and a sheep on the lot while it is out.
    let helper: Helper
}

/// Where a character's Claude Code session works, as the agents file's
/// `works_in` or `project` says.
enum Workspace: Equatable, Sendable {
    /// The lot: the directory the characters share, with the Builder's
    /// buildings and the Conservationist's beds.
    case lot
    /// A checkout of the a*life repository, the app and server that run the
    /// sim, such as the Engineer works in.
    case aLife
    /// A project of your own, somewhere other than the lot or a*life, such
    /// as an engineer you hand the work on another app to.
    case project(Project)
}

/// A project a character works on, as the agents file's `project` says: a
/// directory on this machine, a git repository the server clones, or
/// several repositories it clones side by side.
struct Project: Equatable, Sendable {
    /// The id of the character who works on it, which names its clone.
    let id: String
    let source: Source

    enum Source: Equatable, Sendable {
        /// A directory that is already on this machine, used as it is.
        case directory(URL)
        /// A git repository, cloned once into a directory the server keeps
        /// for the character, at `branch` or the repository's default.
        case repository(String, branch: String?)
        /// Several git repositories, such as an app and its server, each
        /// cloned once into the directory the server keeps for the
        /// character, side by side, so the character works on them all.
        case repositories([Repository])
    }

    /// One of the git repositories a project is made of.
    struct Repository: Equatable, Sendable {
        let address: String
        /// The branch to clone, or `nil` for the repository's default.
        var branch: String? = nil

        /// The directory it is cloned into, named after the repository, such
        /// as `app` for `git@github.com:you/app.git`.
        var name: String { Project.cloneName(of: address) ?? address }
    }

    /// The name a repository's clone gets, as `git clone` would choose it:
    /// the last part of its address without `.git`. `nil` if there's no
    /// such name that will do for a directory.
    static func cloneName(of address: String) -> String? {
        var name = Substring(address)
        while name.hasSuffix("/") { name = name.dropLast() }
        if let separator = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            name = name[name.index(after: separator)...]
        }
        if name.hasSuffix(".git") { name = name.dropLast(4) }
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("-") else { return nil }
        return String(name)
    }
}

/// A subagent a character can send off, defined for its session with
/// `--agents`. Claude Code runs it in a context of its own, with only the
/// tools listed here, and the character waits until it reports back.
struct Helper: Equatable, Sendable {
    /// The agent's name, such as `construction-worker`. The character names
    /// it to send it off.
    let name: String
    /// When to use it. Claude Code reads this to decide whom to send.
    let description: String
    /// The helper's own system prompt.
    let prompt: String
    let tools: [String]
    /// The model it runs on, or `nil` for its character's, whatever that is
    /// at the time.
    let model: ClaudeModel?

    /// The `--agents` entry for it.
    var definition: JSONValue {
        [
            "description": .string(description),
            "prompt": .string(prompt),
            "tools": .array(tools.map(JSONValue.string)),
            "model": .string(model?.rawValue ?? "inherit"),
        ]
    }
}

/// The characters on the lot, as the agents file lists them: the
/// `agents.yaml` next to this file, which the server ships with, or the file
/// `ALIFE_AGENTS_FILE` names. The file is read once, when the server starts,
/// and checked; anything wrong with it stops the server with a message that
/// says where. New agents can be added to it, as the Team Lead does, and
/// join the lot when the server next starts.
enum Cast {
    /// The agents file the server ships with. `Package.swift` copies it into
    /// the server's resources.
    static var shippedFile: URL {
        guard let file = Bundle.module.url(forResource: "agents", withExtension: "yaml") else {
            fatalError("agents.yaml is missing from the server's resources")
        }
        return file
    }

    /// The agents file in the a*life checkout the server was built from, the
    /// one the shipped file is copied from, if it is still there.
    static var checkoutFile: URL? {
        guard let checkout = ClaudeCode.builtFrom else { return nil }
        let file = checkout.appendingPathComponent("a-life-server/Sources/ALifeServer/agents.yaml")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The agents file to read: the one `ALIFE_AGENTS_FILE` names, or else
    /// the one in the checkout the server was built from, so that an agent
    /// added to it (by the Team Lead, say) joins the lot when the server
    /// restarts, without building it again. The shipped copy if there's
    /// neither.
    static func file(in environment: [String: String]) -> URL {
        guard let path = environment["ALIFE_AGENTS_FILE"], !path.isEmpty else { return checkoutFile ?? shippedFile }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Reads the agents file at `file` and checks it.
    static func load(contentsOf file: URL) throws -> [Character] {
        let yaml: String
        do {
            yaml = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw CastError("Couldn't read the agents file \(file.path): \(error.localizedDescription)")
        }
        return try decode(yaml, from: file.path)
    }

    /// The characters the text of an agents file lists, once checked.
    /// `source` names the file in errors.
    static func decode(_ yaml: String, from source: String) throws -> [Character] {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CastError("\(source) is empty. It should list the agents under agents:.")
        }
        do {
            return try YAMLDecoder().decode(AgentsFile.self, from: yaml).agents
        } catch let error as DecodingError {
            // Yams hands on its own DecodingErrors, and wraps anything else,
            // whether the YAML didn't parse or a check here refused a field.
            if case .dataCorrupted(let context) = error, let underlying = context.underlyingError {
                if let field = underlying as? FieldError {
                    throw CastError("\(source): \(field.path) \(field.problem)")
                }
                throw CastError("\(source) isn't valid YAML: \(underlying)")
            }
            throw CastError("\(source): \(explain(error))")
        } catch let error as FieldError {
            throw CastError("\(source): \(error.path) \(error.problem)")
        } catch {
            throw CastError("\(source) isn't valid YAML: \(error)")
        }
    }

    /// The permission modes Claude Code takes. `manual` is another name for
    /// `default`.
    static let permissionModes = ["default", "manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    // MARK: Adding an agent

    /// Adds the agent `entry` describes to the agents file at `file`, as
    /// `adding(_:to:from:)` does, and says who it is. The file is left as it
    /// was if the agent can't be added.
    @discardableResult
    static func add(_ entry: String, toFileAt file: URL) throws -> Character {
        let yaml: String
        do {
            yaml = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw CastError("Couldn't read the agents file \(file.path): \(error.localizedDescription)")
        }
        let (text, added) = try adding(entry, to: yaml, from: file.path)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw CastError("Couldn't write the agents file \(file.path): \(error.localizedDescription)")
        }
        return added
    }

    /// The text of the agents file `yaml` with one more agent at the end of
    /// its list: the one `entry` describes, its fields as an agent in the
    /// file has them (with or without the `- ` in front). Everything already
    /// in the file, its agents and its comments, stays as it is, word for
    /// word, so a new agent never changes or takes the place of another.
    ///
    /// The new agent is checked as the server checks the file when it
    /// starts, with the others: it needs an id and a name of its own. Throws,
    /// saying what's wrong and where, if it can't be added; and if the file
    /// is wrong already, since nothing could be added to it.
    static func adding(_ entry: String, to yaml: String, from source: String) throws -> (text: String, added: Character) {
        let cast = try decode(yaml, from: source)
        let fields = try fields(of: entry)

        let lines = yaml.components(separatedBy: "\n")
        // As the file's agents are indented, such as "  - id: builder".
        let indent = lines.lazy
            .compactMap { line -> String? in
                let spaces = line.prefix { $0 == " " }
                return line.dropFirst(spaces.count).hasPrefix("- ") ? String(spaces) : nil
            }
            .first ?? "  "
        let item = fields.enumerated().map { index, line in
            line.isEmpty ? "" : indent + (index == 0 ? "- " : "  ") + line
        }

        // After the last agent, before any comments at the end of the file,
        // such as an example to take the #s off; or else at its very end.
        var places: [Int] = []
        if let last = lines.lastIndex(where: { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return !text.isEmpty && !text.hasPrefix("#")
        }) {
            places.append(last + 1)
        }
        let end = lines.last == "" ? lines.count - 1 : lines.count
        if !places.contains(end) { places.append(end) }

        var firstProblem: Error?
        for place in places {
            var candidate = Array(lines[..<place])
            if place > 0, !candidate[place - 1].trimmingCharacters(in: .whitespaces).isEmpty { candidate.append("") }
            candidate += item
            candidate += lines[place...]
            var text = candidate.joined(separator: "\n")
            if !text.hasSuffix("\n") { text += "\n" }
            do {
                let after = try decode(text, from: source)
                // Only if everyone else is just as they were.
                if after.count == cast.count + 1, Array(after.dropLast()) == cast, let added = after.last {
                    return (text, added)
                }
            } catch {
                firstProblem = firstProblem ?? error
            }
        }
        throw firstProblem ?? CastError(
            "\(source): the new agent couldn't be added after the last one without changing the others. Add it to the file by hand."
        )
    }

    /// The lines of a new agent's fields, without the indent or the `- `
    /// they had, once checked to be one agent's fields.
    private static func fields(of entry: String) throws -> [String] {
        var lines = entry.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else {
            throw CastError("The new agent is empty. Give its fields, starting with id:.")
        }
        /// Without the indent they all share.
        func dedented(_ lines: [String]) -> [String] {
            let margin = lines.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
            return lines.map { $0.isEmpty ? "" : String($0.dropFirst(margin)) }
        }
        lines = dedented(lines)

        let node: Node?
        do {
            node = try Yams.compose(yaml: lines.joined(separator: "\n"))
        } catch {
            throw CastError("The new agent isn't valid YAML: \(error)")
        }
        switch node {
        case .mapping?:
            return lines
        case .sequence(let items)? where items.count == 1 && items.first?.mapping != nil && lines[0].hasPrefix("- "):
            // A list item, "- id: painter", stands for its fields.
            lines[0] = "  " + lines[0].dropFirst(2)
            return dedented(lines)
        default:
            throw CastError("The new agent should be one agent's fields, starting with id:, as an agent in the file has them.")
        }
    }

    // MARK: Explaining what's wrong

    /// Where in the file something is, such as `agents[2].helper.tools`.
    fileprivate static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("") { path, key in
            if let index = key.intValue { return "\(path)[\(index)]" }
            return path.isEmpty ? key.stringValue : "\(path).\(key.stringValue)"
        }
    }

    private static func explain(_ error: DecodingError) -> String {
        /// The field, or the file itself at the top.
        func place(_ codingPath: [any CodingKey]) -> String {
            codingPath.isEmpty ? "the file" : path(codingPath)
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(place(context.codingPath + [key])) is missing."
        case .valueNotFound(_, let context):
            return "\(place(context.codingPath)) is empty."
        case .typeMismatch(let type, let context):
            return "\(place(context.codingPath)) should be \(expected(type))."
        case .dataCorrupted(let context):
            return "\(place(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    /// What Yams expected to find, which it names by its own node types.
    private static func expected(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: return "true or false"
        case is Node.Mapping.Type: return "a set of fields"
        case is Node.Sequence.Type: return "a list"
        case is Node.Scalar.Type, is String.Type: return "a single value, not a list or a set of fields"
        default: return "a \(type)"
        }
    }
}

/// What is wrong with an agents file, and where.
struct CastError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - The file as it is written

/// A field that is there but isn't right. The path is where it is, such as
/// `agents[1].color`.
private struct FieldError: Error {
    let path: String
    let problem: String

    init(_ codingPath: [any CodingKey], _ problem: String) {
        path = Cast.path(codingPath)
        self.problem = problem
    }
}

/// The agents file, decoded and checked as it goes, so that each problem is
/// reported with where it is.
private struct AgentsFile: Decodable {
    let agents: [Character]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case agents
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "the file")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([AgentEntry].self, forKey: .agents)
        guard !entries.isEmpty else {
            throw FieldError([CodingKeys.agents], "is empty. There has to be at least one agent.")
        }
        for (index, entry) in entries.enumerated() {
            if let first = entries.firstIndex(where: { $0.character.id == entry.character.id }), first < index {
                throw FieldError(
                    [CodingKeys.agents, ListIndex(index), AgentEntry.CodingKeys.id],
                    "\"\(entry.character.id)\" is agents[\(first)]'s id too. Each agent needs an id of its own."
                )
            }
            // Two characters called the same couldn't be told apart on the lot.
            let name = entry.character.name.lowercased()
            if let first = entries.firstIndex(where: { $0.character.name.lowercased() == name }), first < index {
                throw FieldError(
                    [CodingKeys.agents, ListIndex(index), AgentEntry.CodingKeys.name],
                    "\"\(entry.character.name)\" is agents[\(first)]'s name too. Each agent needs a name of its own."
                )
            }
        }
        agents = entries.map(\.character)
    }
}

private struct AgentEntry: Decodable {
    let character: Character

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, color
        case permissionMode = "permission_mode"
        case model
        case worksIn = "works_in"
        case project
        case changesThings = "changes_things"
        case role, helper
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "an agent")
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.text(.id)
        try checkName(id, at: container.codingPath + [CodingKeys.id], what: "An id", example: "builder")

        let color = try container.optional(String.self, .color)
        if let color, !Self.isColor(color) {
            throw FieldError(container.codingPath + [CodingKeys.color], "should be a colour like \"#8050C8\", not \"\(color)\".")
        }

        let permissionMode = try container.optional(String.self, .permissionMode) ?? "default"
        guard Cast.permissionModes.contains(permissionMode) else {
            throw FieldError(
                container.codingPath + [CodingKeys.permissionMode],
                "\"\(permissionMode)\" isn't one of Claude Code's permission modes: \(Cast.permissionModes.joined(separator: ", "))."
            )
        }

        let model = try checkModel(container, .model, otherwise: "for Claude Code's own default")

        let worksIn = try container.optional(String.self, .worksIn)
        var workspace: Workspace
        switch worksIn ?? "lot" {
        case "lot": workspace = .lot
        case "a-life": workspace = .aLife
        case let other:
            throw FieldError(
                container.codingPath + [CodingKeys.worksIn],
                "\"\(other)\" isn't somewhere a character can work. It can be lot, the lot the characters share, or a-life, a checkout of the a*life repository. For a project of your own, use project instead."
            )
        }
        if let project = try container.optional(ProjectEntry.self, .project) {
            guard worksIn == nil else {
                throw FieldError(
                    container.codingPath + [CodingKeys.project],
                    "can't go with works_in. A character works on the lot, on a*life or on a project of its own, so leave one of them out."
                )
            }
            workspace = .project(Project(id: id, source: project.source))
        }

        character = Character(
            id: id,
            name: try container.text(.name),
            color: color,
            changesThings: try container.optional(Bool.self, .changesThings) ?? false,
            permissionMode: permissionMode,
            model: model,
            workspace: workspace,
            role: try container.text(.role),
            helper: try container.decode(HelperEntry.self, forKey: .helper).helper
        )
    }

    private static func isColor(_ text: String) -> Bool {
        text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// An agent's `project`: a `path` on this machine, a `repo` to clone, with
/// its `branch` if need be, or several `repos` to clone side by side.
private struct ProjectEntry: Decodable {
    let source: Project.Source

    enum CodingKeys: String, CodingKey, CaseIterable {
        case path, repo, repos, branch
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "a project")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.optional(String.self, .path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = try container.optional(String.self, .repo)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try container.optional(String.self, .branch)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let repos = try container.optional([RepoEntry].self, .repos) {
            let at = container.codingPath + [CodingKeys.repos]
            guard path == nil, repo == nil else {
                throw FieldError(
                    at,
                    "can't go with \(path != nil ? "path" : "repo"). A project is a directory on this machine, a git repository to clone, or several to clone side by side, so give only one of them."
                )
            }
            guard branch == nil else {
                throw FieldError(
                    container.codingPath + [CodingKeys.branch],
                    "goes with each of the repos it is for, not with the project."
                )
            }
            guard !repos.isEmpty else {
                throw FieldError(at, "is empty. List at least one repo for the server to clone.")
            }
            let repositories = repos.map(\.repository)
            for (index, repository) in repositories.enumerated() {
                if let first = repositories.firstIndex(where: { $0.name == repository.name }), first < index {
                    throw FieldError(
                        at + [ListIndex(index), RepoEntry.CodingKeys.repo],
                        "would be cloned into \(repository.name), as repos[\(first)] is. Each repo needs a directory of its own, so leave one of them out."
                    )
                }
            }
            source = .repositories(repositories)
            return
        }

        switch (path, repo) {
        case (nil, nil):
            throw FieldError(
                container.codingPath,
                "needs a path, a directory on this machine, a repo, a git repository for the server to clone, or repos, several of them."
            )
        case (.some, .some):
            throw FieldError(
                container.codingPath + [CodingKeys.repo],
                "can't go with path. A project is either a directory on this machine or a git repository to clone, so leave one of them out."
            )
        case (let path?, nil):
            if branch != nil {
                throw FieldError(
                    container.codingPath + [CodingKeys.branch],
                    "is only for a repo. A project's path is used as it is, at whatever branch it is on."
                )
            }
            source = .directory(try Self.directory(path, at: container.codingPath + [CodingKeys.path]))
        case (nil, let repo?):
            try Self.checkAddress(repo, at: container.codingPath + [CodingKeys.repo])
            if let branch {
                try Self.checkBranch(branch, at: container.codingPath + [CodingKeys.branch])
            }
            source = .repository(repo, branch: branch)
        }
    }

    /// Refuses `address` unless it is one `git clone` takes without asking
    /// for a password. The server clones with the person's own credentials
    /// and nobody to type them in, so an https address, which git asks for
    /// a password for, fails when the server starts: it has to be the
    /// repository's ssh address instead.
    static func checkAddress(_ address: String, at codingPath: [any CodingKey]) throws {
        guard isGitAddress(address) else {
            throw FieldError(
                codingPath,
                "\"\(address)\" isn't a git repository's address. It can be like git@github.com:you/app.git, or start with ssh://, git:// or file://."
            )
        }
        if let ssh = sshAddress(for: address) {
            throw FieldError(
                codingPath,
                "\"\(address)\" is an https address, which the server can't clone: it clones without asking for a password. Use the repository's ssh address instead, such as \(ssh)."
            )
        }
    }

    /// The ssh address, such as `git@github.com:you/app.git`, that stands
    /// for `address` if it is an http or https one, or `nil` if it isn't.
    static func sshAddress(for address: String) -> String? {
        guard let scheme = ["https://", "http://"].first(where: { address.lowercased().hasPrefix($0) }) else { return nil }
        let rest = address.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return "git@\(rest):you/app.git" }
        var host = rest[..<slash]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        let path = rest[rest.index(after: slash)...]
        return "git@\(host):\(path.isEmpty ? "you/app.git" : path)"
    }

    /// Refuses `branch` unless it can be a branch's name.
    static func checkBranch(_ branch: String, at codingPath: [any CodingKey]) throws {
        if branch.isEmpty || branch.hasPrefix("-") || branch.contains(where: \.isWhitespace) {
            throw FieldError(
                codingPath,
                "\"\(branch)\" won't do. A branch's name has no spaces and doesn't start with a hyphen, such as main."
            )
        }
    }

    /// The directory `path` names, with `~` expanded, once it is checked to
    /// be a full path to a directory that is there.
    private static func directory(_ path: String, at codingPath: [any CodingKey]) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw FieldError(codingPath, "\"\(path)\" should be a full path, such as ~/Development/my-app.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FieldError(
                codingPath,
                "\(expanded) isn't a directory on this machine. A project's path has to be there already; for one that isn't, give its repo instead."
            )
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// Whether `text` looks like an address `git clone` takes: a URL with a
    /// scheme git knows, or the `user@host:path` form ssh uses.
    static func isGitAddress(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-"), !text.contains(where: \.isWhitespace) else { return false }
        for scheme in ["https://", "http://", "ssh://", "git://", "file://"] where text.hasPrefix(scheme) {
            return text.count > scheme.count
        }
        // user@host:path, such as git@github.com:you/app.git
        guard let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") else { return false }
        let user = text[..<at], host = text[text.index(after: at)..<colon], path = text[text.index(after: colon)...]
        return !user.isEmpty && !host.isEmpty && !host.contains("/") && !path.isEmpty
    }
}

/// One of a project's `repos`: the `repo` to clone, with its `branch` if
/// need be.
private struct RepoEntry: Decodable {
    let repository: Project.Repository

    enum CodingKeys: String, CodingKey, CaseIterable {
        case repo, branch
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "a repo")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repo = try container.text(.repo)
        let at = container.codingPath + [CodingKeys.repo]
        try ProjectEntry.checkAddress(repo, at: at)
        guard Project.cloneName(of: repo) != nil else {
            throw FieldError(at, "\"\(repo)\" doesn't end in a name to clone it as, such as app in git@github.com:you/app.git.")
        }
        let branch = try container.optional(String.self, .branch)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch {
            try ProjectEntry.checkBranch(branch, at: container.codingPath + [CodingKeys.branch])
        }
        repository = Project.Repository(address: repo, branch: branch)
    }
}

private struct HelperEntry: Decodable {
    let helper: Helper

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, tools, model, description, prompt
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "a helper")
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let name = try container.text(.name)
        try checkName(name, at: container.codingPath + [CodingKeys.name], what: "A helper's name", example: "construction-worker")

        let tools = try container.decode([String].self, forKey: .tools).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !tools.isEmpty else {
            throw FieldError(container.codingPath + [CodingKeys.tools], "is empty. A helper needs at least one tool, such as Read.")
        }
        if let blank = tools.firstIndex(of: "") {
            throw FieldError(container.codingPath + [CodingKeys.tools, ListIndex(blank)], "is empty.")
        }

        let model = try checkModel(container, .model, otherwise: "to run it on its character's model")

        helper = Helper(
            name: name,
            description: try container.text(.description),
            prompt: try container.text(.prompt),
            tools: tools,
            model: model
        )
    }
}

// MARK: Checks

/// Ids and helper names go into URLs and Claude Code's `--agents`.
private func checkName(_ name: String, at codingPath: [any CodingKey], what: String, example: String) throws {
    let allowed = name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    guard allowed, name.first != "-" else {
        throw FieldError(codingPath, "\"\(name)\" won't do. \(what) has only lowercase letters, digits and hyphens, such as \"\(example)\".")
    }
}

/// The model a `model` field names, if it is there: one of the simple names
/// in `ClaudeModel`, such as `opus`. Anything else is refused, saying which
/// names there are.
private func checkModel<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key, otherwise: String) throws -> ClaudeModel? {
    guard let name = try container.optional(String.self, key)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    guard let model = ClaudeModel(rawValue: name) else {
        throw FieldError(
            container.codingPath + [key],
            "\"\(name)\" isn't one of the models a character can run on: \(ClaudeModel.names). Leave it out \(otherwise)."
        )
    }
    return model
}

/// Refuses a field the decoder doesn't know, which is most likely a typo
/// that would otherwise be ignored.
private func rejectUnknownFields<Known: CodingKey & CaseIterable>(
    in decoder: any Decoder,
    _ known: Known.Type,
    of what: String
) throws {
    let names = Known.allCases.map(\.stringValue)
    let container = try decoder.container(keyedBy: AnyKey.self)
    if let unknown = container.allKeys.first(where: { !names.contains($0.stringValue) }) {
        let list = names.dropLast().joined(separator: ", ") + (names.count > 1 ? " and " : "") + (names.last ?? "")
        throw FieldError(
            decoder.codingPath + [unknown],
            "isn't a field of \(what). The field\(names.count > 1 ? "s are" : " is") \(list)."
        )
    }
}

private extension KeyedDecodingContainer {
    /// Text that has to be there and can't be blank, without the line break
    /// a YAML block leaves at its end.
    func text(_ key: Key) throws -> String {
        let text = try decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FieldError(codingPath + [key], "is empty.") }
        return text
    }

    /// A field that can be left out, but not left empty: `color: #8050C8`
    /// without quotes is a comment, and so empty.
    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) throws -> Value? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            let hint = Value.self == String.self ? " Leave it out, or give it a value; one that starts with # needs quotes." : " Leave it out, or give it a value."
            throw FieldError(codingPath + [key], "is empty." + hint)
        }
        return try decode(type, forKey: key)
    }
}

/// Any field name, to see every field a mapping has.
private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// A place in a list, for saying where something is.
private struct ListIndex: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }

    init(_ index: Int) {
        intValue = index
    }

    init?(stringValue: String) {
        nil
    }

    init?(intValue: Int) {
        self.intValue = intValue
    }
}
