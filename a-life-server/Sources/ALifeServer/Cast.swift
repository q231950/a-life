import Foundation
import Yams

/// Someone on the lot. Each character gets a session of its own: a Claude
/// Code session, or a dummy that plays a script.
///
/// The characters are listed in the agents file; see `Cast`.
struct Character: Equatable, Sendable {
    /// Used in the session's URLs, such as `gardener`.
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
    /// Who the character is, added to Claude Code's own system prompt.
    let role: String
    /// The helper the character sends off to do its work: a Claude Code
    /// subagent, and a sheep on the lot while it is out.
    let helper: Helper
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

    /// The `--agents` entry for it. It runs on its character's model.
    var definition: JSONValue {
        [
            "description": .string(description),
            "prompt": .string(prompt),
            "tools": .array(tools.map(JSONValue.string)),
            "model": "inherit",
        ]
    }
}

/// The characters on the lot, as the agents file lists them: the
/// `agents.yaml` next to this file, which the server ships with, or the file
/// `ALIFE_AGENTS_FILE` names. The file is read once, when the server starts,
/// and checked; anything wrong with it stops the server with a message that
/// says where.
enum Cast {
    /// The agents file the server ships with. `Package.swift` copies it into
    /// the server's resources.
    static var shippedFile: URL {
        guard let file = Bundle.module.url(forResource: "agents", withExtension: "yaml") else {
            fatalError("agents.yaml is missing from the server's resources")
        }
        return file
    }

    /// The agents file to read: the one `ALIFE_AGENTS_FILE` names, or the
    /// shipped one if it isn't set.
    static func file(in environment: [String: String]) -> URL {
        guard let path = environment["ALIFE_AGENTS_FILE"], !path.isEmpty else { return shippedFile }
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
        }
        agents = entries.map(\.character)
    }
}

private struct AgentEntry: Decodable {
    let character: Character

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, color
        case permissionMode = "permission_mode"
        case changesThings = "changes_things"
        case role, helper
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownFields(in: decoder, CodingKeys.self, of: "an agent")
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.text(.id)
        try checkName(id, at: container.codingPath + [CodingKeys.id], what: "An id", example: "gardener")

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

        character = Character(
            id: id,
            name: try container.text(.name),
            color: color,
            changesThings: try container.optional(Bool.self, .changesThings) ?? false,
            permissionMode: permissionMode,
            role: try container.text(.role),
            helper: try container.decode(HelperEntry.self, forKey: .helper).helper
        )
    }

    private static func isColor(_ text: String) -> Bool {
        text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy(\.isHexDigit)
    }
}

private struct HelperEntry: Decodable {
    let helper: Helper

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, tools, description, prompt
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

        helper = Helper(
            name: name,
            description: try container.text(.description),
            prompt: try container.text(.prompt),
            tools: tools
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
