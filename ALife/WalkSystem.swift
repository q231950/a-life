import Foundation
import RealityKit

/// Marks a floor entity as a tile so a tap on it can be turned into a destination.
struct TileComponent: Component {
    let tile: Tile
}

/// The lot's floor plan: which tiles there are, which are free, and where
/// each one is. It sits on the lot's root entity, so systems can find their
/// way around the lot, too. Positions are in the root's space.
struct LotComponent: Component {
    var grid: TileGrid
    let tileSize: Float

    /// The centre of `tile`, on the floor.
    func position(of tile: Tile) -> SIMD3<Float> {
        [
            (Float(tile.x) - Float(grid.width - 1) / 2) * tileSize,
            0,
            (Float(tile.z) - Float(grid.depth - 1) / 2) * tileSize,
        ]
    }

    /// The tile `position` is on.
    func tile(at position: SIMD3<Float>) -> Tile {
        Tile(
            x: Int((position.x / tileSize + Float(grid.width - 1) / 2).rounded()),
            z: Int((position.z / tileSize + Float(grid.depth - 1) / 2).rounded())
        )
    }

    /// Waypoints for a `WalkComponent`, from `origin` to the centre of `goal`.
    /// `nil` if there is no way there.
    func route(from origin: SIMD3<Float>, to goal: Tile) -> [SIMD3<Float>]? {
        let start = tile(at: origin)
        guard let path = grid.path(from: start, to: goal) else { return nil }

        var waypoints = path.map { position(of: $0) }
        // When re-routing mid-step, first get back onto the centre of a tile.
        if simd_distance(origin, position(of: start)) > 0.05 {
            waypoints.insert(position(of: start), at: 0)
        }
        return waypoints
    }
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

            // It faces the way it's going across the lot, and keeps its
            // heading going straight down, as a bird or a pegasus does to land.
            if simd_length(SIMD2(toTarget.x, toTarget.z)) > 0.001 {
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
