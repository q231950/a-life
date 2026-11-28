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

    func testFoalsAreBedsOfFoalsPoniesAndBabyHorsesInTheGarden() {
        func item(_ kind: String, _ category: LotItem.Category = .plant) -> LotItem {
            LotItem(id: "garden/x.md", category: category, kind: kind, name: "X", area: LotArea(x: 1, y: 1))
        }
        for kind in ["foal", "foals", "Shetland pony", "colt", "filly", "baby horses", "baby-horse"] {
            XCTAssertTrue(item(kind).isFoals, kind)
        }
        for kind in ["rose", "horse chestnut", "foaling", "paddock"] {
            XCTAssertFalse(item(kind).isFoals, kind)
        }
        // Foals live in the garden, not in a building.
        XCTAssertFalse(item("foal", .building).isFoals)
        XCTAssertEqual(LotPlan.mostAnimals, 6)
    }

    func testBedsOfAnimalsAreNamedByTheirKind() {
        func animal(_ kind: String, _ category: LotItem.Category = .plant) -> LotItem.Animal? {
            LotItem(id: "garden/x.md", category: category, kind: kind, name: "X", area: LotArea(x: 1, y: 1)).animal
        }
        let kinds: [String: LotItem.Animal] = [
            "foal": .foal, "pony": .foal,
            "bear": .bear, "brown bears": .bear, "grizzly bear": .bear,
            "polar-bear": .polarBear, "polar bears": .polarBear, "Polar Bear": .polarBear,
            "bird": .bird, "birds": .bird, "blue bird": .bird,
            "unicorn": .unicorn, "unicorns": .unicorn,
            "pegasus": .pegasus, "pegasuses": .pegasus, "pegasi": .pegasus,
            "stegosaurus": .stegosaurus, "stegosauruses": .stegosaurus, "Stegosaur": .stegosaurus,
            "diplodocus": .diplodocus, "diplodocuses": .diplodocus,
            "pterosaur": .pterosaur, "pterosaurs": .pterosaur, "pterosaurus": .pterosaur, "pterodactyl": .pterosaur,
            "triceratops": .triceratops, "Triceratopses": .triceratops,
            "tyrannosaurus": .tyrannosaurus, "tyranosaurus": .tyrannosaurus, "tyrannosaurus rex": .tyrannosaurus,
            "t-rex": .tyrannosaurus, "T. rex": .tyrannosaurus, "trex": .tyrannosaurus,
        ]
        for (kind, expected) in kinds {
            XCTAssertEqual(animal(kind), expected, kind)
        }
        // Plants named after animals are still plants.
        for kind in ["rose", "bird cherry", "bird of paradise", "bearberry", "bear's breeches", "oak"] {
            XCTAssertNil(animal(kind), kind)
        }
        XCTAssertNil(animal("bear", .building))

        // The kinds a bed of them has, as the Conservationist writes them.
        XCTAssertEqual(LotItem.Animal.allCases.map(\.kind), [
            "foal", "bear", "polar-bear", "bird", "unicorn", "pegasus",
            "stegosaurus", "diplodocus", "pterosaur", "triceratops", "tyrannosaurus",
        ])
        XCTAssertEqual(LotItem.Animal.allCases.map(\.plural), [
            "foals", "bears", "polar bears", "birds", "unicorns", "pegasuses",
            "stegosauruses", "diplodocuses", "pterosaurs", "triceratops", "tyrannosauruses",
        ])
        XCTAssertEqual(LotItem.Animal.allCases.filter(\.flies), [.bird, .pegasus, .pterosaur])
    }

    func testBuildingsAreDrawnByTheFirstKindWhoseWordsAreInTheirs() {
        let kinds: [String: LotItem.Building] = [
            "restaurant": .restaurant, "Luigi's pizzeria": .restaurant, "pub": .restaurant,
            "coffee shop": .cafe, "tea house": .cafe, "Café": .cafe,
            "workshop": .shed, "garden shed": .shed, "bookshop": .shop, "shops": .shop,
            "tower": .tower, "wind turbine": .tower, "block of flats": .flats, "hotel": .flats,
            "office": .office, "bank": .office, "hospital": .hospital, "chapel": .church,
            "town hall": .school, "school": .school, "stable": .barn, "farm": .barn,
            "windmill": .mill, "house": .house, "farmhouse": .house, "cottage": .house,
        ]
        for (kind, expected) in kinds {
            XCTAssertEqual(LotItem.Building(kind: kind), expected, kind)
        }
        for kind in ["building", "pavilion", "inner courtyard"] {
            XCTAssertNil(LotItem.Building(kind: kind), kind)
        }
        let barn = LotItem(id: "buildings/barn.md", category: .building, kind: "red barn", name: "Barn", area: LotArea(x: 1, y: 1))
        XCTAssertEqual(barn.building, .barn)
        XCTAssertNil(barn.plant)
    }

    func testPlantsAreDrawnByTheFirstKindWhoseWordsAreInTheirs() {
        func item(_ kind: String) -> LotItem {
            LotItem(id: "garden/x.md", category: .plant, kind: kind, name: "X", area: LotArea(x: 1, y: 1))
        }
        let kinds: [String: LotItem.Plant] = [
            "lawn": .grass, "privet": .hedge, "rosemary": .lettuce, "rose": .rose, "roses": .rose,
            "cherry tomatoes": .tomato, "strawberry": .tomato, "spruce": .pine, "pine tree": .pine,
            "apple tree": .apple, "cherry blossom": .cherry, "bird cherry": .cherry, "oak": .oak,
            "weeping willow": .oak, "wildflowers": .flower, "sunflower": .sunflower,
            "blueberry bush": .berry, "bushes": .bush, "daisies": .daisy, "potatoes": .potato,
        ]
        for (kind, expected) in kinds {
            XCTAssertEqual(item(kind).plant, expected, kind)
        }
        XCTAssertNil(item("cactus").plant)
        // A bed of animals isn't a plant, and a building is never one.
        XCTAssertNil(item("unicorn").plant)
        XCTAssertNil(LotItem(id: "buildings/x.md", category: .building, kind: "rose", name: "X", area: LotArea(x: 1, y: 1)).plant)
    }

    func testEachKindIsDrawnAsItselfWhenItIsNamedAsItIsCalled() {
        // So asking for one by its name gets that one on the lot.
        for building in LotItem.Building.allCases {
            XCTAssertEqual(LotItem.Building(kind: building.rawValue), building, building.rawValue)
            XCTAssertEqual(LotItem.Building(kind: building.name), building, building.name)
        }
        for plant in LotItem.Plant.allCases {
            for kind in [plant.rawValue, plant.name, plant.plural] {
                XCTAssertEqual(LotItem.Plant(kind: kind), plant, kind)
                let bed = LotItem(id: "garden/x.md", category: .plant, kind: kind, name: "X", area: LotArea(x: 1, y: 1))
                XCTAssertNil(bed.animal, kind)
            }
        }
        for animal in LotItem.Animal.allCases {
            for kind in [animal.kind, animal.name, animal.plural] {
                let bed = LotItem(id: "garden/x.md", category: .plant, kind: kind, name: "X", area: LotArea(x: 1, y: 1))
                XCTAssertEqual(bed.animal, animal, kind)
            }
        }
    }
}
