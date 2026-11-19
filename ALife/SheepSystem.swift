import Foundation
import RealityKit

/// A helper (subagent) that an agent sent off, shown as a little sheep.
///
/// It pops up beside its agent's desk, in the agent's room in the office,
/// and stays there with it while the helper works, turning to look at its
/// agent and hopping now and then. Once the helper has reported back, it
/// swells up like a balloon and pops, with a bang, into a puff of scraps
/// (see `Burst`).
struct SheepComponent: Component {
    enum Phase {
        /// Popping up beside its agent.
        case arriving
        /// In the room with its agent while its helper works.
        case staying
        /// Swelling up, until it pops.
        case bursting
    }

    /// The agent that sent the helper.
    weak var agent: Entity?
    /// Its spot in its agent's room, in its parent's space, and which of
    /// the spots round the desk it is (see `OfficePlan.sheepSpot`).
    let spot: SIMD3<Float>
    let place: Int
    /// Its agent's shirt colour, which its scarf is, and so are some of the
    /// scraps it bursts into.
    let scarf: PlatformColor
    /// Set once the helper has reported back to its agent.
    var hasReportedBack = false

    fileprivate(set) var phase = Phase.arriving
    /// How long it has been in its current phase, in seconds.
    fileprivate var elapsed: Float = 0
    /// How long until its next hop, in seconds.
    fileprivate var nextHop: Float = .random(in: 1...3)

    init(agent: Entity, spot: SIMD3<Float>, place: Int, scarf: PlatformColor) {
        self.agent = agent
        self.spot = spot
        self.place = place
        self.scarf = scarf
    }
}

/// Takes every sheep through its phases (see `SheepComponent`).
struct SheepSystem: System {
    private static let query = EntityQuery(where: .has(SheepComponent.self))

    /// How long popping up takes, and how long it stands still before it
    /// starts hopping.
    private static let popDuration: Float = 0.3
    private static let arrivalDuration: Float = 0.8
    /// How long and how high a hop is.
    private static let hopDuration: Float = 0.35
    private static let hopHeight: Float = 0.1
    /// How long it swells before it pops, and how big it gets.
    private static let swellDuration: Float = 0.45
    private static let swelling: Float = 0.8
    /// Its wool, for the scraps.
    private static let wool = PlatformColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1)

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        var popped: [Entity] = []

        for sheep in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var state = sheep.components[SheepComponent.self] else { continue }

            state.elapsed += deltaTime
            let phase = state.phase
            switch phase {
            case .arriving:
                arrive(sheep, &state)
            case .staying:
                stay(sheep, &state, deltaTime: deltaTime)
            case .bursting:
                if swell(sheep, &state) {
                    popped.append(sheep)
                }
            }
            if state.phase != phase {
                state.elapsed = 0
            }
            sheep.components[SheepComponent.self] = state
        }

        // Not while going through the query's results.
        for sheep in popped {
            if let parent = sheep.parent, let state = sheep.components[SheepComponent.self] {
                Burst.pop(at: sheep.position + [0, 0.27, 0], colors: [Self.wool, Self.wool, state.scarf], in: parent)
            }
            sheep.removeFromParent()
        }
    }

    // MARK: Phases

    /// Pops up, then stands beside its agent for a moment.
    private func arrive(_ sheep: Entity, _ state: inout SheepComponent) {
        let progress = min(state.elapsed / Self.popDuration, 1)
        sheep.scale = SIMD3(repeating: max(Self.pop(progress), 0.01))
        guard state.elapsed >= Self.arrivalDuration || state.hasReportedBack else { return }
        sheep.scale = SIMD3(repeating: 1)
        state.phase = state.hasReportedBack ? .bursting : .staying
    }

    /// Stays on its spot in the room, looking at its agent, and hops now
    /// and then, until its helper has reported back.
    private func stay(_ sheep: Entity, _ state: inout SheepComponent, deltaTime: Float) {
        if state.hasReportedBack || state.agent?.parent == nil {
            sheep.position = state.spot
            state.phase = .bursting
            return
        }
        face(sheep, agent: state.agent)

        state.nextHop -= deltaTime
        var lift: Float = 0
        if state.nextHop < 0 {
            let progress = -state.nextHop / Self.hopDuration
            if progress >= 1 {
                state.nextHop = .random(in: 1.5...4)
            } else {
                lift = sin(progress * .pi) * Self.hopHeight
            }
        }
        sheep.position = state.spot + [0, lift, 0]
    }

    /// Swells up, wobbling, faster and faster, like a balloon blown up too
    /// far. Returns `true` once it is time for it to pop.
    private func swell(_ sheep: Entity, _ state: inout SheepComponent) -> Bool {
        let progress = min(state.elapsed / Self.swellDuration, 1)
        let size = 1 + Self.swelling * progress * progress
        let wobble = sin(state.elapsed * 45) * 0.06 * progress
        sheep.scale = [size * (1 + wobble), size * (1 - wobble), size * (1 + wobble)]
        return progress >= 1
    }

    // MARK: Helpers

    /// Turns `sheep` to look at its agent, if the agent is near, as it is
    /// at its desk, or else out of the window.
    private func face(_ sheep: Entity, agent: Entity?) {
        var direction = SIMD3<Float>(0, 0, 1)
        if let agent {
            let toAgent = agent.position(relativeTo: sheep.parent) - sheep.position
            let distance = simd_length(SIMD2(toAgent.x, toAgent.z))
            if distance > 0.01, distance < 2, abs(toAgent.y) < 0.5 {
                direction = toAgent
            }
        }
        sheep.orientation = simd_quatf(angle: atan2(direction.x, direction.z), axis: [0, 1, 0])
    }

    /// Grows from nothing to a little over full size, and settles back.
    private static func pop(_ progress: Float) -> Float {
        let overshoot: Float = 1.7
        let t = progress - 1
        return 1 + (overshoot + 1) * t * t * t + overshoot * t * t
    }
}
