import ALifeClient
import RealityKit

/// The Builder's barn, which comes with its farmyard: a red barn with big
/// white-braced doors and a trough in front, a fenced pen of chickens and
/// goats beside it, and a round lunging ring with a sand floor, all on the
/// barn's own tiles. A few horses come with it, standing at the trough to
/// start with. They are the barn's children, so they go when it goes.
/// `BarnSystem` moves the horses and the animals in the pen.
@MainActor
enum Barn {
    /// How a barn's columns of tiles are shared out, from left to right: the
    /// barn itself, the pen and the lunging ring. A small barn has no room
    /// for the ring, or for the pen either.
    struct Layout: Equatable {
        var barn: Int
        var pen: Int
        var ring: Int

        init(width: Int, depth: Int) {
            guard width >= 6, depth >= 3 else {
                (barn, pen, ring) = (width, 0, 0)
                return
            }
            barn = max(3, Int((Float(width) * 0.4).rounded()))
            let rest = width - barn
            // The ring is round, so no wider than the barn is deep, and it
            // leaves at least two columns for the pen.
            ring = rest >= 5 ? min(depth, rest - 2) : 0
            if ring < 3 { ring = 0 }
            pen = rest - ring
            if pen < 2 {
                barn += pen
                pen = 0
            }
        }
    }

    /// Draws the barn and its farmyard on `width` by `depth` metres of `building`,
    /// and puts its animals in it.
    static func addFarmyard(to building: Entity, item: LotItem, width: Float, depth: Float) {
        let area = item.area
        let tileSize = width / Float(max(area.width, 1))
        let layout = Layout(width: area.width, depth: area.depth)
        let left = -width / 2
        let hasTrough = area.depth >= 3

        // The barn, at the back of its columns, with room for the trough in front.
        let barnColumns = Float(layout.barn) * tileSize
        let front: Float = hasTrough ? 0.9 : 0
        let w = max(barnColumns - 0.2, 0.6)
        let d = max(depth - 0.2 - front, 0.6)
        let centre = SIMD3<Float>(left + barnColumns / 2, 0, -depth / 2 + 0.1 + d / 2)
        let top = addBarn(to: building, at: centre, width: w, depth: d)
        if hasTrough {
            addTrough(to: building, at: [centre.x, 0, depth / 2 - 0.18], length: w * 0.85)
        }

        // The pen next to it.
        var x = left + barnColumns
        if layout.pen > 0 {
            let penWidth = Float(layout.pen) * tileSize
            addPen(to: building, from: [x + 0.12, -depth / 2 + 0.12], to: [x + penWidth - 0.12, depth / 2 - 0.12])
            x += penWidth
        }

        // The lunging ring, at the front of its columns so its gate opens onto the lot.
        var ring: HorseComponent.Ring?
        if layout.ring > 0 {
            let diameter = Float(layout.ring) * tileSize
            let ringCentre = SIMD3<Float>(x + diameter / 2, 0, depth / 2 - diameter / 2)
            let radius = diameter / 2 - 0.12
            addRing(to: building, at: ringCentre, radius: radius)
            let gate = Tile(x: area.x + layout.barn + layout.pen + layout.ring / 2, z: area.y + area.depth)
            ring = HorseComponent.Ring(centre: ringCentre, radius: radius, gate: gate)
        }

        // Its horses, each with a place of its own at the trough, on the
        // tiles in front of the barn.
        let horses = area.width * area.depth >= 30 ? 3 : 2
        let coats: [PlatformColor] = [
            PlatformColor(red: 0.55, green: 0.3, blue: 0.15, alpha: 1), // chestnut
            PlatformColor(red: 0.32, green: 0.2, blue: 0.13, alpha: 1), // bay
            PlatformColor(red: 0.88, green: 0.87, blue: 0.84, alpha: 1), // grey
        ]
        for index in 0..<horses {
            let column = min(layout.barn - 1, (2 * index + 1) * layout.barn / (2 * horses))
            let feedTile = Tile(x: area.x + column, z: area.y + area.depth)
            let horse = makeHorse(coat: coats[index % coats.count])
            horse.position = [left + (Float(column) + 0.5) * tileSize, 0, depth / 2 + tileSize / 2]
            horse.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) // facing the trough
            horse.components.set(WalkComponent())
            horse.components.set(HorseComponent(feedTile: feedTile, ring: ring))
            building.addChild(horse)
        }

