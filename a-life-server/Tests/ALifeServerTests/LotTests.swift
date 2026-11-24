import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the characters build and plant: the files in the lot's
/// `buildings/` and `garden/` that say where they stand, what the server
/// makes of them, and the front ends following the lot.
@MainActor
final class LotTests: XCTestCase {
    private var lot: URL!

    override func setUp() async throws {
        lot = FileManager.default.temporaryDirectory.appendingPathComponent("a-life-lot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: lot)
    }

    private let restaurant = """
        ---
        kind: Restaurant
        x: 38
        y: 22
        width: 5
        depth: 4
        ---
        # Luigi's

        A little trattoria by the house.
        """

    private let roses = """
        ---
        kind: rose
        color: red
        x: 20
        y: 30
        width: 3
        ---
        # Rose bed
        """

    /// Writes `text` to `path` in the lot, as last changed `secondsAgo`.
    private func write(_ text: String, to path: String, secondsAgo: TimeInterval = 0) throws {
        let file = lot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: file.path)
    }

    private func survey() -> (items: [LotItem], problems: [String]) {
        LotSurvey.survey(LotSurvey.entries(in: lot))
    }

    // MARK: Reading the files

    func testABuildingAndABedStandWhereTheirFilesSay() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write(roses, to: "garden/roses.md")

