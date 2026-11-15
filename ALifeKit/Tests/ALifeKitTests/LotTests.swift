import XCTest
@testable import ALifeAPI

/// The lot's layout, and what is on it as it goes over the wire.
final class LotTests: XCTestCase {
    func testAreasKnowTheirTilesAndWhatTheyOverlap() {
        let area = LotArea(x: 2, y: 3, width: 3, depth: 2)
        XCTAssertTrue(area.contains(x: 2, y: 3))
        XCTAssertTrue(area.contains(x: 4, y: 4))
        XCTAssertFalse(area.contains(x: 5, y: 4))
        XCTAssertFalse(area.contains(x: 4, y: 5))
        XCTAssertEqual(area.tiles.count, 6)
        XCTAssertEqual(area.tiles.first?.x, 2)
        XCTAssertEqual(area.tiles.last?.y, 4)

        XCTAssertTrue(area.overlaps(LotArea(x: 4, y: 4)))
        XCTAssertFalse(area.overlaps(LotArea(x: 5, y: 3, width: 2, depth: 2))) // right next to it
        XCTAssertFalse(area.overlaps(LotArea(x: 2, y: 5, width: 3)))
    }

    func testTheHouseAndTheLawnAreReservedInTheMiddleOfTheLot() {
        XCTAssertEqual(LotPlan.width, 64)
        XCTAssertEqual(LotPlan.depth, 64)
        let reserved = LotPlan.reserved
        for area in [LotPlan.house, LotPlan.lawn] {
            XCTAssertTrue(area.tiles.allSatisfy { reserved.contains(x: $0.x, y: $0.y) })
        }
        XCTAssertTrue((LotPlan.doorway + LotPlan.bushes).allSatisfy { reserved.contains(x: $0.x, y: $0.y) })
        // There is a path all the way round.
        XCTAssertEqual(reserved.x, LotPlan.house.x - 1)
        XCTAssertEqual(reserved.xs.upperBound, LotPlan.house.xs.upperBound + 1)
        XCTAssertTrue(LotPlan.reserved.tiles.allSatisfy { LotPlan.bounds.contains(x: $0.x, y: $0.y) })
    }

    func testItemsTravelAsPlainFields() throws {
        let roses = LotItem(
            id: "garden/roses.md", category: .plant, kind: "rose", name: "Roses",
            area: LotArea(x: 40, y: 30, width: 3, depth: 1), color: "#D02030"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Lot(revision: 3, items: [roses]))) as? [String: Any])
        XCTAssertEqual(json["revision"] as? Int, 3)
        let item = try XCTUnwrap((json["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["category"] as? String, "plant")
        XCTAssertEqual(item["kind"] as? String, "rose")
        XCTAssertEqual(item["x"] as? Int, 40)
        XCTAssertEqual(item["width"] as? Int, 3)
        XCTAssertEqual(item["color"] as? String, "#D02030")

        let decoded = try JSONDecoder().decode(Lot.self, from: JSONEncoder().encode(Lot(revision: 3, items: [roses])))
        XCTAssertEqual(decoded.items, [roses])
        XCTAssertEqual(decoded.items.first?.area, LotArea(x: 40, y: 30, width: 3, depth: 1))
    }

    func testACategoryFromALaterVersionIsUnknown() throws {
        let json = #"{"id":"ponds/duck.md","category":"pond","kind":"duck pond","name":"Duck pond","x":1,"y":2,"width":3,"depth":3}"#
        let item = try JSONDecoder().decode(LotItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.category, .unknown)
        XCTAssertNil(item.color)
    }
}
