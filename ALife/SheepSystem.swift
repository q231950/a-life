import Foundation
import RealityKit

/// A helper (subagent) that an agent sent off, shown as a little sheep.
///
/// It pops up beside its agent and wanders off to random places on the lot
/// while the helper works. Once the helper has reported back, it walks back
/// to its agent, stays a moment, then spins and flies straight up into the
/// sky, and is gone once the camera can't see it any more.
struct SheepComponent: Component {
    enum Phase {
        /// Popping up beside its agent.
        case arriving
        /// Off to random places on the lot, with a pause at each.
        case wandering
        /// Its helper has reported back: walking back to its agent.
        case returning
        /// Beside its agent, for a moment.
        case lingering
        /// Spinning, then flying straight up.
        case leaving
    }

    /// The agent that sent the helper.
    weak var agent: Entity?
    /// Set once the helper has reported back to its agent.
    var hasReportedBack = false

    fileprivate(set) var phase = Phase.arriving
    /// How long it has been in its current phase, in seconds.
    fileprivate var elapsed: Float = 0
    /// How much longer to stand still before wandering on, in seconds.
    fileprivate var pause: Float = 0
    /// The tile it last set off for, walking back to its agent.
    fileprivate var goal: Tile?
    /// How fast it is climbing while it leaves, in metres per second.
    fileprivate var climb: Float = 0

    init(agent: Entity) {
        self.agent = agent
    }
}

/// Takes every sheep through its phases (see `SheepComponent`). The walking
/// itself is left to `WalkSystem`.
struct SheepSystem: System {
    private static let query = EntityQuery(where: .has(SheepComponent.self))
    private static let cameras = EntityQuery(where: .has(PerspectiveCameraComponent.self))

    /// How long popping up takes, and how long it stands beside its agent
    /// before it wanders off.
    private static let popDuration: Float = 0.3
    private static let arrivalDuration: Float = 0.8
    /// How close to its agent it comes when it walks back.
    private static let besideDistance: Float = 0.75
    /// How long it stays with its agent before it leaves.
    private static let lingerDuration: Float = 0.8
    /// How long it spins on the spot before it lifts off, and how fast it
    /// spins by then: four turns a second.
    private static let spinUpDuration: Float = 0.6
    private static let topSpin: Float = 4 * 2 * .pi
    /// How quickly it speeds up as it climbs, and its top speed.
    private static let liftOff: Float = 9
    private static let topClimb: Float = 30
    /// Gone at this height whatever the camera sees, just in case.
    private static let ceiling: Float = 200

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        var camera: Entity?
        for found in context.scene.performQuery(Self.cameras) {
            camera = found
            break
        }
        var flownOff: [Entity] = []

        for sheep in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var state = sheep.components[SheepComponent.self],
                  let lot = sheep.parent?.components[LotComponent.self] else { continue }

