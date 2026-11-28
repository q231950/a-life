import ALifeAPI

/// Something a character can make for the lot, which its conversation offers
/// with a picture of it: a building for the Builder, or a bed of plants or
/// animals for the Conservationist. Picking one starts a request for it in
/// the message field, such as "Build a barn", to finish or send.
///
/// They are the kinds a front end draws its own way (`LotItem.Building`,
/// `LotItem.Plant` and `LotItem.Animal`), so a new kind is offered as soon
/// as it is drawn.
public struct LotSuggestion: Identifiable, Equatable, Sendable {
    /// What it is.
    public enum Thing: Equatable, Sendable {
        case building(LotItem.Building)
        case plant(LotItem.Plant)
        case animal(LotItem.Animal)
    }

    public let thing: Thing

    public init(_ thing: Thing) {
        self.thing = thing
    }

    /// The Builder's id, whose conversation offers the buildings.
    public static let builderID = "builder"
    /// The Conservationist's id, whose conversation offers the plants and the animals.
    public static let conservationistID = "conservationist"

    /// What the character with `characterID` can make: the buildings for
    /// the Builder, the plants and then the animals for the
    /// Conservationist, and nothing for anyone else.
    public static func offered(by characterID: String) -> [LotSuggestion] {
        switch characterID {
        case builderID:
            return LotItem.Building.allCases.map { LotSuggestion(.building($0)) }
        case conservationistID:
            return LotItem.Plant.allCases.map { LotSuggestion(.plant($0)) }
                + LotItem.Animal.allCases.map { LotSuggestion(.animal($0)) }
        default:
            return []
        }
    }

    public var id: String {
        switch thing {
        case .building(let building): "building/\(building.rawValue)"
        case .plant(let plant): "plant/\(plant.rawValue)"
        case .animal(let animal): "animal/\(animal.kind)"
        }
    }

    /// What it is called under its picture, such as `Block of flats` or
    /// `Polar bear`.
    public var title: String {
        let name: String
        switch thing {
        case .building(let building): name = building.name
        case .plant(let plant): name = plant.name
        case .animal(let animal): name = animal.name
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The start of a request for it, such as `Build an office`,
    /// `Plant some roses` or `Put out some unicorns`.
    public var request: String {
        switch thing {
        case .building(let building):
            let article = building.name.first.map { "aeiou".contains($0) } == true ? "an" : "a"
            return "Build \(article) \(building.name)"
        case .plant(let plant):
            return "Plant some \(plant.plural)"
        case .animal(let animal):
            return "Put out some \(animal.plural)"
        }
    }
}
