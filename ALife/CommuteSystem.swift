import ALifeClient
import Foundation
import RealityKit

/// An agent's way to work and back. While it works, it walks into the
/// office, takes the lift at the back of the lobby, and after a moment out
/// of sight appears at the desk in its own room, by the window, where it
/// stays while it works. Once it's done, it takes the lift down again, and
/// walks out of the door to its spot on the lawn. `Commute` decides when.
struct CommuteComponent: Component {
    /// Working, or waiting for you in the middle of its work. The world
    /// sets this; the system takes the agent where it belongs.
    var isAtWork = false
    /// Its spot on the lawn, and the tile where it steps into the lift.
    let lawn: Tile
    let lift: Tile
    /// Where it sits in its room, in its parent's space.
    let desk: SIMD3<Float>

    fileprivate var commute = Commute()
    /// How long until it next looks for a way, if it found none, in seconds.
    fileprivate var retry: Float = 0
    /// How long since it appeared after a ride in the lift, in seconds, or
    /// `nil` once it's at full size.
    fileprivate var appeared: Float?

    init(lawn: Tile, lift: Tile, desk: SIMD3<Float>) {
        self.lawn = lawn
        self.lift = lift
        self.desk = desk
    }
}

/// Takes every agent with a `CommuteComponent` to work and back (see there).
/// The walking itself is left to `WalkSystem`.
struct CommuteSystem: System {
    private static let query = EntityQuery(where: .has(CommuteComponent.self))

    /// How long it takes to grow back to full size when it steps out.
    private static let appearDuration: Float = 0.25
    /// Hidden, but still there for the systems: a disabled entity isn't.
    private static let hidden: Float = 0.0001

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        for agent in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var state = agent.components[CommuteComponent.self],
                  let lot = agent.parent?.components[LotComponent.self] else { continue }

            state.retry -= deltaTime
            let isAtLift = state.commute.isHeadingIn && isStanding(agent, on: state.lift, on: lot)
            switch state.commute.advance(by: deltaTime, isAtWork: state.isAtWork, isAtLift: isAtLift) {
            case .enterLift?, .leaveDesk?:
                agent.scale = SIMD3(repeating: Self.hidden)
                agent.components[WalkComponent.self]?.waypoints = []
                state.appeared = nil
            case .appearAtDesk?:
                agent.position = state.desk
                agent.orientation = simd_quatf(angle: 0, axis: [0, 1, 0]) // facing the window
                state.appeared = 0
            case .appearAtLift?:
                agent.position = lot.position(of: state.lift)
                agent.orientation = simd_quatf(angle: 0, axis: [0, 1, 0]) // facing the door
                state.appeared = 0
                state.retry = 0
            case nil:
                break
            }

            switch state.commute.phase {
            case .outside:
                head(agent, to: state.lawn, &state, on: lot)
            case .goingIn:
                head(agent, to: state.lift, &state, on: lot)
            case .goingUp, .atDesk, .goingDown:
                break
            }

            if let appeared = state.appeared {
                // Steps out of the lift, popping back to full size.
                let progress = min((appeared + deltaTime) / Self.appearDuration, 1)
                agent.scale = SIMD3(repeating: max(Self.hidden, progress))
                state.appeared = progress < 1 ? appeared + deltaTime : nil
            }
            agent.components[CommuteComponent.self] = state
        }
    }

    /// Whether `agent` stands still in the middle of `tile`.
    private func isStanding(_ agent: Entity, on tile: Tile, on lot: LotComponent) -> Bool {
        agent.components[WalkComponent.self]?.waypoints.isEmpty == true
            && simd_distance(agent.position, lot.position(of: tile)) < 0.05
    }

    /// Sends `agent` to `goal`, unless it is there or on its way there
    /// already.
    private func head(_ agent: Entity, to goal: Tile, _ state: inout CommuteComponent, on lot: LotComponent) {
        guard let walk = agent.components[WalkComponent.self] else { return }
        if let last = walk.waypoints.last {
            if lot.tile(at: last) == goal { return } // on its way
        } else if isStanding(agent, on: goal, on: lot) {
            return
        }
        // A new way there, though not every frame if there is none.
        guard state.retry <= 0 else { return }
        if let route = lot.route(from: agent.position, to: goal) {
            agent.components[WalkComponent.self]?.waypoints = route
        } else {
            state.retry = 1
        }
    }
}
