import ALifeClient
import CoreGraphics
import RealityKit

/// The office the characters work in, on the house's tiles in the middle of
/// the lot (see `OfficePlan`): a modern block of glass with neon along its
/// edges, a lobby on the ground floor with the door at the front and a lift
/// at the back, and a storey for every two characters over it. Each
/// character has a room of its own, lit in the colour of its shirt, with a
/// desk by the front window where you can see it through the glass while it
/// works. The walls the characters walk round are on the lot's floor plan;
/// this is only what you see.
@MainActor
enum OfficeBuilding {
    /// The office with a room for each slot in `shirts`, up to the highest,
    /// each lit in the shirt of the character in that slot, or left dark if
    /// nobody has it at the moment. Its parts stand in `lot`'s space.
    static func make(rooms shirts: [Int: PlatformColor], on lot: LotComponent) -> Entity {
        let office = Entity()
        office.name = "Office"

        let rooms = OfficePlan.rooms(tintedBy: shirts)
        let storeys = OfficePlan.storeys(forRooms: rooms.count)
        let storeyHeight = OfficePlan.storeyHeight
        let top = Float(storeys) * storeyHeight

        let area = OfficePlan.footprint
        let corner = lot.position(x: Float(area.x) - 0.5, y: Float(area.y) - 0.5)
        let far = lot.position(x: Float(area.xs.upperBound) - 0.5, y: Float(area.ys.upperBound) - 0.5)
        let shell = Shell(left: corner.x, right: far.x, back: corner.z, front: far.z)

        addLobby(to: office, shell: shell, on: lot)
        for storey in 1..<storeys {
            let floor = Float(storey) * storeyHeight
            addSlab(to: office, shell: shell, at: floor)
            addGlass(to: office, shell: shell, from: floor, to: floor + storeyHeight - slabDepth, door: nil)
            // A frosted wall between the two rooms.
            let partition = ModelEntity(
                mesh: .generateBox(width: 0.05, height: storeyHeight - slabDepth, depth: shell.depth - 0.08),
                materials: [Buildings.material(PlatformColor(white: 0.92, alpha: 1), roughness: 0.4)]
            )
            partition.position = [shell.centreX, floor + (storeyHeight - slabDepth) / 2, shell.centreZ]
            office.addChild(partition)
        }
        for (room, shirt) in rooms {
            addRoom(room, shirt: shirt, to: office, on: lot)
        }
        // Rooms nobody has yet, to fill the top storey.
        for slot in rooms.count..<((storeys - 1) * OfficePlan.roomsPerStorey) {
            addRoom(OfficePlan.room(forSlot: slot), shirt: nil, to: office, on: lot)
        }
        addFrame(to: office, shell: shell, height: top)
        addRoof(to: office, shell: shell, on: top)
        return office
    }

    // MARK: Parts

    /// The office's outside edges, in the lot's space.
    private struct Shell {
        let left: Float, right: Float, back: Float, front: Float
        var width: Float { right - left }
        var depth: Float { front - back }
        var centreX: Float { (left + right) / 2 }
        var centreZ: Float { (back + front) / 2 }
    }