        Buildings.addLabel(item.name, to: building, at: top + 0.45)
    }

    // MARK: The farmyard

    /// A red barn with a gable roof whose ridge runs from front to back, big
    /// double doors and a hayloft door. Returns its height.
    private static func addBarn(to building: Entity, at centre: SIMD3<Float>, width: Float, depth: Float) -> Float {
        let red = Buildings.material(PlatformColor(red: 0.7, green: 0.16, blue: 0.13, alpha: 1))
        let darkRed = Buildings.material(PlatformColor(red: 0.5, green: 0.1, blue: 0.08, alpha: 1))
        let white = Buildings.material(PlatformColor(red: 0.96, green: 0.94, blue: 0.9, alpha: 1))
        let roof = Buildings.material(PlatformColor(red: 0.3, green: 0.3, blue: 0.33, alpha: 1))
        let height: Float = 1.3

        let walls = ModelEntity(mesh: .generateBox(width: width, height: height, depth: depth, cornerRadius: 0.02), materials: [red])
        walls.position = centre + [0, height / 2, 0]
        building.addChild(walls)

        // The gable ends: a box turned 45° about z is a diamond seen from the
        // front. Squashed, its top half is the gable, in the walls' red.
        let half = width / 2
        let rise = min(half * 0.9, 0.9)
        let side = width / Float(2).squareRoot()
        let gable = ModelEntity(mesh: .generateBox(width: side, height: side, depth: depth), materials: [red])
        gable.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
        let squashed = Entity()
        squashed.scale = [1, rise / half, 1]
        squashed.position = centre + [0, height, 0]
        squashed.addChild(gable)
        building.addChild(squashed)

        // The two slopes of the roof, overhanging a little.
        let slope = (half * half + rise * rise).squareRoot()
        let pitch = atan2(rise, half)
        for side: Float in [-1, 1] {
            let panel = ModelEntity(mesh: .generateBox(width: slope + 0.14, height: 0.06, depth: depth + 0.2), materials: [roof])
            panel.position = centre + [side * half / 2, height + rise / 2 + 0.03, 0]
            panel.orientation = simd_quatf(angle: -side * pitch, axis: [0, 0, 1])
            building.addChild(panel)
        }

        // Big double doors in a white frame, each with a white cross brace.
        let face = centre.z + depth / 2
        let doorWidth = min(0.9, width * 0.55)
        let doorHeight = min(1.0, height * 0.78)
        let frame = ModelEntity(mesh: .generateBox(width: doorWidth + 0.1, height: doorHeight + 0.05, depth: 0.02), materials: [white])
        frame.position = [centre.x, (doorHeight + 0.05) / 2, face + 0.01]
        building.addChild(frame)
        let leafWidth = doorWidth / 2 - 0.03
        for side: Float in [-1, 1] {
            let leafCentre = SIMD3<Float>(centre.x + side * doorWidth / 4, doorHeight / 2, face + 0.025)
            let leaf = ModelEntity(mesh: .generateBox(width: leafWidth, height: doorHeight - 0.04, depth: 0.02), materials: [darkRed])
            leaf.position = leafCentre
            building.addChild(leaf)
            let diagonal = (leafWidth * leafWidth + doorHeight * doorHeight).squareRoot() - 0.06
            for slant: Float in [-1, 1] {
                let brace = ModelEntity(mesh: .generateBox(width: 0.035, height: diagonal, depth: 0.01), materials: [white])
                brace.position = leafCentre + [0, 0, 0.015]
                brace.orientation = simd_quatf(angle: slant * atan2(leafWidth, doorHeight), axis: [0, 0, 1])
                building.addChild(brace)
            }
        }

        // A hayloft door up in the gable.
        let loft = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.28, depth: 0.02), materials: [white])
        loft.position = [centre.x, height + rise * 0.3, face + 0.01]
        building.addChild(loft)

        // White trim up the front corners.
        for side: Float in [-1, 1] {
            let trim = ModelEntity(mesh: .generateBox(width: 0.06, height: height, depth: 0.02), materials: [white])
            trim.position = [centre.x + side * (half - 0.03), height / 2, face + 0.01]
            building.addChild(trim)
        }
        return height + rise
    }

    /// A long wooden trough full of hay, where the horses come to feed.
    private static func addTrough(to building: Entity, at position: SIMD3<Float>, length: Float) {
        let wood = Buildings.material(PlatformColor(red: 0.5, green: 0.34, blue: 0.2, alpha: 1))
        let hay = Buildings.material(PlatformColor(red: 0.9, green: 0.78, blue: 0.4, alpha: 1), roughness: 1)
        let trough = ModelEntity(mesh: .generateBox(width: length, height: 0.22, depth: 0.28, cornerRadius: 0.03), materials: [wood])
        trough.position = position + [0, 0.11, 0]
        building.addChild(trough)
        let filling = ModelEntity(mesh: .generateBox(width: length - 0.08, height: 0.04, depth: 0.2, cornerRadius: 0.02), materials: [hay])
        filling.position = position + [0, 0.22, 0]
        building.addChild(filling)
    }

    /// A fenced pen on a dirt floor between the corners `low` and `high`,
    /// with chickens pecking and goats grazing in it.
    private static func addPen(to building: Entity, from low: SIMD2<Float>, to high: SIMD2<Float>) {
        let dirt = ModelEntity(
            mesh: .generatePlane(width: high.x - low.x, depth: high.y - low.y),
            materials: [Buildings.material(PlatformColor(red: 0.6, green: 0.48, blue: 0.33, alpha: 1), roughness: 1)]
        )
        dirt.position = [(low.x + high.x) / 2, 0.006, (low.y + high.y) / 2]
        building.addChild(dirt)

        let corners: [SIMD2<Float>] = [low, [high.x, low.y], high, [low.x, high.y]]
        for index in corners.indices {
            addFence(to: building, from: corners[index], to: corners[(index + 1) % corners.count])
        }

        // Inside the fence, with a little room so nobody stands in it.
        let inner = (low: low + 0.22, high: high - 0.22)
        let space = (high.x - low.x) * (high.y - low.y)
        let animals: [PenAnimalComponent.Kind] = Array(repeating: .chicken, count: space >= 6 ? 4 : 3) + Array(repeating: .goat, count: space >= 4 ? 2 : 1)
        for kind in animals {
            let animal = kind == .chicken ? makeChicken() : makeGoat()
            let spot = SIMD2<Float>(.random(in: inner.low.x...max(inner.low.x, inner.high.x)), .random(in: inner.low.y...max(inner.low.y, inner.high.y)))
            animal.position = [spot.x, 0, spot.y]
            animal.orientation = simd_quatf(angle: .random(in: 0..<(2 * .pi)), axis: [0, 1, 0])
            animal.components.set(PenAnimalComponent(kind: kind, low: inner.low, high: inner.high))
            building.addChild(animal)
        }
    }

    /// A round paddock with a sand floor and a fence round it, open at the
    /// front for a gate.
    private static func addRing(to building: Entity, at centre: SIMD3<Float>, radius: Float) {
        let sand = ModelEntity(
            mesh: .generateCylinder(height: 0.02, radius: radius),
            materials: [Buildings.material(PlatformColor(red: 0.89, green: 0.8, blue: 0.6, alpha: 1), roughness: 1)]
        )
        sand.position = centre + [0, 0.01, 0]
        building.addChild(sand)

        // Posts all the way round, and rails between them but for the gate,
        // which faces the front (+z, an angle of 0).
        let posts = max(12, Int(2 * .pi * radius / 0.5))
        let gate = 0.4 / radius
        func point(_ angle: Float) -> SIMD2<Float> { [centre.x + sin(angle) * radius, centre.z + cos(angle) * radius] }
        for index in 0..<posts {
            let angle = gate + Float(index) / Float(posts) * (2 * .pi - 2 * gate)
            let next = gate + Float(index + 1) / Float(posts) * (2 * .pi - 2 * gate)
            addFence(to: building, from: point(angle), to: point(next), endPost: index == posts - 1)
        }
    }

    /// A stretch of wooden fence on the floor from `start` to `end`: a post
    /// at the start, and at the end too if `endPost`, and two rails.
    private static func addFence(to building: Entity, from start: SIMD2<Float>, to end: SIMD2<Float>, endPost: Bool = true) {
        let wood = Buildings.material(PlatformColor(red: 0.93, green: 0.9, blue: 0.84, alpha: 1))
        let length = simd_length(end - start)
        guard length > 0.01 else { return }
        let direction = (end - start) / length

        // Posts no more than half a metre apart.
        let gaps = max(1, Int((length / 0.5).rounded(.up)))
        for index in 0...gaps where index < gaps || endPost {
            let at = start + direction * (length * Float(index) / Float(gaps))
            let post = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.36, depth: 0.05), materials: [wood])
            post.position = [at.x, 0.18, at.y]
            building.addChild(post)
        }
        let middle = (start + end) / 2
        let heading = simd_quatf(angle: atan2(direction.x, direction.y), axis: [0, 1, 0])
        for y: Float in [0.14, 0.3] {
            let rail = ModelEntity(mesh: .generateBox(width: 0.025, height: 0.04, depth: length), materials: [wood])
            rail.position = [middle.x, y, middle.y]
            rail.orientation = heading
            building.addChild(rail)
        }
    }

    // MARK: Animals

    /// A horse about as tall as a character, facing +z. Its body is in
    /// "Gait", which bobs as it runs, with its legs ("FrontLeg" and
    /// "BackLeg"), which swing from the hip, and its neck ("Neck"), which
    /// lowers its head to feed.
    private static func makeHorse(coat: PlatformColor) -> Entity {
        let coat = Buildings.material(coat, roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.12, green: 0.1, blue: 0.09, alpha: 1), roughness: 0.7)

        let horse = Entity()
        horse.name = "Horse"
        let gait = Entity()
        gait.name = "Gait"
        horse.addChild(gait)

        let body = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.3, depth: 0.8, cornerRadius: 0.11), materials: [coat])
        body.position = [0, 0.68, 0]
        gait.addChild(body)

        for z: Float in [0.28, -0.28] {
            for x: Float in [-0.09, 0.09] {
                let hip = Entity()
                hip.name = z > 0 ? "FrontLeg" : "BackLeg"
                hip.position = [x, 0.55, z]
                let leg = ModelEntity(mesh: .generateBox(width: 0.075, height: 0.44, depth: 0.075, cornerRadius: 0.02), materials: [coat])
                leg.position = [0, -0.25, 0]
                hip.addChild(leg)
                let hoof = ModelEntity(mesh: .generateBox(width: 0.085, height: 0.07, depth: 0.09, cornerRadius: 0.02), materials: [dark])
                hoof.position = [0, -0.5, 0.005]
                hip.addChild(hoof)
                gait.addChild(hip)
            }
        }

        // The neck rises forwards from the shoulders; the head is on its end.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.72, 0.32]
        gait.addChild(neck)
        let lean: Float = 0.5
        let neckPiece = ModelEntity(mesh: .generateBox(width: 0.15, height: 0.46, depth: 0.2, cornerRadius: 0.06), materials: [coat])
        neckPiece.position = [0, 0.23 * cos(lean), 0.23 * sin(lean)]
        neckPiece.orientation = simd_quatf(angle: lean, axis: [1, 0, 0])
        neck.addChild(neckPiece)
        let mane = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.46, depth: 0.05, cornerRadius: 0.02), materials: [dark])
        mane.position = [0, 0.02, -0.11]
        neckPiece.addChild(mane)

        let head = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.15, depth: 0.34, cornerRadius: 0.05), materials: [coat])
        head.position = [0, 0.42, 0.3]
        head.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0]) // nose down a little
        neck.addChild(head)
        for x: Float in [-0.045, 0.045] {
            let ear = ModelEntity(mesh: .generateBox(width: 0.035, height: 0.08, depth: 0.03), materials: [coat])
            ear.position = [x, 0.51, 0.17]
            neck.addChild(ear)
        }

        let tail = ModelEntity(mesh: .generateBox(width: 0.06, height: 0.36, depth: 0.06, cornerRadius: 0.02), materials: [dark])
        tail.position = [0, 0.62, -0.47]
        tail.orientation = simd_quatf(angle: -0.4, axis: [1, 0, 0]) // hanging out behind
        gait.addChild(tail)

        return horse
    }

    /// A little white hen, facing +z, whose head ("Head") bobs down to peck.
    private static func makeChicken() -> Entity {
        let feathers = Buildings.material(PlatformColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1), roughness: 0.9)
        let yellow = Buildings.material(PlatformColor(red: 0.95, green: 0.7, blue: 0.15, alpha: 1))
        let red = Buildings.material(PlatformColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1))

        let chicken = Entity()
        chicken.name = "Chicken"
        for x: Float in [-0.025, 0.025] {
            let leg = ModelEntity(mesh: .generateBox(width: 0.015, height: 0.06, depth: 0.015), materials: [yellow])
            leg.position = [x, 0.03, 0]
            chicken.addChild(leg)
        }
        let body = ModelEntity(mesh: .generateSphere(radius: 0.065), materials: [feathers])
        body.scale = [1, 0.95, 1.3]
        body.position = [0, 0.11, 0]
        chicken.addChild(body)
        let tail = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.07, depth: 0.03, cornerRadius: 0.01), materials: [feathers])
        tail.position = [0, 0.16, -0.08]
        tail.orientation = simd_quatf(angle: -0.4, axis: [1, 0, 0])
        chicken.addChild(tail)

        let head = Entity()
        head.name = "Head"
        head.position = [0, 0.14, 0.06]
        chicken.addChild(head)
        let skull = ModelEntity(mesh: .generateSphere(radius: 0.038), materials: [feathers])
        skull.position = [0, 0.04, 0.02]
        head.addChild(skull)
        let beak = ModelEntity(mesh: .generateBox(width: 0.02, height: 0.018, depth: 0.035), materials: [yellow])
        beak.position = [0, 0.035, 0.065]
        head.addChild(beak)
        let comb = ModelEntity(mesh: .generateBox(width: 0.012, height: 0.03, depth: 0.04, cornerRadius: 0.006), materials: [red])
        comb.position = [0, 0.085, 0.02]
        head.addChild(comb)
        return chicken
    }

    /// A small goat with horns and a beard, facing +z, whose head ("Head")
    /// lowers to graze.
    private static func makeGoat() -> Entity {
        let coat = Buildings.material(PlatformColor(red: 0.85, green: 0.8, blue: 0.72, alpha: 1), roughness: 0.9)
        let dark = Buildings.material(PlatformColor(red: 0.3, green: 0.26, blue: 0.22, alpha: 1), roughness: 0.7)

        let goat = Entity()
        goat.name = "Goat"
        for z: Float in [-0.12, 0.12] {
            for x: Float in [-0.06, 0.06] {
                let leg = ModelEntity(mesh: .generateBox(width: 0.045, height: 0.22, depth: 0.045, cornerRadius: 0.01), materials: [coat])
                leg.position = [x, 0.11, z]
                goat.addChild(leg)
            }
        }
        let body = ModelEntity(mesh: .generateBox(width: 0.19, height: 0.18, depth: 0.38, cornerRadius: 0.07), materials: [coat])
        body.position = [0, 0.3, 0]
        goat.addChild(body)
        let tail = ModelEntity(mesh: .generateBox(width: 0.03, height: 0.07, depth: 0.03), materials: [coat])
        tail.position = [0, 0.4, -0.19]
        tail.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
        goat.addChild(tail)

        let head = Entity()
        head.name = "Head"
        head.position = [0, 0.36, 0.17]
        goat.addChild(head)
        let skull = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.11, depth: 0.17, cornerRadius: 0.04), materials: [coat])
        skull.position = [0, 0.05, 0.08]
        head.addChild(skull)
        for x: Float in [-0.03, 0.03] {
            let horn = ModelEntity(mesh: .generateBox(width: 0.02, height: 0.09, depth: 0.02, cornerRadius: 0.008), materials: [dark])
            horn.position = [x, 0.13, 0.03]
            horn.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0]) // swept back
            head.addChild(horn)
        }
        let beard = ModelEntity(mesh: .generateBox(width: 0.03, height: 0.06, depth: 0.025), materials: [coat])
        beard.position = [0, -0.03, 0.13]
        head.addChild(beard)
        return goat
    }
}
