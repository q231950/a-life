import RealityKit
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Builds the lot (floor tiles, a little house, some bushes, one character)
/// and turns taps on tiles into walks.
@MainActor
final class World {
    let root = Entity()
    /// Only used in a window. On a real surface the device is the camera.
    let camera = CameraRig()

    private var grid = TileGrid(width: 16, depth: 16)
    private let tileSize: Float = 1
    private let tileThickness: Float = 0.1
    private let character: Entity
    private let marker: ModelEntity

    init() {
        character = Self.makeCharacter()
        marker = ModelEntity(
            mesh: .generateBox(width: 0.35, height: 0.02, depth: 0.35, cornerRadius: 0.05),
            materials: [SimpleMaterial(color: PlatformColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), isMetallic: false)]
        )

        placeHouse()
        placeBushes()
        placeFloor()

        character.position = position(of: Tile(x: 2, z: 2))
        character.components.set(WalkComponent())
        root.addChild(character)

        marker.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        marker.isEnabled = false
        root.addChild(marker)

        root.addChild(Self.makeSun())
    }

    // MARK: Showing the lot

    /// For a window: the lot at full size, seen through the orbit camera.
    func contentForWindow() -> Entity {
        root.addChild(camera.root)
        return root
    }

    #if os(iOS)
    /// For a real surface: the lot shrunk to `width` metres across, with the
    /// bottom of its floor tiles at y = 0. Put it under an entity whose y-axis
    /// is the surface's normal.
    ///
    /// The orbit camera stays out of this tree: a camera entity under an
    /// anchor pins the content to the screen instead of the surface.
    func contentForSurface(width: Float = 0.5) -> Entity {
        // Tiles are 1 m, so the lot is 16 m wide. Walks are measured in the
        // lot's own space, so they shrink along with it.
        let scale = width / (Float(grid.width) * tileSize)
        root.scale = SIMD3(repeating: scale)
        root.position = [0, tileThickness * scale, 0]
        return root
    }

    /// See-through, with tiles that ignore taps, while the lot is being placed.
    func setPreview(_ isPreview: Bool) {
        if isPreview {
            root.components.set(OpacityComponent(opacity: 0.5))
        } else {
            root.components.remove(OpacityComponent.self)
        }
        for tile in root.children where tile.components.has(TileComponent.self) {
            tile.components[InputTargetComponent.self]?.isEnabled = !isPreview
        }
    }
    #endif

    // MARK: Walking

    /// Called with whatever entity the tap gesture hit.
    func walk(to tappedEntity: Entity) {
        guard let goal = tappedEntity.components[TileComponent.self]?.tile else { return }
        let start = tile(at: character.position)
        guard let route = grid.path(from: start, to: goal) else { return }

        var waypoints = route.map(position(of:))
        // When re-routing mid-step, first get back onto the centre of a tile.
        if simd_distance(character.position, position(of: start)) > 0.05 {
            waypoints.insert(position(of: start), at: 0)
        }
        character.components[WalkComponent.self]?.waypoints = waypoints

        marker.position = position(of: goal) + [0, 0.02, 0]
        marker.isEnabled = true
    }

    // MARK: Grid <-> world space

    private func position(of tile: Tile) -> SIMD3<Float> {
        [
            (Float(tile.x) - Float(grid.width - 1) / 2) * tileSize,
            0,
            (Float(tile.z) - Float(grid.depth - 1) / 2) * tileSize,
        ]
    }

    private func tile(at position: SIMD3<Float>) -> Tile {
        Tile(
            x: Int((position.x / tileSize + Float(grid.width - 1) / 2).rounded()),
            z: Int((position.z / tileSize + Float(grid.depth - 1) / 2).rounded())
        )
    }

    // MARK: Building the lot

    private func placeFloor() {
        let mesh = MeshResource.generateBox(width: tileSize, height: tileThickness, depth: tileSize)
        let shape = ShapeResource.generateBox(width: tileSize, height: tileThickness, depth: tileSize)
        let light = SimpleMaterial(color: PlatformColor(red: 0.55, green: 0.78, blue: 0.38, alpha: 1), roughness: 0.9, isMetallic: false)
        let dark = SimpleMaterial(color: PlatformColor(red: 0.48, green: 0.71, blue: 0.33, alpha: 1), roughness: 0.9, isMetallic: false)

        for tile in grid.allTiles {
            let entity = ModelEntity(mesh: mesh, materials: [(tile.x + tile.z).isMultiple(of: 2) ? light : dark])
            entity.position = position(of: tile) - [0, tileThickness / 2, 0] // top face at y = 0
            entity.components.set(TileComponent(tile: tile))
            // Both are needed for an entity to receive targeted gestures.
            entity.components.set(CollisionComponent(shapes: [shape]))
            entity.components.set(InputTargetComponent())
            root.addChild(entity)
        }
    }

    /// A 6×6 room with a two-tile doorway, so paths visibly route around walls.
    private func placeHouse() {
        let mesh = MeshResource.generateBox(width: tileSize, height: 0.7, depth: tileSize)
        let material = SimpleMaterial(color: PlatformColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1), roughness: 0.7, isMetallic: false)
        let range = 5...10
        let doorway: Set<Tile> = [Tile(x: 7, z: 10), Tile(x: 8, z: 10)]

        for x in range {
            for z in range where x == range.lowerBound || x == range.upperBound || z == range.lowerBound || z == range.upperBound {
                let tile = Tile(x: x, z: z)
                guard !doorway.contains(tile) else { continue }
                grid.block(tile)
                let wall = ModelEntity(mesh: mesh, materials: [material])
                wall.position = position(of: tile) + [0, 0.35, 0]
                root.addChild(wall)
            }
        }
    }

    private func placeBushes() {
        let mesh = MeshResource.generateSphere(radius: 0.4)
        let material = SimpleMaterial(color: PlatformColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1), roughness: 1.0, isMetallic: false)

        for tile in [Tile(x: 12, z: 3), Tile(x: 13, z: 3), Tile(x: 2, z: 12), Tile(x: 3, z: 13), Tile(x: 13, z: 12)] {
            grid.block(tile)
            let bush = ModelEntity(mesh: mesh, materials: [material])
            bush.position = position(of: tile) + [0, 0.35, 0]
            root.addChild(bush)
        }
    }

    private static func makeCharacter() -> Entity {
        let skin = SimpleMaterial(color: PlatformColor(red: 0.96, green: 0.8, blue: 0.67, alpha: 1), roughness: 0.6, isMetallic: false)
        let shirt = SimpleMaterial(color: PlatformColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1), roughness: 0.6, isMetallic: false)

        let body = ModelEntity(mesh: .generateBox(width: 0.32, height: 0.6, depth: 0.22, cornerRadius: 0.08), materials: [shirt])
        body.position = [0, 0.4, 0]

        let head = ModelEntity(mesh: .generateSphere(radius: 0.15), materials: [skin])
        head.position = [0, 0.85, 0]

        // A nose on +z, so you can see which way the character is facing.
        let nose = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [skin])
        nose.position = [0, 0.85, 0.15]

        let character = Entity()
        character.name = "Character"
        character.addChild(body)
        character.addChild(head)
        character.addChild(nose)
        return character
    }

    private static func makeSun() -> Entity {
        let sun = DirectionalLight()
        sun.light.intensity = 4000
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2)
        sun.look(at: .zero, from: [6, 10, 4], relativeTo: nil)
        return sun
    }
}
