import RealityKit
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Builds the lot (floor tiles, a little house, some bushes, your character),
/// turns taps on tiles into walks, and shows one character per session on
/// the server, with a little sheep for each helper it has sent off.
@MainActor
final class World {
    let root = Entity()
    let camera = CameraRig()

    /// The floor plan. Once the lot is built, it is put on `root` too, for
    /// the systems that walk things around on it.
    private var lot = LotComponent(grid: TileGrid(width: 16, depth: 16), tileSize: 1)
    private let character: Entity
    private let marker: ModelEntity
    private var agentCharacters: [String: AgentCharacter] = [:]
    /// The sheep of the helpers the agents sent off, by helper id. A sheep
    /// that has flown off is gone from the lot, and is dropped from here at
    /// the next `show(_:selectedID:)`.
    private var sheep: [String: Entity] = [:]

    init() {
        character = Self.makeCharacter(shirt: PlatformColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1))
        marker = ModelEntity(
            mesh: .generateBox(width: 0.35, height: 0.02, depth: 0.35, cornerRadius: 0.05),
            materials: [SimpleMaterial(color: PlatformColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), isMetallic: false)]
        )

        placeHouse()
        placeBushes()
        placeFloor()
        root.components.set(lot)

        character.position = lot.position(of: Tile(x: 2, z: 2))
        character.components.set(WalkComponent())
        Self.setLabel("You", on: character)
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
        marker.position = lot.position(of: goal) + [0, 0.02, 0]
        marker.isEnabled = true
    }

    /// Sends `walker` to `goal`. Returns `false` if there is no way there.
    @discardableResult
    private func walk(_ walker: Entity, to goal: Tile) -> Bool {
        guard let waypoints = lot.route(from: walker.position, to: goal) else { return false }
        walker.components[WalkComponent.self]?.waypoints = waypoints
        return true
    }

    // MARK: Agents

    /// What the lot shows of one session's character.
    struct Resident: Equatable {
        let id: String
        let name: String
        /// Its shirt's colour as `#RRGGBB`, if the server gives it one.
        let color: String?
        /// Working, or waiting for you in the middle of its work.
        let isAtWork: Bool
        /// A tool call is waiting for your yes or no.
        let isWaitingForYou: Bool
        /// The ids of the helpers (subagents) it has out working right now.
        let subagents: [String]
    }

    private struct AgentCharacter {
        let entity: Entity
        /// Which desk and which spot on the lawn belong to this agent.
        let slot: Int
        /// Its shirt's colour, which its sheep wear, too.
        let shirt: PlatformColor
        var name: String
        var destination: Tile
        var isWaitingForYou = false
    }

    /// The floor inside the house: where agents go while they work.
    private static let desks = (6...9).flatMap { z in (6...9).map { x in Tile(x: x, z: z) } }
    /// The lawn in front of the door: where agents wait.
    private static let lawn = (12...14).flatMap { z in (5...10).map { x in Tile(x: x, z: z) } }

    /// Makes the scene match the sessions: one character each, inside the
    /// house while it works (or waits for you mid-task) and out on the lawn
    /// otherwise, with a ring under the one you are talking to, and a sheep
    /// for each helper it has out.
    func show(_ residents: [Resident], selectedID: String?) {
        let current = Set(residents.map(\.id))
        for (id, gone) in agentCharacters where !current.contains(id) {
            gone.entity.removeFromParent()
            agentCharacters[id] = nil
        }

        for resident in residents {
            var shown = agentCharacters[resident.id] ?? addCharacter(for: resident)
            if shown.name != resident.name {
                shown.name = resident.name
                Self.setLabel(resident.name, on: shown.entity)
            }
            if shown.isWaitingForYou != resident.isWaitingForYou {
                shown.isWaitingForYou = resident.isWaitingForYou
                Self.setWaitingMarker(resident.isWaitingForYou, on: shown.entity)
            }
            shown.entity.findEntity(named: "Selection")?.isEnabled = resident.id == selectedID

            let spots = resident.isAtWork ? Self.desks : Self.lawn
            let destination = spots[shown.slot % spots.count]
            if shown.destination != destination, walk(shown.entity, to: destination) {
                shown.destination = destination
            }
            agentCharacters[resident.id] = shown
        }
        showSheep(for: residents)
    }

    /// Puts a sheep next to its agent for each helper that has just been sent
    /// off, and sends each sheep whose helper has reported back home to its
    /// agent. `SheepSystem` takes it from there.
    private func showSheep(for residents: [Resident]) {
        sheep = sheep.filter { $0.value.parent != nil } // the ones that flew off

        var out: Set<String> = []
        for resident in residents {
            guard let agent = agentCharacters[resident.id] else { continue }
            for (place, id) in resident.subagents.enumerated() {
                out.insert(id)
                if sheep[id] == nil {
                    sheep[id] = addSheep(beside: agent, place: place)
                }
            }
        }
        // Includes the helpers of an agent that has left the lot.
        for (id, entity) in sheep where !out.contains(id) {
            entity.components[SheepComponent.self]?.hasReportedBack = true
        }
    }

    /// A sheep popping up beside `agent`, on the side of the `place`th free
    /// tile around it, so that it doesn't stand in a wall and two sent off
    /// together don't stand in each other.
    private func addSheep(beside agent: AgentCharacter, place: Int) -> Entity {
        let entity = Self.makeSheep(scarf: agent.shirt)
        let here = lot.tile(at: agent.entity.position)
        let sides = [(x: 1, z: 0), (x: -1, z: 0), (x: 0, z: 1), (x: 0, z: -1)].filter {
            lot.grid.isWalkable(Tile(x: here.x + $0.x, z: here.z + $0.z))
        }
        entity.position = agent.entity.position
        if !sides.isEmpty {
            let side = sides[place % sides.count]
            let direction = SIMD3<Float>(Float(side.x), 0, Float(side.z))
            entity.position += direction * 0.5
            // Facing away from its agent, towards where it's off to.
            entity.orientation = simd_quatf(angle: atan2(direction.x, direction.z), axis: [0, 1, 0])
        }
        entity.scale = SIMD3(repeating: 0.01) // it pops up from nothing
        entity.components.set(WalkComponent(speed: 1.6))
        entity.components.set(SheepComponent(agent: agent.entity))
        root.addChild(entity)
        return entity
    }

    /// The session whose character `entity` is, or is part of.
    func residentID(of entity: Entity) -> String? {
        var current: Entity? = entity
        while let candidate = current {
            if let id = agentCharacters.first(where: { $0.value.entity === candidate })?.key {
                return id
            }
            current = candidate.parent
        }
        return nil
    }

    private func addCharacter(for resident: Resident) -> AgentCharacter {
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
        let shirt = resident.color.flatMap { Self.color(hex: $0) } ?? shirts[slot % shirts.count]
        let entity = Self.makeCharacter(shirt: shirt)
        entity.name = resident.id
        entity.position = lot.position(of: home)
        entity.components.set(WalkComponent())
        // Both are needed for a tap to land on the character itself.
        let shape = ShapeResource.generateBox(width: 0.5, height: 1.1, depth: 0.5).offsetBy(translation: [0, 0.55, 0])
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(InputTargetComponent())
        Self.setLabel(resident.name, on: entity)

        // Shown under the character you are talking to.
        let ring = ModelEntity(
            mesh: .generatePlane(width: 0.7, depth: 0.7, cornerRadius: 0.35),
            materials: [UnlitMaterial(color: .white)]
        )
        ring.name = "Selection"
        ring.position = [0, 0.015, 0]
        ring.isEnabled = false
        entity.addChild(ring)

        root.addChild(entity)
        return AgentCharacter(entity: entity, slot: slot, shirt: shirt, name: resident.name, destination: home)
    }

    /// A colour written as `#RRGGBB`, or `nil` if it isn't one.
    private static func color(hex: String) -> PlatformColor? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return PlatformColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A "!" over the character's head while it waits for your answer.
    private static func setWaitingMarker(_ isShown: Bool, on character: Entity) {
        character.findEntity(named: "Waiting")?.removeFromParent()
        guard isShown else { return }

        let mesh = MeshResource.generateText(
            "!",
            extrusionDepth: 0.01,
            font: .boldSystemFont(ofSize: 0.3),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: PlatformColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))])
        text.position = [-mesh.bounds.center.x, 0, 0]

        let marker = Entity()
        marker.name = "Waiting"
        marker.position = [0, 1.3, 0]
        marker.components.set(BillboardComponent())
        marker.addChild(text)
        character.addChild(marker)
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

    // MARK: Building the lot

    private func placeFloor() {
        let tileSize = lot.tileSize
        let mesh = MeshResource.generateBox(width: tileSize, height: 0.1, depth: tileSize)
        let shape = ShapeResource.generateBox(width: tileSize, height: 0.1, depth: tileSize)
        let light = SimpleMaterial(color: PlatformColor(red: 0.55, green: 0.78, blue: 0.38, alpha: 1), roughness: 0.9, isMetallic: false)
        let dark = SimpleMaterial(color: PlatformColor(red: 0.48, green: 0.71, blue: 0.33, alpha: 1), roughness: 0.9, isMetallic: false)

        for tile in lot.grid.allTiles {
            let entity = ModelEntity(mesh: mesh, materials: [(tile.x + tile.z).isMultiple(of: 2) ? light : dark])
            entity.position = lot.position(of: tile) - [0, 0.05, 0] // top face at y = 0
            entity.components.set(TileComponent(tile: tile))
            // Both are needed for an entity to receive targeted gestures.
            entity.components.set(CollisionComponent(shapes: [shape]))
            entity.components.set(InputTargetComponent())
            root.addChild(entity)
        }
    }

    /// A 6×6 room with a two-tile doorway, so paths visibly route around walls.
    private func placeHouse() {
        let mesh = MeshResource.generateBox(width: lot.tileSize, height: 0.7, depth: lot.tileSize)
        let material = SimpleMaterial(color: PlatformColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1), roughness: 0.7, isMetallic: false)
        let range = 5...10
        let doorway: Set<Tile> = [Tile(x: 7, z: 10), Tile(x: 8, z: 10)]

        for x in range {
            for z in range where x == range.lowerBound || x == range.upperBound || z == range.lowerBound || z == range.upperBound {
                let tile = Tile(x: x, z: z)
                guard !doorway.contains(tile) else { continue }
                lot.grid.block(tile)
                let wall = ModelEntity(mesh: mesh, materials: [material])
                wall.position = lot.position(of: tile) + [0, 0.35, 0]
                root.addChild(wall)
            }
        }
    }

    private func placeBushes() {
        let mesh = MeshResource.generateSphere(radius: 0.4)
        let material = SimpleMaterial(color: PlatformColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1), roughness: 1.0, isMetallic: false)

        for tile in [Tile(x: 12, z: 3), Tile(x: 13, z: 3), Tile(x: 2, z: 12), Tile(x: 3, z: 13), Tile(x: 13, z: 12)] {
            lot.grid.block(tile)
            let bush = ModelEntity(mesh: mesh, materials: [material])
            bush.position = lot.position(of: tile) + [0, 0.35, 0]
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

    /// A helper's sheep: about half as tall as a character and built the same
    /// way, facing +z like one, with a scarf in its agent's shirt colour.
    private static func makeSheep(scarf: PlatformColor) -> Entity {
        let wool = SimpleMaterial(color: PlatformColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1), roughness: 0.9, isMetallic: false)
        let face = SimpleMaterial(color: PlatformColor(red: 0.3, green: 0.27, blue: 0.27, alpha: 1), roughness: 0.6, isMetallic: false)
        let scarf = SimpleMaterial(color: scarf, roughness: 0.6, isMetallic: false)

        let sheep = Entity()
        sheep.name = "Sheep"

        let leg = MeshResource.generateBox(width: 0.06, height: 0.16, depth: 0.06, cornerRadius: 0.02)
        for x: Float in [-0.08, 0.08] {
            for z: Float in [-0.11, 0.11] {
                let part = ModelEntity(mesh: leg, materials: [face])
                part.position = [x, 0.08, z]
                sheep.addChild(part)
            }
        }

        let body = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.24, depth: 0.4, cornerRadius: 0.1), materials: [wool])
        body.position = [0, 0.27, 0]
        sheep.addChild(body)

        let collar = ModelEntity(mesh: .generateBox(width: 0.22, height: 0.07, depth: 0.1, cornerRadius: 0.03), materials: [scarf])
        collar.position = [0, 0.32, 0.2]
        sheep.addChild(collar)

        let head = ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [face])
        head.position = [0, 0.38, 0.25]
        sheep.addChild(head)

        // One flat bar through the head makes both ears.
        let ears = ModelEntity(mesh: .generateBox(width: 0.28, height: 0.03, depth: 0.05, cornerRadius: 0.015), materials: [face])
        ears.position = [0, 0.41, 0.23]
        sheep.addChild(ears)

        // A tuft of wool on top of the head.
        let tuft = ModelEntity(mesh: .generateSphere(radius: 0.06), materials: [wool])
        tuft.position = [0, 0.46, 0.23]
        sheep.addChild(tuft)

        return sheep
    }

    private static func makeSun() -> Entity {
        let sun = DirectionalLight()
        sun.light.intensity = 4000
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2)
        sun.look(at: .zero, from: [6, 10, 4], relativeTo: nil)
        return sun
    }
}
