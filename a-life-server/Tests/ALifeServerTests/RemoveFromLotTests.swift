import ALifeAPI
@testable import ALifeServer
import XCTest

/// The `remove-from-lot` command, which the construction worker and the
/// keeper take buildings and beds off the lot with: only from their own
/// character's folder, and nothing but a Markdown file directly in it.
final class RemoveFromLotTests: XCTestCase {
    private var lot: URL!

    override func setUp() async throws {
        lot = FileManager.default.temporaryDirectory.appendingPathComponent("a-life-lot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: lot)
    }

    private let restaurant = "---\nkind: restaurant\nx: 38\ny: 22\nwidth: 5\ndepth: 4\n---\n# Luigi's\n"
    private let roses = "---\nkind: rose\ncolor: red\nx: 20\ny: 30\nwidth: 3\n---\n# Rose bed\n"

    /// Writes `text` to `path` in the lot.
    private func write(_ text: String, to path: String) throws {
        let file = lot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func survey() -> (items: [LotItem], problems: [String]) {
        LotSurvey.survey(LotSurvey.entries(in: lot))
    }

    /// The environment the server gives the session of the character `id`.
    private func session(of id: String?) -> [String: String] {
        var environment = ["ALIFE_LOT_DIR": lot.path]
        environment["ALIFE_CHARACTER"] = id
        return environment
    }

    func testTheBuilderAndTheConservationistTakeThingsOffTheLot() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write("", to: "buildings/barn.md") // emptied, as it used to be
        try write(roses, to: "garden/roses.md")
        XCTAssertEqual(survey().items.map(\.id), ["buildings/restaurant.md", "garden/roses.md"])

        let pulledDown = RemoveFromLot.run("buildings/restaurant.md", environment: session(of: "builder"))
        XCTAssertEqual(pulledDown.succeeded, true, pulledDown.said)
        XCTAssertEqual(pulledDown.said, "Took buildings/restaurant.md off the lot. lot.md shows it gone once the server has looked again, within a second.")
        // A file's name alone is in the character's own folder.
        XCTAssertTrue(RemoveFromLot.run("barn.md", environment: session(of: "builder")).succeeded)
        XCTAssertTrue(RemoveFromLot.run("garden/roses.md", environment: session(of: "conservationist")).succeeded)

        for path in ["buildings/restaurant.md", "buildings/barn.md", "garden/roses.md"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: lot.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(survey().items, [])
    }

    func testOnlyTheBuilderAndTheConservationistTakeThingsAwayAndOnlyFromTheirOwnFolder() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write(roses, to: "garden/roses.md")

        let refusals: [(path: String, character: String?, said: String)] = [
            ("buildings/restaurant.md", "conservationist", "buildings/restaurant.md isn't yours to take away: you only take beds out of garden/. Nothing was changed."),
            ("garden/roses.md", "builder", "garden/roses.md isn't yours to take away: you only take buildings out of buildings/. Nothing was changed."),
            ("buildings/restaurant.md", "team-lead", "Only the Builder's construction worker and the Conservationist's keeper can take things off the lot with remove-from-lot. Nothing was changed."),
            ("buildings/restaurant.md", nil, "Only the Builder's construction worker and the Conservationist's keeper can take things off the lot with remove-from-lot. Nothing was changed."),
            // The keeper's own folder, by its name alone, isn't the Builder's.
            ("restaurant.md", "conservationist", "There's no garden/restaurant.md on the lot. Read lot.md to see what is there. Nothing was changed."),
        ]
        for refusal in refusals {
            let result = RemoveFromLot.run(refusal.path, environment: session(of: refusal.character))
            XCTAssertFalse(result.succeeded, refusal.path)
            XCTAssertEqual(result.said, refusal.said)
        }
        XCTAssertEqual(survey().items.map(\.id), ["buildings/restaurant.md", "garden/roses.md"])
    }

    func testItRefusesAnythingButAMarkdownFileInTheFolder() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write("Notes on the lot", to: "notes.md")
        try write("Plans", to: "buildings/plans.txt")
        try write("A wing", to: "buildings/wings/east.md")
        try write(".", to: "buildings/.hidden.md")
        // A file outside the lot, and a link to it from inside.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).md")
        try "Not the lot's".write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: lot.appendingPathComponent("buildings/link.md"), withDestinationURL: outside)

        let builder = session(of: "builder")
        let refusals: [(path: String, said: String)] = [
            ("lot.md", "There's no buildings/lot.md on the lot. Read lot.md to see what is there. Nothing was changed."),
            ("../notes.md", "../notes.md isn't a file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/../notes.md", "buildings/../notes.md isn't a file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("/etc/passwd", "/etc/passwd isn't a file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            (outside.path, "\(outside.path) isn't a file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/wings/east.md", "buildings/wings/east.md isn't a file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/plans.txt", "buildings/plans.txt isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/wings", "buildings/wings isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/.hidden.md", "buildings/.hidden.md isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/..", "buildings/.. isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/", "buildings/ isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/.md", "buildings/.md isn't a Markdown file in buildings/. Give one such as buildings/shed.md. Nothing was changed."),
            ("buildings/link.md", "buildings/link.md isn't a plain file, so it can't be taken away with remove-from-lot. Nothing was changed."),
            ("buildings/school.md", "There's no buildings/school.md on the lot. Read lot.md to see what is there. Nothing was changed."),
        ]
        for refusal in refusals {
            let result = RemoveFromLot.run(refusal.path, environment: builder)
            XCTAssertFalse(result.succeeded, refusal.path)
            XCTAssertEqual(result.said, refusal.said)
        }
        for path in ["buildings/restaurant.md", "notes.md", "buildings/plans.txt", "buildings/wings/east.md", "buildings/.hidden.md", "buildings/link.md"] {
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: lot.appendingPathComponent(path).path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        // A folder that is a link, which could lead anywhere, is refused too.
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("garden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: elsewhere) }
        try roses.write(to: elsewhere.appendingPathComponent("roses.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: lot.appendingPathComponent("garden"), withDestinationURL: elsewhere)
        let linked = RemoveFromLot.run("garden/roses.md", environment: session(of: "conservationist"))
        XCTAssertFalse(linked.succeeded)
        XCTAssertEqual(linked.said, "There's no garden/ on the lot, or it is a link rather than a folder. Nothing was changed.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("roses.md").path))
    }

    func testTheHelpersAreToldToTakeThingsAwayWithTheCommandAndNothingElse() {
        for (character, path) in [(Character.builder, "buildings/shed.md"), (Character.conservationist, "garden/rose-bed.md")] {
            let helper = character.helper
            XCTAssertTrue(helper.tools.contains("Bash"), character.name)
            XCTAssertTrue(helper.prompt.contains("\"$ALIFE_SERVER_COMMAND\" remove-from-lot \(path)"), character.name)
            XCTAssertTrue(helper.prompt.contains("Never empty a file instead"), character.name)
            XCTAssertTrue(helper.prompt.contains("This is the only thing you use Bash for: never run any other command."), character.name)
            XCTAssertFalse(helper.prompt.contains("empty it"), character.name)
        }
    }
}
