@testable import ALifeServer
import Foundation

/// The cast the server ships with, read from its agents file.
let shippedCast: [Character] = {
    do {
        return try Cast.load(contentsOf: Cast.shippedFile)
    } catch {
        fatalError("The shipped agents file doesn't load: \(error)")
    }
}()

extension Character {
    static var gardener: Character { shipped("gardener") }
    static var builder: Character { shipped("builder") }
    static var engineer: Character { shipped("engineer") }
    static var flamingoEngineer: Character { shipped("flamingo-engineer") }
    static var teamLead: Character { shipped("team-lead") }

    private static func shipped(_ id: String) -> Character {
        guard let character = shippedCast.first(where: { $0.id == id }) else {
            fatalError("The shipped agents file has no \(id)")
        }
        return character
    }
}
