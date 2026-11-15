import ALifeClient
import CoreGraphics
import RealityKit

/// The Builder's buildings, drawn by their kind: a house has a pitched red
/// roof and a chimney, a restaurant a striped awning, an office bands of
/// windows, a church a spire, a tower is a wind turbine, a barn comes with
/// its farmyard and horses (see `Barn`), and so on. A kind it doesn't know is
/// a plain building. Each has its name over it.
@MainActor
enum Buildings {
    /// A building standing on `width` by `depth` metres, its front (with the
    /// door) towards +z, centred on the origin, on the floor.
    static func make(_ item: LotItem, width: Float, depth: Float) -> Entity {
        let style = Style(kind: item.kind)
        let building = Entity()
        building.name = item.id
        if style.isWindTurbine {
            addWindTurbine(to: building, width: width, depth: depth, label: item.name)
            return building
        }
        if style.isBarn {
            Barn.addFarmyard(to: building, item: item, width: width, depth: depth)
            return building
        }

        // A little room between neighbours.
        let w = max(width - 0.2, 0.6)
        let d = max(depth - 0.2, 0.6)
        let h = style.height

        let walls = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: 0.03), materials: [material(style.walls)])
        walls.position = [0, h / 2, 0]
        building.addChild(walls)

        if style.hasWindowBands {
            // Strips of glass all the way round, one per floor.
            let glass = material(PlatformColor(red: 0.55, green: 0.75, blue: 0.9, alpha: 1), roughness: 0.2)
            var y: Float = 0.55
            while y < h - 0.2 {
                let band = ModelEntity(mesh: .generateBox(width: w + 0.02, height: 0.16, depth: d + 0.02), materials: [glass])
                band.position = [0, y, 0]
                building.addChild(band)
                y += 0.5
            }
        } else {
            // A window either side of the door.
            let glass = material(PlatformColor(red: 0.6, green: 0.8, blue: 0.95, alpha: 1), roughness: 0.2)
            for side: Float in [-1, 1] where w >= 1.4 {
                let window = ModelEntity(mesh: .generateBox(width: min(0.45, w / 5), height: 0.3, depth: 0.03), materials: [glass])
                window.position = [side * w * 0.3, min(0.55, h * 0.55), d / 2 + 0.01]
                building.addChild(window)
            }
        }

        let door = ModelEntity(
            mesh: .generateBox(width: 0.32, height: min(0.55, h * 0.6), depth: 0.04),
            materials: [material(style.door)]
        )
        door.position = [0, min(0.55, h * 0.6) / 2, d / 2 + 0.01]
        building.addChild(door)

        var top = h
        switch style.roof {
        case .flat(let color):
            let roof = ModelEntity(mesh: .generateBox(width: w + 0.1, height: 0.08, depth: d + 0.1), materials: [material(color)])
            roof.position = [0, h + 0.04, 0]
            building.addChild(roof)
            top += 0.08
        case .pitched(let color):
            top += addPitchedRoof(to: building, color: color, width: w, depth: d, on: h)
        }

        if let awning = style.awning {
            addAwning(to: building, color: awning, width: w, depth: d, height: min(0.85, h * 0.75))
        }
        if style.hasChimney {
            let chimney = ModelEntity(mesh: .generateBox(width: 0.18, height: 0.5, depth: 0.18), materials: [material(PlatformColor(red: 0.55, green: 0.3, blue: 0.25, alpha: 1))])
            chimney.position = [w * 0.28, h + 0.35, -d * 0.15]
            building.addChild(chimney)
        }
        if style.hasSpire {
            top = max(top, addSpire(to: building, width: w, depth: d, on: h))
        }
        if style.hasRedCross {
            let red = material(PlatformColor(red: 0.85, green: 0.12, blue: 0.15, alpha: 1))
            for (cw, ch) in [(Float(0.4), Float(0.12)), (Float(0.12), Float(0.4))] {
                let bar = ModelEntity(mesh: .generateBox(width: cw, height: ch, depth: 0.03), materials: [red])
                bar.position = [0, h - 0.35, d / 2 + 0.015]
                building.addChild(bar)
            }
        }

        addLabel(item.name, to: building, at: top + 0.45)
        return building
    }

    // MARK: Kinds

    private enum Roof {
        case flat(PlatformColor)
        /// A gable roof, its ridge along x.
        case pitched(PlatformColor)
    }

    /// How a kind of building looks.
    private struct Style {
        var walls: PlatformColor
        var roof: Roof
        var height: Float
        var door = PlatformColor(red: 0.42, green: 0.27, blue: 0.17, alpha: 1)
        /// A striped awning over the front, in this colour and white.
        var awning: PlatformColor?
        var hasWindowBands = false
        var hasChimney = false
        var hasSpire = false
        var hasRedCross = false
        /// Not a building at all but a wind turbine, drawn by `addWindTurbine`.
        var isWindTurbine = false
        /// A barn with its farmyard and horses, drawn by `Barn`.
        var isBarn = false

        init(walls: PlatformColor, roof: Roof, height: Float) {
            self.walls = walls
            self.roof = roof
            self.height = height
        }

        /// The style of the first kind whose words are in `kind`, or a plain building.
        init(kind: String) {
            func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor { PlatformColor(red: r, green: g, blue: b, alpha: 1) }
            let kind = Kind(kind)
            func `is`(_ words: String...) -> Bool { kind.isOne(of: words) }

            if `is`("restaurant", "bistro", "diner", "pizzeria", "trattoria", "pub", "inn", "tavern") {
                self.init(walls: rgb(0.93, 0.68, 0.5), roof: .flat(rgb(0.4, 0.3, 0.28)), height: 1.2)
                awning = rgb(0.82, 0.15, 0.17)
            } else if `is`("cafe", "café", "coffee", "bakery", "tea", "ice cream", "patisserie") {
                self.init(walls: rgb(0.72, 0.9, 0.82), roof: .flat(rgb(0.38, 0.42, 0.4)), height: 1.0)
                awning = rgb(0.93, 0.45, 0.6)
            } else if `is`("shed", "garage", "workshop", "hut", "cabin", "greenhouse") {
                self.init(walls: rgb(0.6, 0.45, 0.3), roof: .pitched(rgb(0.38, 0.28, 0.2)), height: 0.8)
            } else if `is`("shop", "store", "market", "grocer", "boutique", "kiosk", "pharmacy") {
                self.init(walls: rgb(0.88, 0.88, 0.9), roof: .flat(rgb(0.35, 0.38, 0.45)), height: 1.1)
                awning = rgb(0.2, 0.45, 0.82)
            } else if `is`("tower", "turbine") {
                self.init(walls: rgb(0.95, 0.95, 0.96), roof: .flat(rgb(0.95, 0.95, 0.96)), height: 5)
                isWindTurbine = true
            } else if `is`("skyscraper", "apartment", "flats", "block", "hotel") {
                self.init(walls: rgb(0.68, 0.7, 0.74), roof: .flat(rgb(0.3, 0.32, 0.36)), height: 5)
                hasWindowBands = true
            } else if `is`("office", "bank", "studio", "lab") {
                self.init(walls: rgb(0.5, 0.6, 0.72), roof: .flat(rgb(0.3, 0.33, 0.38)), height: 2.6)
                hasWindowBands = true
            } else if `is`("hospital", "clinic", "surgery") {
                self.init(walls: rgb(0.97, 0.97, 0.97), roof: .flat(rgb(0.6, 0.62, 0.65)), height: 1.9)
                hasRedCross = true
            } else if `is`("church", "chapel", "temple", "cathedral") {
                self.init(walls: rgb(0.95, 0.94, 0.9), roof: .pitched(rgb(0.4, 0.42, 0.48)), height: 1.5)
                hasSpire = true
            } else if `is`("school", "library", "town hall", "museum", "university", "college", "station") {
                self.init(walls: rgb(0.72, 0.36, 0.28), roof: .pitched(rgb(0.33, 0.36, 0.42)), height: 1.4)
                door = rgb(0.2, 0.3, 0.55)
            } else if `is`("barn", "stable", "farm", "farmyard", "ranch", "paddock") {
                self.init(walls: rgb(0.7, 0.18, 0.15), roof: .pitched(rgb(0.3, 0.3, 0.33)), height: 1.5)
                isBarn = true
            } else if `is`("mill") {
                self.init(walls: rgb(0.7, 0.18, 0.15), roof: .pitched(rgb(0.3, 0.3, 0.33)), height: 1.5)
                door = rgb(0.95, 0.93, 0.88)
            } else if `is`("house", "home", "cottage", "bungalow", "villa", "lodge") {
                self.init(walls: rgb(0.96, 0.9, 0.78), roof: .pitched(rgb(0.72, 0.3, 0.24)), height: 1.0)
                hasChimney = true
            } else {
                self.init(walls: rgb(0.85, 0.8, 0.7), roof: .flat(rgb(0.5, 0.5, 0.52)), height: 1.2)
            }
        }
    }

    // MARK: Parts

    /// A gable roof over walls `height` tall, its ridge along x. Returns how
    /// far it rises above the walls.
    private static func addPitchedRoof(to building: Entity, color: PlatformColor, width: Float, depth: Float, on height: Float) -> Float {
        // A box turned 45° about x is a diamond seen from the side: its top
        // half is the roof, and its bottom half is hidden in the walls.
        // Squashing it makes the roof less steep.
        let span = depth + 0.2
        let side = span / Float(2).squareRoot()
        let ridge = ModelEntity(mesh: .generateBox(width: width + 0.2, height: side, depth: side), materials: [material(color)])
        ridge.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
        let squash = min(1, 1.6 / span) // no taller than 0.8
        let roof = Entity()
        roof.scale = [1, squash, 1]
        roof.position = [0, height, 0]
        roof.addChild(ridge)
        building.addChild(roof)
        return span / 2 * squash
    }

    /// A striped awning sloping out over the front.
    private static func addAwning(to building: Entity, color: PlatformColor, width: Float, depth: Float, height: Float) {
        let stripes = max(3, Int(width / 0.3))
        let stripe = width / Float(stripes)
        let white = material(PlatformColor(white: 0.97, alpha: 1))
        let awning = Entity()
        for index in 0..<stripes {
            let part = ModelEntity(
                mesh: .generateBox(width: stripe, height: 0.03, depth: 0.45),
                materials: [index.isMultiple(of: 2) ? material(color) : white]
            )
            part.position = [-width / 2 + stripe * (Float(index) + 0.5), 0, 0]
            awning.addChild(part)
        }
        awning.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0]) // sloping down and out
        awning.position = [0, height, depth / 2 + 0.2]
        building.addChild(awning)
    }

    /// A square tower with a spire on top, at the front. Returns its height.
    private static func addSpire(to building: Entity, width: Float, depth: Float, on height: Float) -> Float {
        let walls = material(PlatformColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1))
        let size = min(0.7, width / 3)
        let towerHeight = height + 0.9
        let tower = ModelEntity(mesh: .generateBox(width: size, height: towerHeight, depth: size), materials: [walls])
        tower.position = [0, towerHeight / 2, depth / 2 - size / 2]
        building.addChild(tower)

        let mesh = MeshResource.generateCone(height: 1.2, radius: size * 0.6)
        let spire = ModelEntity(mesh: mesh, materials: [material(PlatformColor(red: 0.35, green: 0.37, blue: 0.43, alpha: 1))])
        spire.position = [0, towerHeight - mesh.bounds.min.y, depth / 2 - size / 2]
        building.addChild(spire)
        return towerHeight + 1.2
    }

    /// A wind turbine standing in the middle of `width` by `depth` metres: a
    /// slender white tower on a concrete pad, with a nacelle on top, a rotor
    /// of three blades facing the front that turns all the time, and a red
    /// light on top that blinks. `TurbineSystem` does the turning and blinking.
    private static func addWindTurbine(to building: Entity, width: Float, depth: Float, label: String) {
        let white = material(PlatformColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1), roughness: 0.45)
        let w = max(width - 0.2, 0.6)
        let d = max(depth - 0.2, 0.6)

        let pad = ModelEntity(mesh: .generateBox(width: w, height: 0.06, depth: d, cornerRadius: 0.02), materials: [material(PlatformColor(white: 0.72, alpha: 1))])
        pad.position = [0, 0.03, 0]
        building.addChild(pad)

        // The tower, narrowing towards the top.
        let height: Float = 5
        let foot = min(0.24, min(w, d) / 4)
        if let mesh = taperedTube(height: height, bottomRadius: foot, topRadius: foot * 0.5) {
            building.addChild(ModelEntity(mesh: mesh, materials: [white]))
        } else {
            let tower = ModelEntity(mesh: .generateCylinder(height: height, radius: foot * 0.75), materials: [white])
            tower.position = [0, height / 2, 0]
            building.addChild(tower)
        }

        let door = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.3, depth: 0.03), materials: [material(PlatformColor(white: 0.55, alpha: 1))])
        door.position = [0, 0.21, foot * 0.95]
        building.addChild(door)

        // The nacelle, the housing on top, sticking out further at the back.
        let head = Entity()
        head.position = [0, height, 0]
        building.addChild(head)
        let nacelle = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.28, depth: 0.8, cornerRadius: 0.07), materials: [white])
        nacelle.position = [0, 0.12, -0.12]
        head.addChild(nacelle)

        // The rotor: a rounded hub and three blades, a third of a turn apart,
        // starting at a random angle so neighbouring turbines aren't in step.
        let bladeLength: Float = 1.9
        let rotor = Entity()
        rotor.position = [0, 0.12, 0.32]
        rotor.orientation = simd_quatf(angle: .random(in: 0..<(2 * .pi)), axis: [0, 0, 1])
        rotor.components.set(SpinComponent(axis: [0, 0, 1], speed: 1.4))
        head.addChild(rotor)
        let hub = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [white])
        hub.scale = [1, 1, 1.4]
        rotor.addChild(hub)
        for index in 0..<3 {
            let arm = Entity()
            arm.orientation = simd_quatf(angle: Float(index) * 2 * .pi / 3, axis: [0, 0, 1])
            let blade = ModelEntity(mesh: .generateBox(width: 0.14, height: bladeLength, depth: 0.035, cornerRadius: 0.015), materials: [white])
            blade.position = [0, bladeLength / 2 + 0.06, 0]
            blade.orientation = simd_quatf(angle: 0.3, axis: [0, 1, 0]) // pitched into the wind
            arm.addChild(blade)
            rotor.addChild(arm)
        }

        // A small red light on top of the nacelle, unlit so it shines.
        let beacon = Entity()
        beacon.position = [0, 0.12 + 0.14 + 0.04, -0.4]
        beacon.components.set(BlinkComponent(period: 1, onFraction: 0.5))
        let light = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [UnlitMaterial(color: PlatformColor(red: 1, green: 0.05, blue: 0.05, alpha: 1))])
        beacon.addChild(light)
        head.addChild(beacon)

        addLabel(label, to: building, at: height + 0.12 + bladeLength + 0.5)
    }

    /// The side of a tube that narrows from `bottomRadius` on the floor to
    /// `topRadius` at `height`, with no ends: the floor and the nacelle hide them.
    private static func taperedTube(height: Float, bottomRadius: Float, topRadius: Float, segments: Int = 24) -> MeshResource? {
        let slope = (bottomRadius - topRadius) / height
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for index in 0..<segments {
            let angle = Float(index) / Float(segments) * 2 * .pi
            let outward = SIMD3<Float>(sin(angle), 0, cos(angle))
            let normal = simd_normalize(outward + [0, slope, 0])
            positions += [outward * bottomRadius, outward * topRadius + [0, height, 0]]
            normals += [normal, normal]
        }
        var indices: [UInt32] = []
        for index in 0..<segments {
            let bottom = UInt32(index * 2), top = bottom + 1
            let nextBottom = UInt32((index + 1) % segments * 2), nextTop = nextBottom + 1
            indices += [bottom, nextBottom, top, top, nextBottom, nextTop]
        }
        var descriptor = MeshDescriptor(name: "taperedTube")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Its name, floating over it and facing the camera.
    static func addLabel(_ name: String, to building: Entity, at height: Float) {
        let mesh = MeshResource.generateText(
            String(name.prefix(30)),
            extrusionDepth: 0.01,
            font: .boldSystemFont(ofSize: 0.32),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        text.position = [-mesh.bounds.center.x, 0, 0] // text meshes start at their left edge

        let label = Entity()
        label.name = "Label"
        label.position = [0, height, 0]
        label.components.set(BillboardComponent())
        label.addChild(text)
        building.addChild(label)
    }

    static func material(_ color: PlatformColor, roughness: Float = 0.75) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: false)
    }
}

/// The kind of something on the lot, such as `apple tree` or `bookshop`, to
/// tell what to draw.
struct Kind {
    private let text: String
    private let words: [Substring]

    init(_ text: String) {
        self.text = text.lowercased()
        words = self.text.split { !$0.isLetter }
    }

    /// Whether it is one of these: one of its words is one of them, with or
    /// without an s, or ends in one, as a bookshop is a shop. Two words, such
    /// as `town hall`, have to be in it as they are.
    func isOne(of names: [String]) -> Bool {
        names.contains { name in
            if name.contains(" ") { return text.contains(name) }
            return words.contains { $0 == name || $0 == name + "s" || ($0.count > name.count + 2 && name.count >= 4 && $0.hasSuffix(name)) }
        }
    }
}
