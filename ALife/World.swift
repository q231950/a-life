import ALifeClient
import RealityKit
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Builds the lot (floor tiles, the office in the middle, some bushes, your
/// character), turns taps on tiles into walks, shows one character per
/// session on the server, with a room of its own in the office and a little
/// sheep for each helper it has sent off, and shows what the characters
/// have built and planted.
@MainActor
final class World {
    let root = Entity()
    let camera = CameraRig()

    /// The floor plan. Once the lot is built, it is put on `root` too, for
    /// the systems that walk things around on it.
    private var lot = LotComponent(grid: TileGrid(width: LotPlan.width, depth: LotPlan.depth), tileSize: 1)
    /// The floor plan with only the office and the bushes on it, before
    /// anything is built or planted.
    private var scenery = TileGrid(width: LotPlan.width, depth: LotPlan.depth)
    /// The buildings and beds on the lot, by the file each comes from.
    private var placed: [String: (item: LotItem, entity: Entity)] = [:]
    private let character: Entity
    private let marker: ModelEntity
    private var agentCharacters: [String: AgentCharacter] = [:]
    /// The sheep of the helpers the agents sent off, by helper id. A sheep
    /// that has flown off is gone from the lot, and is dropped from here at
    /// the next `show(_:selectedID:)`.
    private var sheep: [String: Entity] = [:]
    /// The office, and the shirts of the characters whose rooms it has, by
    /// slot, to build it again when they change.
    private var office = Entity()
    private var officeShirts: [Int: PlatformColor]?

    init() {
        character = Self.makeCharacter(shirt: PlatformColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1))
        marker = ModelEntity(
            mesh: .generateBox(width: 0.35, height: 0.02, depth: 0.35, cornerRadius: 0.05),
            materials: [SimpleMaterial(color: PlatformColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), isMetallic: false)]
        )

        placeOffice()
        placeBushes()
        placeFloor()
        scenery = lot.grid
        root.components.set(lot)
        showOffice()

        // On the path beside the lawn.
        let start = Tile(x: LotPlan.lawn.x - 1, z: LotPlan.lawn.y + 1)
        character.position = lot.position(of: start)
        character.components.set(WalkComponent())
        Self.setLabel("You", on: character)
        root.addChild(character)

        marker.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        marker.isEnabled = false
        root.addChild(marker)

        root.addChild(Self.makeSun())
        root.addChild(camera.root)
        camera.focus(on: lot.position(of: Tile(x: LotPlan.house.x + LotPlan.house.width / 2, z: LotPlan.house.y + LotPlan.house.depth)))
    }

    // MARK: Walking

    /// Called with whatever entity the tap gesture hit.
    func walk(to tappedEntity: Entity) {
        guard let goal = tappedEntity.components[TileComponent.self]?.tile,
              walk(character, to: goal) else { return }
        marker.position = lot.position(of: goal) + [0, 0.02, 0]
        marker.isEnabled = true
        camera.focus(on: marker.position)
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
        /// Working, waiting for you in the middle of its work, or with
        /// something still to tell you: a call, or lines yet to be said.
        let isAtWork: Bool
        /// A tool call is waiting for your yes or no.
        let isWaitingForYou: Bool
        /// It finished a job while you were out of earshot, and is calling
        /// you about it.
        let isCalling: Bool
        /// The ids of the helpers (subagents) it has out working right now.
        let subagents: [String]
    }

    private struct AgentCharacter {
        let entity: Entity
        /// Which room in the office and which spot on the lawn belong to
        /// this agent.
        let slot: Int
        /// Its shirt's colour, which its room and its sheep have, too.
        let shirt: PlatformColor
        var name: String
        var isWaitingForYou = false
        var isCalling = false
    }

    /// The lawn in front of the door: where agents wait.
    private static let lawn = LotPlan.lawn.tiles.map { Tile(x: $0.x, z: $0.y) }

    /// Makes the scene match the sessions: one character each, in its room
    /// in the office while it works (or waits for you mid-task, or has
    /// something left to tell you) and out on the lawn otherwise, with a
    /// ring under the one you are talking to, a phone ringing over the ones
    /// calling you, and a sheep in its room for each helper it has out.
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
            // The "!" goes first: a phone can wait, a request can't.
            let isRinging = resident.isCalling && !resident.isWaitingForYou
            if shown.isCalling != isRinging {
                shown.isCalling = isRinging
                Self.setCallingMarker(isRinging, on: shown.entity)
            }
            shown.entity.findEntity(named: "Selection")?.isEnabled = resident.id == selectedID

            // `CommuteSystem` takes it to work and back.
            shown.entity.components[CommuteComponent.self]?.isAtWork = resident.isAtWork
            agentCharacters[resident.id] = shown
        }
        showOffice()
        showSheep(for: residents)
    }

    /// Builds the office again if the characters with rooms in it, or their
    /// shirts, have changed.
    private func showOffice() {
        let shirts = Dictionary(agentCharacters.values.map { ($0.slot, $0.shirt) }, uniquingKeysWith: { first, _ in first })
        guard shirts != officeShirts else { return }
        officeShirts = shirts
        office.removeFromParent()
        office = OfficeBuilding.make(rooms: shirts, on: lot)
        root.addChild(office)
    }

    /// Puts a sheep in its agent's room for each helper that has just been
    /// sent off, and pops each sheep whose helper has reported back.
    /// `SheepSystem` takes it from there.
    private func showSheep(for residents: [Resident]) {
        sheep = sheep.filter { $0.value.parent != nil } // the ones that flew off

        var out: Set<String> = []
        for resident in residents {
            guard let agent = agentCharacters[resident.id] else { continue }
            for id in resident.subagents {
                out.insert(id)
                if sheep[id] == nil {
                    sheep[id] = addSheep(beside: agent)
                }
            }
        }
        // Includes the helpers of an agent that has left the lot.
        for (id, entity) in sheep where !out.contains(id) {
            entity.components[SheepComponent.self]?.hasReportedBack = true
        }
    }

    /// A sheep popping up in `agent`'s room, on the nearest spot round its
    /// desk that none of the agent's other sheep stands on.
    private func addSheep(beside agent: AgentCharacter) -> Entity {
        let taken = Set(sheep.values.compactMap { $0.components[SheepComponent.self] }.filter { $0.agent === agent.entity }.map(\.place))
        let place = (0...taken.count).first { !taken.contains($0) } ?? 0
        let room = OfficePlan.room(forSlot: agent.slot)

        let entity = Self.makeSheep(scarf: agent.shirt)
        entity.position = lot.position(of: OfficePlan.sheepSpot(in: room, place: place), height: room.floor)
        entity.scale = SIMD3(repeating: 0.01) // it pops up from nothing
        entity.components.set(SheepComponent(agent: agent.entity, spot: entity.position, place: place, scarf: agent.shirt))
        root.addChild(entity)
        return entity
    }

    /// Each character's shirt colour, by session, so the panel can show
    /// them in the same colours as the lot.
    var shirts: [String: PlatformColor] {
        agentCharacters.mapValues(\.shirt)
    }

    /// The sessions whose characters stand close enough to yours to be
    /// heard.
    func residentsInEarshot() -> Set<String> {
        let you = character.position
        return Set(agentCharacters.compactMap { id, agent in
            let position = agent.entity.position
            return Earshot.contains(listener: (x: you.x, z: you.z), speaker: (x: position.x, z: position.z)) ? id : nil
        })
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

        let shirt = PlatformColor.shirt(hex: resident.color, slot: slot)
        let entity = Self.makeCharacter(shirt: shirt)
        entity.name = resident.id
        entity.position = lot.position(of: home)
        entity.components.set(WalkComponent())
        let room = OfficePlan.room(forSlot: slot)
        let lift = OfficePlan.lift(forSlot: slot)
        entity.components.set(CommuteComponent(
            lawn: home,
            lift: Tile(x: lift.x, z: lift.y),
            desk: lot.position(of: room.desk, height: room.floor)
        ))
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
        return AgentCharacter(entity: entity, slot: slot, shirt: shirt, name: resident.name)
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

    /// A phone ringing over the character's head while it calls you.
    private static func setCallingMarker(_ isShown: Bool, on character: Entity) {
        character.findEntity(named: "Calling")?.removeFromParent()
        guard isShown else { return }

        let marker = Entity()
        marker.name = "Calling"
        marker.position = [0, 1.3, 0]
        marker.components.set(BillboardComponent())
        marker.addChild(Phone.makeRingingHandset())
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

    // MARK: What's built and planted

    /// Makes the lot match what the characters have built and planted. If
    /// `popsUp`, as for something just built rather than there all along,
    /// new things pop up and the camera glides over to look at the newest.
    func show(_ things: Lot, popsUp: Bool) {
        let current = Dictionary(things.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, shown) in placed where current[id] != shown.item {
            shown.entity.removeFromParent()
            placed[id] = nil
        }

        var newest: Entity?
        for item in things.items where placed[item.id] == nil && item.category != .unknown {
            let entity = makeEntity(for: item)
            root.addChild(entity)
            placed[item.id] = (item, entity)
            if popsUp {
                let shown = entity.transform
                entity.scale = SIMD3(repeating: 0.01) // it pops up from nothing
                entity.move(to: shown, relativeTo: root, duration: 0.6, timingFunction: .easeOut)
                newest = entity
            }
        }

        // Nobody walks through what is built or planted, except grass and
        // the foals' patch, which the foals trot in and out of.
        var grid = scenery
        for (item, _) in placed.values where !(item.category == .plant && (item.isFoals || Plants.isWalkable(item.kind))) {
            for tile in item.area.tiles {
                grid.block(Tile(x: tile.x, z: tile.y))
            }
        }
        lot.grid = grid
        root.components.set(lot)

        if let newest {
            camera.focus(on: newest.position)
        }
    }

    /// A building, a bed of plants or the Gardener's foals, standing where it is on the lot.
    private func makeEntity(for item: LotItem) -> Entity {
        let area = item.area
        let first = lot.position(of: Tile(x: area.x, z: area.y))
        let last = lot.position(of: Tile(x: area.xs.upperBound - 1, z: area.ys.upperBound - 1))
        let centre = (first + last) / 2

        let entity: Entity
        switch item.category {
        case .plant:
            let tiles = area.tiles.map { (x: $0.x, y: $0.y, position: lot.position(of: Tile(x: $0.x, z: $0.y)) - centre) }
            entity = item.isFoals ? Foals.make(item, tiles: tiles) : Plants.make(item, tiles: tiles, tileSize: lot.tileSize)
        case .building, .unknown:
            entity = Buildings.make(item, width: Float(area.width) * lot.tileSize, depth: Float(area.depth) * lot.tileSize)
        }
        entity.position = centre
        return entity
    }

    // MARK: Building the lot

    /// The grass, in two meshes, one for the light tiles and one for the
    /// dark, on a slab of earth. Each tile is still an entity of its own, for
    /// a tap to land on, with nothing to draw.
    private func placeFloor() {
        let tileSize = lot.tileSize
        let half = tileSize / 2
        let shape = ShapeResource.generateBox(width: tileSize, height: 0.1, depth: tileSize)

        var light = (positions: [SIMD3<Float>](), indices: [UInt32]())
        var dark = light
        for tile in lot.grid.allTiles {
            let centre = lot.position(of: tile) // top face at y = 0
            let isLight = (tile.x + tile.z).isMultiple(of: 2)
            var squares = isLight ? light : dark
            let first = UInt32(squares.positions.count)
            squares.positions += [centre + [-half, 0, -half], centre + [-half, 0, half], centre + [half, 0, half], centre + [half, 0, -half]]
            squares.indices += [first, first + 1, first + 2, first, first + 2, first + 3] // facing up
            if isLight { light = squares } else { dark = squares }

            let target = Entity()
            target.position = centre - [0, 0.05, 0]
            target.components.set(TileComponent(tile: tile))
            // Both are needed for an entity to receive targeted gestures.
            target.components.set(CollisionComponent(shapes: [shape]))
            target.components.set(InputTargetComponent())
            root.addChild(target)
        }

        for (squares, color) in [
            (light, PlatformColor(red: 0.55, green: 0.78, blue: 0.38, alpha: 1)),
            (dark, PlatformColor(red: 0.48, green: 0.71, blue: 0.33, alpha: 1)),
        ] {
            var descriptor = MeshDescriptor(name: "Grass")
            descriptor.positions = MeshBuffers.Positions(squares.positions)
            descriptor.normals = MeshBuffers.Normals(Array(repeating: [0, 1, 0], count: squares.positions.count))
            descriptor.primitives = .triangles(squares.indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { continue }
            root.addChild(ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 0.9, isMetallic: false)]))
        }

        let width = Float(lot.grid.width) * tileSize
        let depth = Float(lot.grid.depth) * tileSize
        let earth = ModelEntity(
            mesh: .generateBox(width: width, height: 0.3, depth: depth),
            materials: [SimpleMaterial(color: PlatformColor(red: 0.45, green: 0.34, blue: 0.24, alpha: 1), roughness: 1, isMetallic: false)]
        )
        earth.position = [0, -0.153, 0] // just under the grass
        root.addChild(earth)
    }

    /// Blocks the tiles along the office's walls on the floor plan, all but
    /// its two-tile doorway, so paths visibly route around them. The office
    /// itself is drawn by `showOffice()`, once the lot is built.
    private func placeOffice() {
        let house = LotPlan.house
        let doorway = Set(LotPlan.doorway.map { Tile(x: $0.x, z: $0.y) })

        for spot in house.tiles where spot.x == house.xs.first || spot.x == house.xs.last || spot.y == house.ys.first || spot.y == house.ys.last {
            let tile = Tile(x: spot.x, z: spot.y)
            guard !doorway.contains(tile) else { continue }
            lot.grid.block(tile)
        }
    }

    private func placeBushes() {
        let mesh = MeshResource.generateSphere(radius: 0.4)
        let material = SimpleMaterial(color: PlatformColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1), roughness: 1.0, isMetallic: false)

        for tile in LotPlan.bushes.map({ Tile(x: $0.x, z: $0.y) }) {
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
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 80, depthBias: 2)
        sun.look(at: .zero, from: [6, 10, 4], relativeTo: nil)
        return sun
    }
}

extension PlatformColor {
    /// The shirts for characters the server gives no colour, by slot.
    private static let spareShirts: [PlatformColor] = [
        PlatformColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1),
        PlatformColor(red: 0.95, green: 0.65, blue: 0.2, alpha: 1),
        PlatformColor(red: 0.3, green: 0.7, blue: 0.65, alpha: 1),
        PlatformColor(red: 0.8, green: 0.45, blue: 0.75, alpha: 1),
        PlatformColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 1),
    ]

    /// A character's shirt: the colour the server gives it as `#RRGGBB`, or
    /// else a spare one for the character's slot. The lot and the panel both
    /// pick it here, so a character looks the same in both.
    static func shirt(hex: String?, slot: Int) -> PlatformColor {
        hex.flatMap { PlatformColor(hex: $0) } ?? spareShirts[slot % spareShirts.count]
    }
}