    /// How thick the floors between storeys are.
    private static let slabDepth: Float = 0.1
    private static let cyan = PlatformColor(red: 0.2, green: 0.95, blue: 1, alpha: 1)
    private static let magenta = PlatformColor(red: 1, green: 0.2, blue: 0.75, alpha: 1)
    private static let steel = PlatformColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)

    /// The ground floor: a polished floor, glass all round with the doorway
    /// open at the front, a lift at the back, a reception desk and planters.
    private static func addLobby(to office: Entity, shell: Shell, on lot: LotComponent) {
        let floor = ModelEntity(
            mesh: .generateBox(width: shell.width, height: 0.01, depth: shell.depth),
            materials: [SimpleMaterial(color: PlatformColor(white: 0.2, alpha: 1), roughness: 0.15, isMetallic: false)]
        )
        floor.position = [shell.centreX, 0.005, shell.centreZ]
        office.addChild(floor)

        let doorway = LotPlan.doorway.map { lot.position(of: Tile(x: $0.x, z: $0.y)).x }
        let door = (left: (doorway.min() ?? 0) - 0.5, right: (doorway.max() ?? 0) + 0.5)
        let ceiling = OfficePlan.storeyHeight - slabDepth
        addGlass(to: office, shell: shell, from: 0, to: ceiling, door: door)

        // The doorway, framed in neon, under a canopy.
        let pink = UnlitMaterial(color: magenta)
        for x in [door.left, door.right] {
            office.addChild(bar(from: [x, 0, shell.front], to: [x, ceiling - 0.15, shell.front], thickness: 0.05, pink))
        }
        let canopy = ModelEntity(mesh: .generateBox(width: door.right - door.left + 0.6, height: 0.05, depth: 0.6), materials: [Buildings.material(steel, roughness: 0.3)])
        canopy.position = [(door.left + door.right) / 2, ceiling - 0.1, shell.front + 0.3]
        office.addChild(canopy)
        office.addChild(bar(from: [door.left - 0.3, ceiling - 0.13, shell.front + 0.6], to: [door.right + 0.3, ceiling - 0.13, shell.front + 0.6], thickness: 0.035, pink))

        // The lift, at the back where the characters step in.
        let lifts = [OfficePlan.lift(forSlot: 0), OfficePlan.lift(forSlot: 1)].map { lot.position(of: Tile(x: $0.x, z: $0.y)).x }
        let liftX = lifts.reduce(0, +) / Float(lifts.count)
        let liftWidth: Float = 1.3, liftHeight: Float = 1.05
        let metal = SimpleMaterial(color: PlatformColor(white: 0.75, alpha: 1), roughness: 0.2, isMetallic: true)
        for side: Float in [-1, 1] {
            let leaf = ModelEntity(mesh: .generateBox(width: liftWidth / 2 - 0.01, height: liftHeight, depth: 0.04), materials: [metal])
            leaf.position = [liftX + side * liftWidth / 4, liftHeight / 2, shell.back + 0.08]
            office.addChild(leaf)
        }
        let blue = UnlitMaterial(color: cyan)
        let z = shell.back + 0.1
        office.addChild(bar(from: [liftX - liftWidth / 2 - 0.04, 0, z], to: [liftX - liftWidth / 2 - 0.04, liftHeight + 0.04, z], thickness: 0.04, blue))
        office.addChild(bar(from: [liftX + liftWidth / 2 + 0.04, 0, z], to: [liftX + liftWidth / 2 + 0.04, liftHeight + 0.04, z], thickness: 0.04, blue))
        office.addChild(bar(from: [liftX - liftWidth / 2 - 0.04, liftHeight + 0.04, z], to: [liftX + liftWidth / 2 + 0.04, liftHeight + 0.04, z], thickness: 0.04, blue))

        // A reception desk on the left, and a planter in each front corner,
        // all on the tiles along the walls that nobody walks on.
        let counter = ModelEntity(mesh: .generateBox(width: 0.45, height: 0.5, depth: 1.6, cornerRadius: 0.05), materials: [Buildings.material(PlatformColor(white: 0.95, alpha: 1), roughness: 0.3)])
        counter.position = [shell.left + 0.5, 0.25, shell.centreZ - 0.2]
        office.addChild(counter)
        office.addChild(bar(from: [shell.left + 0.74, 0.4, shell.centreZ - 0.95], to: [shell.left + 0.74, 0.4, shell.centreZ + 0.55], thickness: 0.03, pink))
        let leaves = SimpleMaterial(color: PlatformColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1), roughness: 1, isMetallic: false)
        for x in [shell.left + 0.5, shell.right - 0.5] {
            let pot = ModelEntity(mesh: .generateCylinder(height: 0.3, radius: 0.2), materials: [Buildings.material(steel, roughness: 0.4)])
            pot.position = [x, 0.15, shell.front - 0.5]
            office.addChild(pot)
            let plant = ModelEntity(mesh: .generateSphere(radius: 0.27), materials: [leaves])
            plant.position = [x, 0.5, shell.front - 0.5]
            office.addChild(plant)
        }
    }

    /// A storey's floor, on which the rooms over it stand.
    private static func addSlab(to office: Entity, shell: Shell, at height: Float) {
        let slab = ModelEntity(
            mesh: .generateBox(width: shell.width + 0.08, height: slabDepth, depth: shell.depth + 0.08),
            materials: [Buildings.material(PlatformColor(white: 0.28, alpha: 1), roughness: 0.4)]
        )
        slab.position = [shell.centreX, height - slabDepth / 2, shell.centreZ]
        office.addChild(slab)
    }

    /// A storey's glass walls, from `bottom` to `top`, with a gap in the
    /// front between `door`'s sides if it has one.
    private static func addGlass(to office: Entity, shell: Shell, from bottom: Float, to top: Float, door: (left: Float, right: Float)?) {
        let height = top - bottom
        let y = bottom + height / 2
        let thickness: Float = 0.03
        var panes: [(width: Float, depth: Float, at: SIMD2<Float>)] = [
            (shell.width, thickness, [shell.centreX, shell.back]),
            (thickness, shell.depth, [shell.left, shell.centreZ]),
            (thickness, shell.depth, [shell.right, shell.centreZ]),
        ]
        if let door {
            panes.append((door.left - shell.left, thickness, [(shell.left + door.left) / 2, shell.front]))
            panes.append((shell.right - door.right, thickness, [(door.right + shell.right) / 2, shell.front]))
        } else {
            panes.append((shell.width, thickness, [shell.centreX, shell.front]))
        }
        for pane in panes {
            let glass = ModelEntity(mesh: .generateBox(width: pane.width, height: height, depth: pane.depth), materials: [glassMaterial])
            glass.position = [pane.at.x, y, pane.at.y]
            // It lets the sun through to the rooms.
            glass.components.set(DynamicLightShadowComponent(castsShadow: false))
            office.addChild(glass)
        }
    }

    /// Glass you can see through, a little blue and shiny.
    private static let glassMaterial: PhysicallyBasedMaterial = {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: PlatformColor(red: 0.6, green: 0.82, blue: 0.95, alpha: 1))
        glass.roughness = 0.05
        glass.metallic = 0.5
        glass.blending = .transparent(opacity: 0.2)
        return glass
    }()

    /// A character's room: a carpet and a wall at the back in its shirt's
    /// colour, a desk by the window with a glowing screen, a strip of neon
    /// along the window and the slab's edge, and a light in its colour. A
    /// room nobody has is grey, with its light off.
    private static func addRoom(_ room: OfficePlan.Room, shirt: PlatformColor?, to office: Entity, on lot: LotComponent) {
        let corner = lot.position(x: room.minX, y: room.minY)
        let far = lot.position(x: room.maxX, y: room.maxY)
        let left = corner.x, right = far.x, back = corner.z, front = far.z
        let width = right - left, depth = front - back
        let middle = (left + right) / 2
        let floor = room.floor
        let ceiling = floor + OfficePlan.storeyHeight - slabDepth
        let tint = shirt ?? PlatformColor(white: 0.55, alpha: 1)

        let carpet = ModelEntity(
            mesh: .generateBox(width: width - 0.1, height: 0.01, depth: depth - 0.1),
            materials: [Buildings.material(tint.mixed(with: PlatformColor(white: 0.12, alpha: 1), by: 0.55), roughness: 0.9)]
        )
        carpet.position = [middle, floor + 0.005, (back + front) / 2]
        office.addChild(carpet)

        let wall = ModelEntity(
            mesh: .generateBox(width: width - 0.12, height: ceiling - floor, depth: 0.04),
            materials: [Buildings.material(shirt == nil ? PlatformColor(white: 0.8, alpha: 1) : tint, roughness: 0.5)]
        )
        wall.position = [middle, (floor + ceiling) / 2, back + 0.05]
        office.addChild(wall)

        // Neon: along the back wall, along the top of the window, and round
        // the outside of the slab under the room. Dim in a room nobody has.
        let neon = UnlitMaterial(color: shirt.map { $0.mixed(with: .white, by: 0.15) } ?? PlatformColor(white: 0.35, alpha: 1))
        office.addChild(bar(from: [left + 0.25, ceiling - 0.2, back + 0.09], to: [right - 0.25, ceiling - 0.2, back + 0.09], thickness: 0.05, neon))
        office.addChild(bar(from: [left + 0.15, ceiling - 0.06, front - 0.08], to: [right - 0.15, ceiling - 0.06, front - 0.08], thickness: 0.04, neon))
        let outer = room.side == 0 ? left - 0.07 : right + 0.07
        let edge = floor - slabDepth / 2
        office.addChild(bar(from: [left - 0.07, edge, front + 0.07], to: [right + 0.07, edge, front + 0.07], thickness: 0.045, neon))
        office.addChild(bar(from: [left - 0.07, edge, back - 0.07], to: [right + 0.07, edge, back - 0.07], thickness: 0.045, neon))
        office.addChild(bar(from: [outer, edge, back - 0.07], to: [outer, edge, front + 0.07], thickness: 0.045, neon))

        // The desk in front of where its character sits, facing the window,
        // with a screen off to one side so you can see the character's face.
        let desk = lot.position(x: room.desk.x, y: room.desk.y) + [0, floor, 0]
        let white = Buildings.material(PlatformColor(white: 0.96, alpha: 1), roughness: 0.3)
        let top = ModelEntity(mesh: .generateBox(width: 1.0, height: 0.04, depth: 0.4, cornerRadius: 0.01), materials: [white])
        top.position = desk + [0, 0.45, 0.42]
        office.addChild(top)
        for side: Float in [-1, 1] {
            let leg = ModelEntity(mesh: .generateBox(width: 0.04, height: 0.43, depth: 0.36), materials: [white])
            leg.position = desk + [side * 0.46, 0.215, 0.42]
            office.addChild(leg)
        }
        let monitor = Entity()
        monitor.position = desk + [0.3, 0.62, 0.5]
        monitor.orientation = simd_quatf(angle: 0.4, axis: [0, 1, 0]) // turned towards its character
        let casing = ModelEntity(mesh: .generateBox(width: 0.36, height: 0.24, depth: 0.025), materials: [Buildings.material(steel, roughness: 0.3)])
        monitor.addChild(casing)
        let screen = ModelEntity(
            mesh: .generateBox(width: 0.32, height: 0.2, depth: 0.005),
            materials: [UnlitMaterial(color: shirt.map { $0.mixed(with: .white, by: 0.5) } ?? PlatformColor(white: 0.1, alpha: 1))]
        )
        screen.position = [0, 0, -0.015] // on the side facing the character
        monitor.addChild(screen)
        office.addChild(monitor)

        // A plant in the back corner, away from the partition.
        let plantX = room.side == 0 ? left + 0.35 : right - 0.35
        let pot = ModelEntity(mesh: .generateCylinder(height: 0.22, radius: 0.13), materials: [white])
        pot.position = [plantX, floor + 0.11, back + 0.4]
        office.addChild(pot)
        let plant = ModelEntity(mesh: .generateSphere(radius: 0.19), materials: [SimpleMaterial(color: PlatformColor(red: 0.2, green: 0.55, blue: 0.3, alpha: 1), roughness: 1, isMetallic: false)])
        plant.position = [plantX, floor + 0.38, back + 0.4]
        office.addChild(plant)

        // Its light, in its character's colour.
        if let shirt {
            let light = PointLight()
            light.light.color = shirt
            light.light.intensity = 5000
            light.light.attenuationRadius = 2.6
            light.position = [middle, ceiling - 0.25, (back + front) / 2 + 0.6]
            office.addChild(light)
        }
    }

    /// Dark steel columns at the corners, with neon running up the front
    /// two, and thin mullions between the panes all the way up.
    private static func addFrame(to office: Entity, shell: Shell, height: Float) {
        let steelMaterial = Buildings.material(steel, roughness: 0.3)
        for x in [shell.left, shell.right] {
            for z in [shell.back, shell.front] {
                let column = ModelEntity(mesh: .generateBox(width: 0.1, height: height, depth: 0.1), materials: [steelMaterial])
                column.position = [x, height / 2, z]
                office.addChild(column)
            }
            let side: Float = x < shell.centreX ? -1 : 1
            office.addChild(bar(from: [x + side * 0.06, 0.1, shell.front + 0.06], to: [x + side * 0.06, height, shell.front + 0.06], thickness: 0.04, UnlitMaterial(color: cyan)))
        }
        let mullion = MeshResource.generateBox(width: 0.03, height: height, depth: 0.03)
        let ground = OfficePlan.storeyHeight
        for step in 1..<Int(shell.width.rounded()) where step != Int(shell.width.rounded()) / 2 {
            let x = shell.left + Float(step)
            for z in [shell.back, shell.front] {
                let bar = ModelEntity(mesh: mullion, materials: [steelMaterial])
                // At the front, from the first floor up, clear of the door.
                let bottom: Float = z == shell.front && abs(x - shell.centreX) < 1.6 ? ground : 0
                bar.scale = [1, (height - bottom) / height, 1]
                bar.position = [x, (bottom + height) / 2, z]
                office.addChild(bar)
            }
        }
        for step in 1..<Int(shell.depth.rounded()) {
            for x in [shell.left, shell.right] {
                let bar = ModelEntity(mesh: mullion, materials: [steelMaterial])
                bar.position = [x, height / 2, shell.back + Float(step)]
                office.addChild(bar)
            }
        }
        // The partition's edge, up the middle of the front and back, from
        // the first floor.
        for z in [shell.back, shell.front] {
            let bar = ModelEntity(mesh: .generateBox(width: 0.06, height: height - ground, depth: 0.06), materials: [steelMaterial])
            bar.position = [shell.centreX, (ground + height) / 2, z]
            office.addChild(bar)
        }
    }

    /// A flat roof with a neon rim, a little plant room, and a sign.
    private static func addRoof(to office: Entity, shell: Shell, on height: Float) {
        let roof = ModelEntity(
            mesh: .generateBox(width: shell.width + 0.2, height: 0.14, depth: shell.depth + 0.2),
            materials: [Buildings.material(PlatformColor(white: 0.22, alpha: 1), roughness: 0.5)]
        )
        roof.position = [shell.centreX, height + 0.07 - slabDepth, shell.centreZ]
        office.addChild(roof)

        let rim = UnlitMaterial(color: cyan)
        let y = height + 0.04
        let l = shell.left - 0.1, r = shell.right + 0.1, b = shell.back - 0.1, f = shell.front + 0.1
        office.addChild(bar(from: [l, y, f], to: [r, y, f], thickness: 0.05, rim))
        office.addChild(bar(from: [l, y, b], to: [r, y, b], thickness: 0.05, rim))
        office.addChild(bar(from: [l, y, b], to: [l, y, f], thickness: 0.05, rim))
        office.addChild(bar(from: [r, y, b], to: [r, y, f], thickness: 0.05, rim))

        let plantRoom = ModelEntity(mesh: .generateBox(width: 1.6, height: 0.5, depth: 1.2, cornerRadius: 0.04), materials: [Buildings.material(PlatformColor(white: 0.7, alpha: 1), roughness: 0.6)])
        plantRoom.position = [shell.centreX + 1.4, height + 0.25, shell.back + 1.2]
        office.addChild(plantRoom)

        let mesh = MeshResource.generateText(
            "a*life",
            extrusionDepth: 0.04,
            font: .boldSystemFont(ofSize: 0.55),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let sign = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: magenta)])
        sign.position = [shell.centreX - mesh.bounds.center.x, height + 0.05, shell.front - 0.3]
        office.addChild(sign)
    }

    /// A straight bar from `start` to `end`, which only differ along one
    /// axis, `thickness` across.
    private static func bar(from start: SIMD3<Float>, to end: SIMD3<Float>, thickness: Float, _ material: some Material) -> ModelEntity {
        let size = simd_abs(end - start) + SIMD3(repeating: thickness)
        let bar = ModelEntity(mesh: .generateBox(width: size.x, height: size.y, depth: size.z), materials: [material])
        bar.position = (start + end) / 2
        return bar
    }
}

