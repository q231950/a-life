import ManagedAgents
import RealityKit
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Builds the lot (floor tiles, a little house, some bushes, your character),
/// turns taps on tiles into walks, and shows one character per agent.
@MainActor
final class World {
    let root = Entity()
    let camera = CameraRig()

    private var grid = TileGrid(width: 16, depth: 16)
    private let tileSize: Float = 1
    private let character: Entity
    private let marker: ModelEntity
    private var agentCharacters: [String: AgentCharacter] = [:]

    init() {
        character = Self.makeCharacter(shirt: PlatformColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1))
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
        root.addChild(camera.root)
    }

    // MARK: Walking

    /// Called with whatever entity the tap gesture hit.
    func walk(to tappedEntity: Entity) {
        guard let goal = tappedEntity.components[TileComponent.self]?.tile,
              walk(character, to: goal) else { return }
        marker.position = position(of: goal) + [0, 0.02, 0]
        marker.isEnabled = true
    }

    /// Sends `walker` to `goal`. Returns `false` if there is no way there.
    @discardableResult
    private func walk(_ walker: Entity, to goal: Tile) -> Bool {
        let start = tile(at: walker.position)
        guard let route = grid.path(from: start, to: goal) else { return false }

        var waypoints = route.map(position(of:))
        // When re-routing mid-step, first get back onto the centre of a tile.
        if simd_distance(walker.position, position(of: start)) > 0.05 {
            waypoints.insert(position(of: start), at: 0)
        }
        walker.components[WalkComponent.self]?.waypoints = waypoints
        return true
    }

    // MARK: Agents

    private struct AgentCharacter {
        let entity: Entity
        /// Which desk and which spot on the lawn belong to this agent.
        let slot: Int
        var name: String
        var destination: Tile
    }

    /// The floor inside the house: where agents go while they work.
    private static let desks = (6...9).flatMap { z in (6...9).map { x in Tile(x: x, z: z) } }
    /// The lawn in front of the door: where agents wait.
    private static let lawn = (12...14).flatMap { z in (5...10).map { x in Tile(x: x, z: z) } }

    /// Makes the scene match the session: one character per agent, inside the
    /// house while its agent is running and out on the lawn otherwise.
    func show(_ agents: [AgentThread]) {
        let current = Set(agents.map(\.id))
        for (id, gone) in agentCharacters where !current.contains(id) {
            gone.entity.removeFromParent()
            agentCharacters[id] = nil
        }

        for agent in agents {
            var shown = agentCharacters[agent.id] ?? addCharacter(for: agent)
            if shown.name != agent.name {
                shown.name = agent.name
                Self.setLabel(agent.name, on: shown.entity)
            }
            let spots = agent.status == .running ? Self.desks : Self.lawn
            let destination = spots[shown.slot % spots.count]
            if shown.destination != destination, walk(shown.entity, to: destination) {
                shown.destination = destination
            }
            agentCharacters[agent.id] = shown
        }
    }

    private func addCharacter(for agent: AgentThread) -> AgentCharacter {
        let taken = Set(agentCharacters.values.map(\.slot))
        let slot = (0...taken.count).first { !taken.contains($0) } ?? 0
        let home = Self.lawn[slot % Self.lawn.count]

        let shirts: [PlatformColor] = [
            PlatformColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1),
            PlatformColor(red: 0.95, green: 0.65, blue: 0.2, alpha: 1),
            PlatformColor(red: 0.3, green: 0.7, blue: 0.65, alpha: 1),
            PlatformColor(red: 0.8, green: 0.45, blue: 0.75, alpha: 1),
            PlatformColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 1),
        ]
        let entity = Self.makeCharacter(
            shirt: agent.isCoordinator ? PlatformColor(red: 0.45, green: 0.3, blue: 0.75, alpha: 1) : shirts[slot % shirts.count]
        )
        entity.name = agent.id
        if agent.isCoordinator { entity.scale = [1.15, 1.15, 1.15] }
        entity.position = position(of: home)
        entity.components.set(WalkComponent())
        Self.setLabel(agent.name, on: entity)
        root.addChild(entity)
        return AgentCharacter(entity: entity, slot: slot, name: agent.name, destination: home)
    }

    /// A name floating above the character's head, always facing the camera.
    private static func setLabel(_ name: String, on character: Entity) {
        character.findEntity(named: "Label")?.removeFromParent()

        let mesh = MeshResource.generateText(
            String(name.prefix(20)),
            extrusionDepth: 0.004,
            font: .systemFont(ofSize: 0.13),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        text.position = [-mesh.bounds.center.x, 0, 0] // text meshes start at their left edge

        let label = Entity()
        label.name = "Label"
        label.position = [0, 1.1, 0]
        label.components.set(BillboardComponent())
        label.addChild(text)
        character.addChild(label)
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
        let mesh = MeshResource.generateBox(width: tileSize, height: 0.1, depth: tileSize)
        let shape = ShapeResource.generateBox(width: tileSize, height: 0.1, depth: tileSize)
        let light = SimpleMaterial(color: PlatformColor(red: 0.55, green: 0.78, blue: 0.38, alpha: 1), roughness: 0.9, isMetallic: false)
        let dark = SimpleMaterial(color: PlatformColor(red: 0.48, green: 0.71, blue: 0.33, alpha: 1), roughness: 0.9, isMetallic: false)

        for tile in grid.allTiles {
            let entity = ModelEntity(mesh: mesh, materials: [(tile.x + tile.z).isMultiple(of: 2) ? light : dark])
            entity.position = position(of: tile) - [0, 0.05, 0] // top face at y = 0
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

    private static func makeCharacter(shirt: PlatformColor) -> Entity {
        let skin = SimpleMaterial(color: PlatformColor(red: 0.96, green: 0.8, blue: 0.67, alpha: 1), roughness: 0.6, isMetallic: false)
        let shirt = SimpleMaterial(color: shirt, roughness: 0.6, isMetallic: false)

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
