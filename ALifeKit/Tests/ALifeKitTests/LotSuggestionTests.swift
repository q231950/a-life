import XCTest
@testable import ALifeClient

/// What the Builder's and the Conservationist's conversations offer to make.
final class LotSuggestionTests: XCTestCase {
    func testTheBuilderOffersEveryBuildingDrawnItsOwnWay() {
        let offered = LotSuggestion.offered(by: "builder")
        XCTAssertEqual(offered.map(\.thing), LotItem.Building.allCases.map { .building($0) })
        XCTAssertTrue(offered.contains { $0.thing == .building(.barn) })
    }

    func testTheConservationistOffersEveryPlantAndThenEveryAnimal() {
        let offered = LotSuggestion.offered(by: "conservationist")
        XCTAssertEqual(
            offered.map(\.thing),
            LotItem.Plant.allCases.map { .plant($0) } + LotItem.Animal.allCases.map { .animal($0) }
        )
    }

    func testNoOneElseOffersAnything() {
        for id in ["engineer", "team-lead", "Builder", ""] {
            XCTAssertEqual(LotSuggestion.offered(by: id), [], id)
        }
    }

    func testEachHasATitleAndTheStartOfARequest() {
        let examples: [(LotSuggestion.Thing, String, String)] = [
            (.building(.barn), "Barn", "Build a barn"),
            (.building(.office), "Office", "Build an office"),
            (.building(.tower), "Wind turbine", "Build a wind turbine"),
            (.building(.flats), "Block of flats", "Build a block of flats"),
            (.plant(.rose), "Rose", "Plant some roses"),
            (.plant(.cherry), "Cherry tree", "Plant some cherry trees"),
            (.plant(.grass), "Grass", "Plant some grass"),
            (.plant(.tomato), "Tomato", "Plant some tomatoes"),
            (.animal(.polarBear), "Polar bear", "Put out some polar bears"),
            (.animal(.triceratops), "Triceratops", "Put out some triceratops"),
        ]
        for (thing, title, request) in examples {
            XCTAssertEqual(LotSuggestion(thing).title, title)
            XCTAssertEqual(LotSuggestion(thing).request, request)
        }
    }

    func testEachHasAnIdOfItsOwn() {
        let all = LotSuggestion.offered(by: "builder") + LotSuggestion.offered(by: "conservationist")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(LotSuggestion(.animal(.polarBear)).id, "animal/polar-bear")
    }
}
