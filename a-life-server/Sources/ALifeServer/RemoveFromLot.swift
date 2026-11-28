import Foundation

/// `ALifeServer remove-from-lot <folder>/<name>.md`: takes a building or a
/// bed off the lot by deleting its file, which the running server notices
/// within a second. The Builder's construction worker runs it to pull a
/// building down, and the Conservationist's keeper to dig up a bed or take
/// the animals in, with the command the server gives their sessions in
/// `ALIFE_SERVER_COMMAND`. Their helpers have no other way to delete a file.
///
/// It is kept narrow on purpose. It only deletes a Markdown file directly
/// in the lot's `buildings/` or `garden/`, and only in the folder of the
/// character whose session runs it, as `ALIFE_CHARACTER` says: `buildings/`
/// for the Builder and `garden/` for the Conservationist, so the keeper can
/// never take a building away. It refuses anything else, such as another
/// folder, a path that climbs out, a link, a file that isn't Markdown or
/// one that isn't there, and says why. Nothing else of the server starts.
enum RemoveFromLot {
    /// The command's name, as it is given to the server.
    static let command = "remove-from-lot"

    /// The folder each character may take things out of, by its id, and
    /// what is kept there.
    static let folders: [String: (folder: String, things: String)] = [
        "builder": ("buildings", "buildings"),
        "conservationist": ("garden", "beds"),
    ]

    /// Takes the file `path` names, such as `buildings/barn.md` or just
    /// `barn.md`, off the lot the environment says, if the character in
    /// `ALIFE_CHARACTER` may; and says what became of it: whether it went
    /// well, and what to say about it.
    static func run(_ path: String, environment: [String: String]) -> (succeeded: Bool, said: String) {
        guard let character = environment["ALIFE_CHARACTER"], let own = folders[character] else {
            return (false, "Only the Builder's construction worker and the Conservationist's keeper can take things off the lot with \(command). Nothing was changed.")
        }
        let (folder, things) = own
        let example = "\(folder)/\(folder == "buildings" ? "shed" : "rose-bed").md"

        // The file's name, directly in the character's own folder.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name: String
        switch parts.count {
        case 1:
            name = parts[0]
        case 2 where parts[0] == folder:
            name = parts[1]
        case 2 where folders.values.contains { $0.folder == parts[0] }:
            return (false, "\(path) isn't yours to take away: you only take \(things) out of \(folder)/. Nothing was changed.")
        default:
            return (false, "\(path) isn't a file in \(folder)/. Give one such as \(example). Nothing was changed.")
        }
        guard !name.isEmpty, !name.hasPrefix("."), name.lowercased().hasSuffix(".md"), name.count > 3 else {
            return (false, "\(path) isn't a Markdown file in \(folder)/. Give one such as \(example). Nothing was changed.")
        }

        let files = FileManager.default
        let directory = lotDirectory(in: environment).appendingPathComponent(folder, isDirectory: true)
        // Neither the folder nor the file may be a link, which could lead
        // anywhere.
        guard (try? files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else {
            return (false, "There's no \(folder)/ on the lot, or it is a link rather than a folder. Nothing was changed.")
        }
        let file = directory.appendingPathComponent(name)
        let shown = "\(folder)/\(name)"
        guard let type = try? files.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType else {
            return (false, "There's no \(shown) on the lot. Read lot.md to see what is there. Nothing was changed.")
        }
        guard type == .typeRegular else {
            return (false, "\(shown) isn't a plain file, so it can't be taken away with \(command). Nothing was changed.")
        }
        do {
            try files.removeItem(at: file)
        } catch {
            return (false, "Couldn't take \(shown) away: \(error.localizedDescription) Nothing was changed.")
        }
        return (true, "Took \(shown) off the lot. lot.md shows it gone once the server has looked again, within a second.")
    }

    /// The lot: `ALIFE_LOT_DIR`, which the server gives every session, or
    /// `~/a-life-lot`, as the server has it.
    static func lotDirectory(in environment: [String: String]) -> URL {
        environment["ALIFE_LOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-lot", isDirectory: true)
    }

    /// Runs the command with what came after its name on the command line,
    /// and returns the status to exit with.
    static func main(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1, let path = arguments.first, !path.hasPrefix("-") else {
            FileHandle.standardError.write(Data("Give the one file to take off the lot, such as: \(command) buildings/shed.md\n".utf8))
            return 1
        }
        let (succeeded, said) = run(path, environment: ProcessInfo.processInfo.environment)
        (succeeded ? FileHandle.standardOutput : FileHandle.standardError).write(Data((said + "\n").utf8))
        return succeeded ? 0 : 1
    }
}