            state.elapsed += deltaTime
            let phase = state.phase
            switch phase {
            case .arriving:
                arrive(sheep, &state)
            case .wandering:
                wander(sheep, &state, on: lot, deltaTime: deltaTime)
            case .returning:
                goBack(sheep, &state, on: lot)
            case .lingering:
                linger(sheep, &state)
            case .leaving:
                if leave(sheep, &state, deltaTime: deltaTime, seenBy: camera) {
                    flownOff.append(sheep)
                }
            }
            if state.phase != phase {
                state.elapsed = 0
            }
            sheep.components[SheepComponent.self] = state
        }

        // Not while going through the query's results.
        for sheep in flownOff {
            sheep.removeFromParent()
        }
    }

    // MARK: Phases

    /// Pops up, then stands beside its agent for a moment.
    private func arrive(_ sheep: Entity, _ state: inout SheepComponent) {
        let progress = min(state.elapsed / Self.popDuration, 1)
        sheep.scale = SIMD3(repeating: max(Self.pop(progress), 0.01))
        guard state.elapsed >= Self.arrivalDuration else { return }
        sheep.scale = SIMD3(repeating: 1)
        state.phase = state.hasReportedBack ? .returning : .wandering
    }

    /// Walks to a random place on the lot, stands there a little, and goes on
    /// to the next, until its helper has reported back.
    private func wander(_ sheep: Entity, _ state: inout SheepComponent, on lot: LotComponent, deltaTime: Float) {
        if state.hasReportedBack {
            state.phase = .returning
            return
        }
        guard sheep.components[WalkComponent.self]?.waypoints.isEmpty == true else { return }
        state.pause -= deltaTime
        guard state.pause <= 0 else { return }

        // Somewhere a few tiles away, so the walk is worth watching.
        let here = lot.tile(at: sheep.position)
        let places = lot.grid.allTiles.filter {
            lot.grid.isWalkable($0) && max(abs($0.x - here.x), abs($0.z - here.z)) >= 3
        }
        if let place = places.randomElement(), let route = lot.route(from: sheep.position, to: place) {
            sheep.components[WalkComponent.self]?.waypoints = route
        }
        state.pause = .random(in: 0.5...1.5)
    }

    /// Heads for its agent, wherever the agent is off to, and stops beside it.
    private func goBack(_ sheep: Entity, _ state: inout SheepComponent, on lot: LotComponent) {
        guard var walk = sheep.components[WalkComponent.self] else { return }
        guard let agent = state.agent, agent.parent != nil else {
            state.phase = .leaving // its agent has left the lot
            return
        }
        let target = agent.position(relativeTo: sheep.parent)
        if Self.horizontalDistance(from: sheep.position, to: target) <= Self.besideDistance {
            walk.waypoints = []
            sheep.components[WalkComponent.self] = walk
            state.phase = .lingering
            return
        }

        // A new route only when the agent has moved on to another tile.
        let goal = lot.tile(at: target)
        guard goal != state.goal || walk.waypoints.isEmpty else { return }
        state.goal = goal
        if lot.tile(at: sheep.position) == goal {
            walk.waypoints = [target]
        } else if let next = walk.waypoints.first, let onward = lot.route(from: next, to: goal) {
            // Finishes the step it is on first, so it doesn't turn back.
            walk.waypoints = [next] + onward
        } else if let route = lot.route(from: sheep.position, to: goal) {
            walk.waypoints = route
        } else {
            walk.waypoints = []
            state.phase = .leaving // there's no way back
        }
        sheep.components[WalkComponent.self] = walk
    }

    /// Stays beside its agent for a moment, facing it.
    private func linger(_ sheep: Entity, _ state: inout SheepComponent) {
        if let agent = state.agent, agent.parent != nil {
            let target = agent.position(relativeTo: sheep.parent)
            if Self.horizontalDistance(from: sheep.position, to: target) > 0.01 {
                let toAgent = target - sheep.position
                sheep.orientation = simd_quatf(angle: atan2(toAgent.x, toAgent.z), axis: [0, 1, 0])
            }
        }
        if state.elapsed >= Self.lingerDuration {
            state.phase = .leaving
        }
    }

    /// Spins up on the spot, then lifts off and climbs faster and faster,
    /// still spinning. Returns `true` once it is out of sight.
    private func leave(_ sheep: Entity, _ state: inout SheepComponent, deltaTime: Float, seenBy camera: Entity?) -> Bool {
        if sheep.components.has(WalkComponent.self) {
            sheep.components.remove(WalkComponent.self) // done walking
        }
        let spin = Self.topSpin * min(state.elapsed / Self.spinUpDuration, 1)
        sheep.orientation = simd_quatf(angle: spin * deltaTime, axis: [0, 1, 0]) * sheep.orientation
        guard state.elapsed > Self.spinUpDuration else { return false }

        state.climb = min(state.climb + Self.liftOff * deltaTime, Self.topClimb)
        sheep.position.y += state.climb * deltaTime
        if sheep.position.y > Self.ceiling { return true }
        guard let camera else { return false }
        return Self.isAboveView(of: camera, sheep.position(relativeTo: nil))
    }

    // MARK: Helpers

    /// Whether `point`, in world space, is above the top edge of what
    /// `camera` shows, or behind the camera. The sides of the view depend on
    /// the window's shape, but going straight up always leaves through the
    /// top, or past the camera.
    private static func isAboveView(of camera: Entity, _ point: SIMD3<Float>) -> Bool {
        let seen = camera.convert(position: point, from: nil)
        let depth = -seen.z // a camera looks down its -z
        guard depth > 0.1 else { return true }
        let fieldOfView = camera.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 60
        // A little past the edge, so nothing of it can still show.
        return seen.y / depth > tan(fieldOfView * .pi / 360) * 1.1
    }

    private static func horizontalDistance(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(b.x - a.x, b.z - a.z))
    }

    /// Grows from nothing to a little over full size, and settles back.
    private static func pop(_ progress: Float) -> Float {
        let overshoot: Float = 1.7
        let t = progress - 1
        return 1 + (overshoot + 1) * t * t * t + overshoot * t * t
    }
}
