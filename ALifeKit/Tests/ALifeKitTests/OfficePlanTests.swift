import XCTest
@testable import ALifeAPI
@testable import ALifeClient

/// The office the characters work in: a room each, as many storeys as they
/// need, and their helpers' sheep with them in their rooms.
final class OfficePlanTests: XCTestCase {
    func testThereIsAStoreyOfRoomsForEveryTwoCharactersOverTheLobby() {
        XCTAssertEqual(OfficePlan.storeys(forRooms: 0), 2) // a floor of rooms at least
        XCTAssertEqual(OfficePlan.storeys(forRooms: 1), 2)
        XCTAssertEqual(OfficePlan.storeys(forRooms: 2), 2)
        XCTAssertEqual(OfficePlan.storeys(forRooms: 3), 3)
        XCTAssertEqual(OfficePlan.storeys(forRooms: 6), 4)
        XCTAssertEqual(OfficePlan.storeys(forRooms: 7), 5)
        XCTAssertEqual(OfficePlan.height(forRooms: 6), 4 * OfficePlan.storeyHeight)
    }

    func testEachCharacterHasARoomOfItsOwn() {
        let rooms = (0..<9).map(OfficePlan.room(forSlot:))
        XCTAssertEqual(Set(rooms.map { "\($0.storey) \($0.side)" }).count, rooms.count)
        for (slot, room) in rooms.enumerated() {
            XCTAssertEqual(room.slot, slot)
            XCTAssertEqual(room.storey, 1 + slot / 2)
            XCTAssertEqual(room.side, slot % 2)
            XCTAssertEqual(room.floor, Float(room.storey) * OfficePlan.storeyHeight)
            XCTAssertLessThan(room.storey, OfficePlan.storeys(forRooms: slot + 1))
            // On the house's tiles, and the two on a storey side by side.
            XCTAssertTrue(room.area.tiles.allSatisfy { LotPlan.house.contains(x: $0.x, y: $0.y) })
            XCTAssertEqual(room.area.depth, LotPlan.house.depth)
        }
        XCTAssertFalse(rooms[0].area.overlaps(rooms[1].area))
        XCTAssertEqual(rooms[0].area.xs.upperBound, rooms[1].area.x)
        XCTAssertEqual(rooms[0].area, rooms[2].area) // one storey up
    }

    func testACharacterSitsByItsRoomsFrontWindow() {
        let room = OfficePlan.room(forSlot: 3)
        let desk = room.desk
        XCTAssertTrue(room.contains(desk, margin: 0.5))
        XCTAssertEqual(desk.x, (room.minX + room.maxX) / 2)
        XCTAssertEqual(room.maxY, Float(LotPlan.house.ys.upperBound) - 0.5) // the front of the house
        XCTAssertLessThan(room.maxY - desk.y, 1)
    }

    func testEachRoomTakesItsCharactersColour() {
        let shirts = [0: "#D03030", 1: "#E08020", 3: "#8040C0"]
        let rooms = OfficePlan.rooms(tintedBy: shirts)
        XCTAssertEqual(rooms.map(\.room.slot), [0, 1, 2, 3])
        XCTAssertEqual(rooms.map(\.tint), ["#D03030", "#E08020", nil, "#8040C0"])
        XCTAssertEqual(rooms[3].room, OfficePlan.room(forSlot: 3))
        XCTAssertTrue(OfficePlan.rooms(tintedBy: [Int: String]()).isEmpty)
    }

    func testTheLiftIsAtTheBackOfTheLobby() {
        for slot in 0..<4 {
            let lift = OfficePlan.lift(forSlot: slot)
            XCTAssertEqual(lift.y, LotPlan.house.y + 1) // just inside the back wall
            XCTAssertTrue(LotPlan.house.contains(x: lift.x, y: lift.y))
            XCTAssertTrue(LotPlan.doorway.contains { $0.x == lift.x }) // straight in from the door
        }
        XCTAssertNotEqual(OfficePlan.lift(forSlot: 0).x, OfficePlan.lift(forSlot: 1).x)
    }

    func testHelpersSheepStayInTheirCharactersRoomRoundItsDesk() {
        let room = OfficePlan.room(forSlot: 1)
        let desk = room.desk
        let spots = (0..<8).map { OfficePlan.sheepSpot(in: room, place: $0) }
        XCTAssertEqual(spots.count, Set(spots.map { "\($0.x) \($0.y)" }).count) // none share a spot
        for spot in spots {
            XCTAssertTrue(room.contains(spot, margin: 0.25), "\(spot)")
            XCTAssertLessThanOrEqual(spot.y, desk.y) // not at the desk, in front
            XCTAssertGreaterThan(hypot(spot.x - desk.x, spot.y - desk.y), 0.5) // not on the character
        }
        // The first two right beside it, either side.
        XCTAssertEqual(spots[0].y, desk.y)
        XCTAssertEqual(spots[1].y, desk.y)
        XCTAssertEqual(spots[0].x + spots[1].x, 2 * desk.x, accuracy: 0.001)
        // Nearest first.
        let distances = spots.map { hypot($0.x - desk.x, $0.y - desk.y) }
        XCTAssertTrue(zip(distances, distances.dropFirst()).allSatisfy { $0 <= $1 + 0.001 }, "\(distances)")
        // So many that they run out of room start again.
        let all = OfficePlan.sheepSpots(in: room)
        XCTAssertEqual(OfficePlan.sheepSpot(in: room, place: all.count), spots[0])
    }
}