extension LotComponent {
    /// The spot `x` across and `y` down a plan of the lot, in tiles, which
    /// needn't be the middle of one, on the floor.
    func position(x: Float, y: Float) -> SIMD3<Float> {
        [
            (x - Float(grid.width - 1) / 2) * tileSize,
            0,
            (y - Float(grid.depth - 1) / 2) * tileSize,
        ]
    }

    /// Where `spot` in the office is, on a floor `height` up.
    func position(of spot: OfficePlan.Spot, height: Float) -> SIMD3<Float> {
        position(x: spot.x, y: spot.y) + [0, height, 0]
    }
}

extension PlatformColor {
    /// This colour, `amount` of the way (0 to 1) to `other`.
    func mixed(with other: PlatformColor, by amount: CGFloat) -> PlatformColor {
        func parts(_ color: PlatformColor) -> (CGFloat, CGFloat, CGFloat) {
            #if os(macOS)
            let color = color.usingColorSpace(.sRGB) ?? color
            #endif
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (red, green, blue)
        }
        let a = parts(self), b = parts(other)
        return PlatformColor(
            red: a.0 + (b.0 - a.0) * amount,
            green: a.1 + (b.1 - a.1) * amount,
            blue: a.2 + (b.2 - a.2) * amount,
            alpha: 1
        )
    }
}
