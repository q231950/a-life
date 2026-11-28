@testable import ALifeServer
import Foundation

/// The agents the server has built in: the Builder, the a*life Engineer, the
/// Team Lead and the Conservationist.
let shippedCast: [Character] = Cast.builtIn

extension Character {
    static var builder: Character { shipped("builder") }
    static var engineer: Character { shipped("engineer") }
    static var teamLead: Character { shipped("team-lead") }
    static var conservationist: Character { shipped("conservationist") }

    private static func shipped(_ id: String) -> Character {
        guard let character = shippedCast.first(where: { $0.id == id }) else {
            fatalError("The built-in agents have no \(id)")
        }
        return character
    }
}

extension Character {
    /// A character on the lot who only looks, as the dummies play one: it
    /// sends two helpers off at once and never asks for anything. The
    /// shipped file needn't have one.
    static let birdwatcher: Character = {
        do {
            return try Cast.decode("""
                agents:
                  - id: birdwatcher
                    name: Birdwatcher
                    color: "#D9594D"
                    role: You are the Birdwatcher, a character in a*life, a little life sim. You watch the birds on the lot.
                    helper: {name: spotter, tools: [Read], description: Looks for birds., prompt: You are the Birdwatcher's spotter.}
                """, from: "agents.yaml")[0]
        } catch {
            fatalError("The Birdwatcher doesn't load: \(error)")
        }
    }()
}
