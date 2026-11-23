import ALifeAPI
import Foundation
import Vapor

/// The models chosen for the characters in a front end's model picker,
/// kept in a small JSON file so a restart of the server doesn't forget
/// them.
///
/// The file, `models.json` in the server's state directory, has an entry
/// for each character whose model was changed from the agents file's,
/// with the agents file's model at the time:
///
/// ```json
/// {
///   "builder" : {
///     "file_model" : "haiku",
///     "model" : "opus"
///   }
/// }
/// ```
///
/// A choice lasts until the agents file gives the character another model,
/// which is the newer word, or until the picker goes back to the file's.
/// Without a file, choices are kept in memory only.
actor ModelChoices {
    /// The model chosen for one character.
    struct Entry: Codable, Equatable, Sendable {
        var model: ClaudeModel
        /// The agents file's model when it was chosen. If the file now says
        /// another, the choice is dropped.
        var fileModel: ClaudeModel?

        enum CodingKeys: String, CodingKey {
            case model
            case fileModel = "file_model"
        }
    }

    /// The file they're kept in, or `nil` to keep them in memory only.
    let file: URL?
    private var entries: [String: Entry] = [:]
    private let logger: Logger

    /// Reads what `file` holds, if it is there.
    init(file: URL?, logger: Logger = Logger(label: "a-life.models")) {
        self.file = file
        self.logger = logger
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
        } catch {
            logger.error("Couldn't read the models chosen in the app from \(file.path), so every character runs on the agents file's: \(error)")
        }
    }

    /// Every choice, by character id.
    var all: [String: Entry] { entries }

    /// The model `character` runs on when the server starts: the one chosen
    /// for it before, unless the agents file has given it another model
    /// since, or else the agents file's.
    func model(for character: Character) -> ClaudeModel? {
        guard let entry = entries[character.id] else { return character.model }
        guard entry.fileModel == character.model else {
            logger.notice("The agents file gives \(character.name) \(character.model?.rawValue ?? "no model") now, so the \(entry.model.rawValue) chosen in the app is dropped")
            entries[character.id] = nil
            save()
            return character.model
        }
        return entry.model
    }

    /// Remembers that `model` was chosen for `character`; `nil`, or the
    /// agents file's own, forgets the choice.
    func choose(_ model: ClaudeModel?, for character: Character) {
        let entry = model.flatMap { $0 == character.model ? nil : Entry(model: $0, fileModel: character.model) }
        guard entries[character.id] != entry else { return }
        entries[character.id] = entry
        save()
    }

    private func save() {
        guard let file else { return }
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                return
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't write the models chosen in the app to \(file.path): \(error)")
        }
    }
}

/// What the server's Claude Code says about the models a character can be
/// switched to: the version each simple name stands for right now, such as
/// Opus 5.5 for `opus`, and what it is good for. It is learnt from Claude
/// Code's answer to `initialize`, asked once when the server starts and
/// again each time a character's Claude Code starts. Until then, the models
/// are known by their plain names only.
actor ModelCatalog {
    /// How long the question asked when the server starts may take.
    static let patience: Duration = .seconds(20)

    private var known: [ClaudeModel: ModelOption] = [:]
    private var asking: Task<Void, Never>?

    /// Every model a character can run on, strongest first, as far as it is
    /// known.
    var options: [ModelOption] {
        ClaudeModel.allCases.map { known[$0] ?? ModelOption(model: $0) }
    }

    /// The same, once the question asked when the server started has been
    /// answered, if it is still out.
    func optionsWhenKnown() async -> [ModelOption] {
        await asking?.value
        return options
    }

    /// The model `model` stands for right now, such as `claude-opus-5-5`,
    /// if Claude Code has said.
    func resolved(_ model: ClaudeModel) -> String? {
        known[model]?.resolved
    }

    /// Takes in the `models` of Claude Code's answer to `initialize`: those
    /// with one of the simple names, with the version each stands for.
    func learn(from answer: JSONValue?) {
        for entry in answer?["models"]?.array ?? [] {
            guard let value = entry["value"]?.string, let model = ClaudeModel(rawValue: value) else { continue }
            func text(_ key: String) -> String? {
                entry[key]?.string.flatMap { $0.isEmpty ? nil : $0 }
            }
            known[model] = ModelOption(model: model, name: text("displayName"), description: text("description"), resolved: text("resolvedModel"))
        }
    }

    /// Asks a Claude Code of its own, started by `launcher` on the lot with
    /// nothing to do, which models there are, in the background. It is
    /// only asked `initialize`, so it takes no turn and calls no model.
    func ask(_ launcher: any ClaudeCodeLauncher, logger: Logger) {
        asking = Task {
            let answer = await Self.initializeAnswer(from: launcher, patience: Self.patience)
            learn(from: answer)
            let versions = ClaudeModel.allCases.compactMap { known[$0]?.name }
            if versions.isEmpty {
                logger.warning("Claude Code didn't say which versions the models stand for, so the app shows their plain names until a character starts")
            } else {
                logger.notice("The models a character can run on: \(versions.joined(separator: ", "))")
            }
        }
    }

    /// The answer to `initialize` from a Claude Code started by `launcher`
    /// for nothing else, or `nil` if it doesn't come within `patience`.
    static func initializeAnswer(from launcher: any ClaudeCodeLauncher, patience: Duration) async -> JSONValue? {
        let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        guard let connection = try? launcher.launch(arguments, in: .lot) else { return nil }
        defer { connection.close() }
        let id = UUID().uuidString
        try? connection.send(["type": "control_request", "request_id": .string(id), "request": ["subtype": "initialize"]])
        return await withTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                for await message in connection.messages
                    where message["type"]?.string == "control_response" && message["response"]?["request_id"]?.string == id
                {
                    return message["response"]?["response"]
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: patience)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