        let (items, problems) = survey()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(items, [
            LotItem(
                id: "buildings/restaurant.md", category: .building, kind: "restaurant", name: "Luigi's",
                area: LotArea(x: 38, y: 22, width: 5, depth: 4)
            ),
            LotItem(
                id: "garden/roses.md", category: .plant, kind: "rose", name: "Rose bed",
                area: LotArea(x: 20, y: 30, width: 3, depth: 1), color: "#D7263D"
            ),
        ])
    }

    func testWhatAFileCanLeaveOut() throws {
        // A building is 3 by 3 and a plant one tile unless they say, and
        // without a heading the file's name names it.
        try write("---\nkind: shed\nx: 1\ny: 2\n---\nA shed.", to: "buildings/garden-shed.md")
        try write("---\nkind: oak\nx: 10\ny: 10\nname: The old oak\n---\n# Oak", to: "garden/oak.md")
        // A colour it doesn't know is left to the front end; one as #RRGGBB is kept.
        try write("---\nkind: tulip\nx: 12\ny: 10\ncolor: sparkly\n---\n", to: "garden/tulip.md")
        try write("---\nkind: daisy\nx: 14\ny: 10\ncolor: '#ffcc00'\n---\n", to: "garden/daisy.md")

        let items = Dictionary(uniqueKeysWithValues: survey().items.map { ($0.id, $0) })
        XCTAssertEqual(items["buildings/garden-shed.md"]?.name, "Garden shed")
        XCTAssertEqual(items["buildings/garden-shed.md"]?.area, LotArea(x: 1, y: 2, width: 3, depth: 3))
        XCTAssertEqual(items["garden/oak.md"]?.name, "The old oak")
        XCTAssertEqual(items["garden/oak.md"]?.area, LotArea(x: 10, y: 10))
        XCTAssertNil(items["garden/tulip.md"]?.color)
        XCTAssertEqual(items["garden/daisy.md"]?.color, "#FFCC00")
    }

    func testAKindNobodyKnowsStillStandsOnTheLot() throws {
        try write("---\nkind: Lighthouse\nx: 2\ny: 2\n---\n", to: "buildings/lighthouse.md")
        XCTAssertEqual(survey().items.map(\.kind), ["lighthouse"])
    }

    func testWhatKeepsAFileOffTheLot() throws {
        try write("# Office\n\nAt x 1-5, y 1-4.", to: "buildings/office.md")
        try write("---\nx: 2\ny: 2\n---\n", to: "buildings/nothing.md")
        try write("---\nkind: barn\nx: 2-6\ny: 2\n---\n", to: "buildings/barn.md")
        try write("---\nkind: tower\nx: 62\ny: 10\nwidth: 3\n---\n", to: "buildings/tower.md")
        try write("---\nkind: mall\nx: 2\ny: 40\nwidth: 20\n---\n", to: "buildings/mall.md")
        try write("---\nkind: hedge\nx: 30\ny: 30\nwidth: 2\n---\n", to: "garden/hedge.md")
        try write("---\nkind: daisy\ny: 4\n---\n", to: "garden/daisy.md")
        try write("Notes on the lot", to: "notes.md") // not in buildings/ or garden/

        let (items, problems) = survey()
        XCTAssertEqual(items, [])
        XCTAssertEqual(problems, [
            "buildings/barn.md: x should be a whole number, the column of its left edge, not 2-6.",
            "buildings/mall.md: its width and depth can each be 1 to 16, not 20 by 3.",
            "buildings/nothing.md: it needs a kind, such as restaurant or house.",
            "buildings/office.md: it isn't on the lot: it doesn't start with the lines that say its kind and where it stands. See lot.md.",
            "buildings/tower.md: at x 62 to 64, y 10 to 12 it runs off the lot, where x and y each go from 0 to 63.",
            "garden/daisy.md: it needs x, the column of its left edge.",
            "garden/hedge.md: at x 30 to 31, y 30 it is on the house or the lawn in front of it, x 28 to 35, y 25 to 36, where nothing can go.",
        ])
    }

    func testTheConservationistCanPutOutFoals() throws {
        // A foal on each tile, in a horse's colour.
        try write("---\nkind: foal\ncolour: chestnut\nx: 10\ny: 40\nwidth: 3\ndepth: 2\n---\n# Foals", to: "garden/foals.md")
        try write("---\nkind: Shetland pony\nx: 20\ny: 40\ncolor: grey\n---\n", to: "garden/pony.md")
        // Too many foals for one bed.
        try write("---\nkind: baby horses\nx: 2\ny: 50\nwidth: 4\ndepth: 2\n---\n", to: "garden/herd.md")
        // A building called a pony stable isn't foals, whatever its size.
        try write("---\nkind: pony stable\nx: 40\ny: 50\nwidth: 4\ndepth: 3\n---\n", to: "buildings/stable.md")

        let (items, problems) = survey()
        XCTAssertEqual(items, [
            LotItem(id: "buildings/stable.md", category: .building, kind: "pony stable", name: "Stable", area: LotArea(x: 40, y: 50, width: 4, depth: 3)),
            LotItem(id: "garden/foals.md", category: .plant, kind: "foal", name: "Foals", area: LotArea(x: 10, y: 40, width: 3, depth: 2), color: "#8C4A23"),
            LotItem(id: "garden/pony.md", category: .plant, kind: "shetland pony", name: "Pony", area: LotArea(x: 20, y: 40), color: "#BDBAB4"),
        ])
        XCTAssertEqual(items.map(\.isFoals), [false, true, true])
        XCTAssertEqual(problems, ["garden/herd.md: a bed of foals has a foal on each tile, and can have at most 6 of them, not 8 (4 by 2)."])
    }

    func testTheConservationistCanPutOutBearsPolarBearsBirdsUnicornsAndPegasuses() throws {
        try write("---\nkind: bear\ncolor: cinnamon\nx: 2\ny: 2\nwidth: 2\n---\n# Bears", to: "garden/bears.md")
        try write("---\nkind: polar-bear\nx: 2\ny: 6\n---\n", to: "garden/polar-bear.md")
        try write("---\nkind: bird\ncolor: blue\nx: 2\ny: 10\nwidth: 3\ndepth: 2\n---\n", to: "garden/birds.md")
        try write("---\nkind: unicorn\ncolor: silver\nx: 2\ny: 14\n---\n", to: "garden/unicorn.md")
        try write("---\nkind: pegasus\nx: 2\ny: 18\nwidth: 2\n---\n", to: "garden/pegasuses.md")
        // Too many pegasuses for one bed.
        try write("---\nkind: pegasus\nx: 10\ny: 2\nwidth: 7\n---\n", to: "garden/herd.md")

        let (items, problems) = survey()
        XCTAssertEqual(items.map(\.id), ["garden/bears.md", "garden/birds.md", "garden/pegasuses.md", "garden/polar-bear.md", "garden/unicorn.md"])
        XCTAssertEqual(items.map(\.animal), [.bear, .bird, .pegasus, .polarBear, .unicorn])
        XCTAssertEqual(items.map(\.color), ["#9A5B2E", "#3F6FD8", nil, nil, "#C8CCD2"])
        XCTAssertEqual(problems, ["garden/herd.md: a bed of pegasuses has a pegasus on each tile, and can have at most 6 of them, not 7 (7 by 1)."])
    }

    func testTheConservationistCanPutOutDinosaurs() throws {
        try write("---\nkind: stegosaurus\ncolor: olive\nx: 2\ny: 2\nwidth: 2\n---\n# Stegosauruses", to: "garden/stegosauruses.md")
        try write("---\nkind: diplodocus\nx: 2\ny: 6\n---\n", to: "garden/diplodocus.md")
        // As the person spells them.
        try write("---\nkind: pterosaurus\ncolor: rust\nx: 2\ny: 10\nwidth: 3\n---\n", to: "garden/pterosaurs.md")
        try write("---\nkind: triceratops\ncolor: sand\nx: 2\ny: 14\n---\n", to: "garden/triceratops.md")
        try write("---\nkind: tyranosaurus\ncolor: slate\nx: 2\ny: 18\n---\n", to: "garden/t-rex.md")
        // Too many triceratops for one bed.
        try write("---\nkind: triceratops\nx: 10\ny: 2\nwidth: 4\ndepth: 2\n---\n", to: "garden/herd.md")

        let (items, problems) = survey()
        XCTAssertEqual(items.map(\.id), ["garden/diplodocus.md", "garden/pterosaurs.md", "garden/stegosauruses.md", "garden/t-rex.md", "garden/triceratops.md"])
        XCTAssertEqual(items.map(\.animal), [.diplodocus, .pterosaur, .stegosaurus, .tyrannosaurus, .triceratops])
        XCTAssertEqual(items.map(\.color), [nil, "#A0522D", "#6B7A3A", "#6E7B86", "#C9AE7C"])
        XCTAssertEqual(problems, ["garden/herd.md: a bed of triceratops has a triceratops on each tile, and can have at most 6 of them, not 8 (4 by 2)."])
    }

    func testTheKeeperIsToldItCanPutOutAnimals() {
        let keeper = Character.conservationist.helper
        XCTAssertTrue(keeper.prompt.contains("at most \(LotPlan.mostAnimals)"), keeper.prompt)
        for animal in LotItem.Animal.allCases {
            XCTAssertTrue(keeper.prompt.contains("kind: \(animal.kind)"), animal.kind)
            XCTAssertTrue(keeper.description.contains(animal.plural), animal.plural)
            XCTAssertTrue(Character.conservationist.role.contains(animal.plural), animal.plural)
        }
    }

    func testAnEmptyFileIsSomethingTakenAway() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write("\n", to: "buildings/restaurant.md")
        XCTAssertEqual(survey().items, [])
        XCTAssertEqual(survey().problems, [])
    }

    func testTheHelpersAreToldWhereTheHouseIs() {
        let house = LotSurvey.describe(LotPlan.reserved)
        XCTAssertEqual(house, "x 28 to 35, y 25 to 36")
        for character in [Character.builder, Character.conservationist] {
            XCTAssertTrue(character.helper.prompt.contains("takes up \(house), and nothing can go there"), character.name)
            XCTAssertTrue(character.helper.prompt.contains("64 by 64 tiles"), character.name)
            XCTAssertTrue(character.helper.prompt.contains("lot.md"), character.name)
        }
    }

    func testWhatWasThereFirstStays() throws {
        try write(restaurant, to: "buildings/restaurant.md", secondsAgo: 60)
        // An apple tree planted later, in the middle of the restaurant.
        try write("---\nkind: apple tree\nx: 40\ny: 23\n---\n", to: "garden/apple.md", secondsAgo: 10)
        // Right next to it is fine.
        try write("---\nkind: hedge\nx: 38\ny: 26\nwidth: 5\n---\n", to: "garden/hedge.md", secondsAgo: 5)

        let (items, problems) = survey()
        XCTAssertEqual(items.map(\.id), ["buildings/restaurant.md", "garden/hedge.md"])
        XCTAssertEqual(problems, ["garden/apple.md: it overlaps buildings/restaurant.md, which is at x 38 to 42, y 22 to 25."])
    }

    func testTheReportListsWhatIsWhereWithAMap() throws {
        try write(restaurant, to: "buildings/restaurant.md")
        try write(roses, to: "garden/roses.md")
        try write("# Office", to: "buildings/office.md")
        let (items, problems) = survey()
        let report = LotSurvey.report(Lot(revision: 1, items: items, problems: problems))

        XCTAssertTrue(report.contains("- A: Luigi's, a restaurant, at x 38 to 42, y 22 to 25, from buildings/restaurant.md\n"), report)
        XCTAssertTrue(report.contains("- B: Rose bed, a rose, #D7263D, at x 20 to 22, y 30, from garden/roses.md\n"), report)
        XCTAssertTrue(report.contains("## Not on the lot\n\n- buildings/office.md: it isn't on the lot"), report)
        // It says which animals a*life draws, for the Conservationist's keeper.
        XCTAssertTrue(report.contains("## Animals\n\na*life draws these animals in garden/, each in a bed of its own kind with one on each tile, at most 6 to a bed"), report)
        for kind in ["foal", "bear", "polar-bear", "bird", "unicorn", "pegasus", "stegosaurus", "diplodocus", "pterosaur", "triceratops", "tyrannosaurus"] {
            XCTAssertTrue(report.contains("\n- kind: \(kind). "), kind)
        }

        let map = report.components(separatedBy: "```\n").last { $0.contains("#") }!.split(separator: "\n")
        XCTAssertEqual(map.count, 2 + 64) // two lines of column numbers, then a line per row
        XCTAssertTrue(map.dropFirst(2).allSatisfy { $0.count == 3 + 64 })
        func tile(_ x: Int, _ y: Int) -> Swift.Character { Array(map[2 + y])[3 + x] }
        XCTAssertEqual(tile(38, 22), "A")
        XCTAssertEqual(tile(42, 25), "A")
        XCTAssertEqual(tile(43, 25), ".")
        XCTAssertEqual(tile(21, 30), "B")
        XCTAssertEqual(tile(31, 31), "#")
        XCTAssertEqual(map[2], " 0 " + String(repeating: ".", count: 64))
    }

    // MARK: The hub

    func testTheHubTellsItsClientsWhenSomethingChanges() async throws {
        let hub = LotHub(directory: lot)
        await hub.survey()
        let empty = await hub.lot
        XCTAssertEqual(empty, Lot(revision: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lot.appendingPathComponent("lot.md").path))

        var changes = await hub.subscribe().makeAsyncIterator()
        let first = await changes.next()
        XCTAssertEqual(first, empty)

        try write(restaurant, to: "buildings/restaurant.md")
        await hub.survey()
        let built = await changes.next()
        XCTAssertEqual(built?.revision, 2)
        XCTAssertEqual(built?.items.map(\.name), ["Luigi's"])

        // Looking again without a change sends nothing.
        await hub.survey()
        try write(roses, to: "garden/roses.md")
        await hub.survey()
        let planted = await changes.next()
        XCTAssertEqual(planted?.revision, 3)
        XCTAssertEqual(planted?.items.map(\.kind), ["restaurant", "rose"])

        let report = try String(contentsOf: lot.appendingPathComponent("lot.md"), encoding: .utf8)
        XCTAssertTrue(report.contains("Rose bed"), report)
        await hub.stop()
    }

    func testALotWithoutADirectoryStaysEmpty() async {
        let hub = LotHub(directory: nil)
        await hub.survey()
        let empty = await hub.lot
        XCTAssertEqual(empty, Lot())
    }

    // MARK: The server

    func testTheFrontEndsSeeWhatIsBuiltAndPlanted() async throws {
        try write(restaurant, to: "buildings/restaurant.md")

        // Arguments of its own, rather than `.testing`'s, which some test

        // runners leave the test bundle in, for Vapor to take as a command.

        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        do {
            try await configure(app, players: .dummies(step: .milliseconds(20)), lotDirectory: lot, lotSurveyInterval: .milliseconds(20))
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0 // any free port
            try await app.startup()
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

            let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
            let now = try await client.lot()
            XCTAssertEqual(now.items.map(\.name), ["Luigi's"])

            let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
            server.connect()
            for _ in 0..<500 where server.lot.items.count != 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(server.lot.items.map(\.kind), ["restaurant"])

            // The Conservationist's keeper plants an oak, and it shows up.
            try write("---\nkind: oak\nx: 20\ny: 20\n---\n# The old oak", to: "garden/oak.md")
            for _ in 0..<500 where server.lot.items.count != 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(server.lot.items.map(\.name), ["Luigi's", "The old oak"])
            XCTAssertEqual(server.lot.revision, 2)
            server.disconnect()
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
