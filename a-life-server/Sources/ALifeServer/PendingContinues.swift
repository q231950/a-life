import Foundation
import Vapor

/// The characters waiting out the 5-hour usage limit, to be told "please
/// continue" once it resets, kept in a small JSON file so a restart of the
/// server doesn't forget them.
///
/// The file, `continues.json` in the server's state directory, lists one
/// entry per character waiting:
///
/// ```json
/// [
///   {
///     "character" : "builder",
///     "claude_session_id" : "1f0c…",
///     "resets_at" : 1763820000
///   }
/// ]
/// ```
///
/// `resets_at` is in seconds since 1970. The file goes once nobody is
/// waiting. Without a file, they're kept in memory only.
actor PendingContinues {
    /// One character waiting for the limit to reset.
    struct Entry: Codable, Equatable, Sendable {
        /// The character's id, such as `builder`.
        var character: String
        /// The Claude Code session to carry on in, resumed if its CLI has
        /// exited.
        var claudeSessionID: String
        /// When the limit resets. The character carries on a minute after.
        var resetsAt: Date

        enum CodingKeys: String, CodingKey {
            case character
            case claudeSessionID = "claude_session_id"
            case resetsAt = "resets_at"
        }
    }

    /// The file they're kept in, or `nil` to keep them in memory only.
    let file: URL?
    private var entries: [String: Entry] = [:]
    private let logger: Logger

    /// Reads what `file` holds, if it is there.
    init(file: URL?, logger: Logger = Logger(label: "a-life.continues")) {
        self.file = file
        self.logger = logger
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let saved = try decoder.decode([Entry].self, from: Data(contentsOf: file))
            entries = Dictionary(saved.map { ($0.character, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            logger.error("Couldn't read the characters waiting for the usage limit from \(file.path), so they won't carry on by themselves: \(error)")
        }
    }

    /// Everyone waiting, by character id.
    var all: [String: Entry] { entries }

    /// Remembers that a character is waiting, in place of what it waited
    /// for before.
    func set(_ entry: Entry) {
        entries[entry.character] = entry
        save()
    }

    /// Forgets that the character `id` was waiting, once it has carried on
    /// or been told something else.
    func remove(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
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
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sorted = entries.values.sorted { $0.character < $1.character }
            try encoder.encode(sorted).write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't write the characters waiting for the usage limit to \(file.path): \(error)")
        }
    }
}
