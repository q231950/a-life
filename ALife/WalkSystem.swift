import Foundation
import RealityKit

/// Marks a floor entity as a tile so a tap on it can be turned into a destination.
struct TileComponent: Component {
    let tile: Tile
}

/// Waypoints an entity is currently walking along, in its parent's space.
struct WalkComponent: Component {
    var waypoints: [SIMD3<Float>] = []
    var speed: Float = 2.2 // metres per second
}

/// Moves every entity with a `WalkComponent` towards its next waypoint each frame
/// and turns it to face the way it's going.
struct WalkSystem: System {
    private static let query = EntityQuery(where: .has(WalkComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var walk = entity.components[WalkComponent.self],
                  let target = walk.waypoints.first else { continue }

            let toTarget = target - entity.position
            let distance = simd_length(toTarget)
            let step = walk.speed * deltaTime

            if distance > 0.001 {
                // +z is the character's face.
                entity.orientation = simd_quatf(angle: atan2(toTarget.x, toTarget.z), axis: [0, 1, 0])
            }

            if distance <= step {
                entity.position = target
                walk.waypoints.removeFirst()
            } else {
                entity.position += toTarget / distance * step
            }
            entity.components[WalkComponent.self] = walk
        }
    }
}
