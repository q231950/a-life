import ALifeClient
import CoreGraphics
import RealityKit

/// The Conservationist's beds of plants, drawn by their kind: flowers in
/// their colour (roses, tulips, daisies, tall sunflowers, lavender), trees
/// (oak, birch, apple, cherry, maple, pine, palm), bushes, hedges, grass,
/// and vegetables
/// (carrots, lettuces, cabbages, tomatoes, pumpkins). One plant or clump
/// grows on each tile of a bed; a kind it doesn't know is a little green
/// plant.
@MainActor
enum Plants {
    /// A bed of `item`'s plants, one on each of `tiles`, positions relative to
    /// the bed's centre. `tileSize` is how big a tile is.
    static func make(_ item: LotItem, tiles: [(x: Int, y: Int, position: SIMD3<Float>)], tileSize: Float) -> Entity {
        let shape = Shape(kind: item.kind)
        let bed = Entity()
        bed.name = item.id

        if shape.growsInSoil {
            let width = Float(item.width) * tileSize - 0.1
            let depth = Float(item.depth) * tileSize - 0.1
            let soil = ModelEntity(mesh: .generateBox(width: width, height: 0.04, depth: depth, cornerRadius: 0.02), materials: [material(soilColor)])
            soil.position = [0, 0.02, 0]
            bed.addChild(soil)
        }

        let color = item.color.flatMap(PlatformColor.init(hex:))
        for tile in tiles {
            var random = Jitter(x: tile.x, y: tile.y)
            let plant = makePlant(shape, color: color, random: &random)
            plant.position = tile.position
            bed.addChild(plant)
        }
        return bed
    }

    /// Whether characters can walk through it, as they can through grass.
    static func isWalkable(_ kind: String) -> Bool {
        if case .grass = Shape(kind: kind) { return true }
        return false
    }

    // MARK: Kinds

    enum Vegetable {
        case carrot, lettuce, cabbage, tomato, pumpkin, potato, other
    }

    /// What a kind of plant looks like, on the lot and in its picture in the
    /// Conservationist's conversation (`KindPicture`).
    enum Shape {
        case flower(PlatformColor, Flower)
        case tree(crown: PlatformColor, trunk: PlatformColor, fruit: PlatformColor?)
        case conifer
        case palm
        case bush(berries: PlatformColor?)
        case hedge
        case grass
        case vegetable(Vegetable)
        /// Anything else.
        case plant

        enum Flower {
            case round, cup, daisy, tall, spike
        }

        /// The shape of the first kind whose words are in `kind`, or a little green plant.
        init(kind: String) {
            self.init(LotItem.Plant(kind: kind), blueberries: kind.lowercased().contains("blueberr"))
        }

        /// What `plant` looks like, or a little green plant for `nil`. A
        /// berry bush has blue berries if they are `blueberries`, and red ones
        /// otherwise.
        init(_ plant: LotItem.Plant?, blueberries: Bool = false) {
            func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor { PlatformColor(red: r, green: g, blue: b, alpha: 1) }
            switch plant {
            case .grass: self = .grass
            case .hedge: self = .hedge
            case .carrot: self = .vegetable(.carrot)
            case .lettuce: self = .vegetable(.lettuce)
            case .cabbage: self = .vegetable(.cabbage)
            case .tomato: self = .vegetable(.tomato)
            case .pumpkin: self = .vegetable(.pumpkin)
            case .potato: self = .vegetable(.potato)
            case .vegetable: self = .vegetable(.other)
            case .sunflower: self = .flower(rgb(0.98, 0.8, 0.1), .tall)
            case .lavender: self = .flower(rgb(0.6, 0.45, 0.85), .spike)
            case .daisy: self = .flower(rgb(0.98, 0.98, 0.95), .daisy)
            case .tulip: self = .flower(rgb(0.95, 0.35, 0.5), .cup)
            case .rose: self = .flower(rgb(0.84, 0.15, 0.24), .round)
            case .poppy: self = .flower(rgb(0.95, 0.35, 0.15), .round)
            case .flower: self = .flower(rgb(0.93, 0.5, 0.75), .round)
            case .pine: self = .conifer
            case .palm: self = .palm
            case .birch: self = .tree(crown: rgb(0.55, 0.78, 0.35), trunk: rgb(0.93, 0.92, 0.88), fruit: nil)
            case .apple: self = .tree(crown: rgb(0.3, 0.6, 0.25), trunk: rgb(0.45, 0.3, 0.2), fruit: rgb(0.85, 0.12, 0.12))
            case .orange: self = .tree(crown: rgb(0.25, 0.55, 0.25), trunk: rgb(0.45, 0.3, 0.2), fruit: rgb(0.98, 0.6, 0.1))
            case .cherry: self = .tree(crown: rgb(0.97, 0.7, 0.82), trunk: rgb(0.38, 0.25, 0.2), fruit: nil)
            case .maple: self = .tree(crown: rgb(0.88, 0.38, 0.15), trunk: rgb(0.42, 0.28, 0.2), fruit: nil)
            case .oak: self = .tree(crown: rgb(0.2, 0.48, 0.2), trunk: rgb(0.42, 0.28, 0.18), fruit: nil)
            case .berry: self = .bush(berries: blueberries ? rgb(0.3, 0.35, 0.8) : rgb(0.8, 0.1, 0.2))
            case .bush: self = .bush(berries: nil)
            case nil: self = .plant
            }
        }

        /// Flowers and vegetables grow in a bed of soil.
        var growsInSoil: Bool {
            switch self {
            case .flower, .vegetable: return true
            default: return false
            }
        }
    }

    // MARK: Plants

    private static let soilColor = PlatformColor(red: 0.42, green: 0.3, blue: 0.2, alpha: 1)
    private static let leafColor = PlatformColor(red: 0.3, green: 0.6, blue: 0.25, alpha: 1)
    private static let stemColor = PlatformColor(red: 0.25, green: 0.5, blue: 0.2, alpha: 1)

    /// One plant or clump, on the centre of its tile.
    private static func makePlant(_ shape: Shape, color: PlatformColor?, random: inout Jitter) -> Entity {
        let plant = Entity()
        func add(_ mesh: MeshResource, _ color: PlatformColor, at position: SIMD3<Float>, roughness: Float = 0.9) {
            let part = ModelEntity(mesh: mesh, materials: [material(color, roughness: roughness)])
            part.position = position
            plant.addChild(part)
        }

        switch shape {
        case .flower(let usual, let flower):
            let blossom = color ?? usual
            // A few to a tile, not quite in a row.
            let spots: [SIMD2<Float>] = flower == .tall ? [[0, 0]] : [[-0.2, -0.18], [0.2, -0.1], [-0.05, 0.2]]
            for spot in spots {
                let at = SIMD3<Float>(spot.x + random.next(0.08), 0, spot.y + random.next(0.08))
                switch flower {
                case .tall:
                    add(.generateBox(width: 0.05, height: 0.9, depth: 0.05), stemColor, at: at + [0, 0.45, 0])
                    add(.generateCylinder(height: 0.06, radius: 0.2), blossom, at: at + [0, 0.92, 0.04])
                    add(.generateCylinder(height: 0.08, radius: 0.09), PlatformColor(red: 0.4, green: 0.25, blue: 0.1, alpha: 1), at: at + [0, 0.94, 0.05])
                case .spike:
                    add(.generateBox(width: 0.03, height: 0.2, depth: 0.03), stemColor, at: at + [0, 0.1, 0])
                    add(.generateBox(width: 0.07, height: 0.24, depth: 0.07, cornerRadius: 0.03), blossom, at: at + [0, 0.3, 0])
                case .daisy:
                    add(.generateBox(width: 0.03, height: 0.2, depth: 0.03), stemColor, at: at + [0, 0.1, 0])
                    add(.generateCylinder(height: 0.03, radius: 0.1), blossom, at: at + [0, 0.22, 0])
                    add(.generateSphere(radius: 0.04), PlatformColor(red: 0.98, green: 0.8, blue: 0.1, alpha: 1), at: at + [0, 0.24, 0])
                case .cup:
                    add(.generateBox(width: 0.03, height: 0.26, depth: 0.03), stemColor, at: at + [0, 0.13, 0])
                    add(.generateBox(width: 0.11, height: 0.14, depth: 0.11, cornerRadius: 0.05), blossom, at: at + [0, 0.3, 0])
                case .round:
                    add(.generateBox(width: 0.03, height: 0.22, depth: 0.03), stemColor, at: at + [0, 0.11, 0])
                    add(.generateSphere(radius: 0.06), leafColor, at: at + [0.05, 0.1, 0])
                    add(.generateSphere(radius: 0.09), blossom, at: at + [0, 0.26, 0])
                }
            }

        case .tree(let crown, let trunk, let fruit):
            let size = 1 + random.next(0.15)
            add(.generateBox(width: 0.16, height: 0.9 * size, depth: 0.16), trunk, at: [0, 0.45 * size, 0])
            add(.generateSphere(radius: 0.55 * size), crown, at: [0, 1.15 * size, 0])
            add(.generateSphere(radius: 0.38 * size), crown, at: [0.3, 0.95 * size, 0.15])
            add(.generateSphere(radius: 0.36 * size), crown, at: [-0.28, 1.0 * size, -0.12])
            if let fruit {
                for angle in stride(from: Float(0.3), to: 2 * .pi, by: 1.1) {
                    add(.generateSphere(radius: 0.07), fruit, at: [cos(angle) * 0.5 * size, 1.05 * size, sin(angle) * 0.5 * size], roughness: 0.4)
                }
            }

        case .conifer:
            let size = 1 + random.next(0.15)
            let green = PlatformColor(red: 0.13, green: 0.38, blue: 0.22, alpha: 1)
            add(.generateBox(width: 0.14, height: 0.4, depth: 0.14), PlatformColor(red: 0.4, green: 0.27, blue: 0.18, alpha: 1), at: [0, 0.2, 0])
            for (level, radius) in [(Float(0.35), Float(0.5)), (0.85, 0.38), (1.3, 0.25)] {
                let mesh = MeshResource.generateCone(height: 0.7 * size, radius: radius * size)
                add(mesh, green, at: [0, level * size - mesh.bounds.min.y, 0])
            }

        case .palm:
            let trunk = PlatformColor(red: 0.6, green: 0.45, blue: 0.3, alpha: 1)
            let fronds = PlatformColor(red: 0.25, green: 0.62, blue: 0.25, alpha: 1)
            // A trunk leaning a little, in three pieces.
            for piece in 0..<3 {
                add(.generateCylinder(height: 0.55, radius: 0.08 - Float(piece) * 0.01), trunk, at: [Float(piece) * 0.05, 0.28 + Float(piece) * 0.52, 0])
            }
            for index in 0..<6 {
                let angle = Float(index) * .pi / 3 + random.next(0.2)
                let frond = ModelEntity(mesh: .generateBox(width: 0.7, height: 0.03, depth: 0.16, cornerRadius: 0.015), materials: [material(fronds)])
                frond.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * simd_quatf(angle: -0.35, axis: [0, 0, 1])
                frond.position = [0.1 + cos(angle) * 0.3, 1.55, -sin(angle) * 0.3]
                plant.addChild(frond)
            }
            add(.generateSphere(radius: 0.08), PlatformColor(red: 0.45, green: 0.3, blue: 0.15, alpha: 1), at: [0.12, 1.5, 0])

        case .bush(let berries):
            let green = PlatformColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1)
            let size = 1 + random.next(0.15)
            add(.generateSphere(radius: 0.38 * size), green, at: [0, 0.32 * size, 0])
            add(.generateSphere(radius: 0.25 * size), green, at: [0.2, 0.25 * size, 0.1])
            if let berries {
                for angle in stride(from: Float(0.2), to: 2 * .pi, by: 0.9) {
                    add(.generateSphere(radius: 0.045), berries, at: [cos(angle) * 0.34 * size, 0.38 * size, sin(angle) * 0.34 * size], roughness: 0.4)
                }
            }

        case .hedge:
            add(.generateBox(width: 1.0, height: 0.7, depth: 0.6, cornerRadius: 0.12), PlatformColor(red: 0.16, green: 0.4, blue: 0.2, alpha: 1), at: [0, 0.35, 0])

        case .grass:
            let blades = PlatformColor(red: 0.45, green: 0.78, blue: 0.3, alpha: 1)
            for _ in 0..<5 {
                let mesh = MeshResource.generateCone(height: 0.22, radius: 0.04)
                add(mesh, blades, at: [random.next(0.4), -mesh.bounds.min.y, random.next(0.4)])
            }

        case .vegetable(let vegetable):
            // Two in a row on each tile.
            for z: Float in [-0.2, 0.2] {
                let at = SIMD3<Float>(random.next(0.1), 0.04, z)
                switch vegetable {
                case .carrot:
                    let mesh = MeshResource.generateCone(height: 0.1, radius: 0.05)
                    add(mesh, PlatformColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1), at: at - [0, mesh.bounds.min.y, 0])
                    add(.generateBox(width: 0.05, height: 0.18, depth: 0.05, cornerRadius: 0.02), leafColor, at: at + [0, 0.18, 0])
                case .lettuce:
                    add(.generateSphere(radius: 0.13), PlatformColor(red: 0.55, green: 0.85, blue: 0.35, alpha: 1), at: at + [0, 0.08, 0])
                case .cabbage:
                    add(.generateSphere(radius: 0.15), PlatformColor(red: 0.45, green: 0.65, blue: 0.5, alpha: 1), at: at + [0, 0.1, 0])
                    add(.generateSphere(radius: 0.1), PlatformColor(red: 0.6, green: 0.78, blue: 0.6, alpha: 1), at: at + [0, 0.2, 0])
                case .tomato:
                    add(.generateBox(width: 0.03, height: 0.55, depth: 0.03), PlatformColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1), at: at + [0, 0.27, 0])
                    add(.generateSphere(radius: 0.11), leafColor, at: at + [0, 0.3, 0])
                    for (dx, dy) in [(Float(-0.08), Float(0.22)), (0.08, 0.3), (0, 0.4)] {
                        add(.generateSphere(radius: 0.045), PlatformColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1), at: at + [dx, dy, 0.07], roughness: 0.3)
                    }
                case .pumpkin:
                    let pumpkin = ModelEntity(mesh: .generateSphere(radius: 0.17), materials: [material(PlatformColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1), roughness: 0.6)])
                    pumpkin.scale = [1.2, 0.8, 1.2]
                    pumpkin.position = at + [0, 0.13, 0]
                    plant.addChild(pumpkin)
                    add(.generateBox(width: 0.03, height: 0.06, depth: 0.03), stemColor, at: at + [0, 0.27, 0])
                case .potato:
                    add(.generateBox(width: 0.22, height: 0.12, depth: 0.12, cornerRadius: 0.05), PlatformColor(red: 0.35, green: 0.62, blue: 0.3, alpha: 1), at: at + [0, 0.06, 0])
                case .other:
                    add(.generateBox(width: 0.18, height: 0.14, depth: 0.14, cornerRadius: 0.06), leafColor, at: at + [0, 0.07, 0])
                }
            }

        case .plant:
            add(.generateBox(width: 0.04, height: 0.25, depth: 0.04), stemColor, at: [0, 0.12, 0])
            add(.generateSphere(radius: 0.14), leafColor, at: [0, 0.28, 0])
            if let color {
                add(.generateSphere(radius: 0.06), color, at: [0, 0.42, 0])
            }
        }

        plant.orientation = simd_quatf(angle: random.next(.pi), axis: [0, 1, 0])
        return plant
    }

    private static func material(_ color: PlatformColor, roughness: Float = 0.9) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: false)
    }
}

/// Small differences from one plant to the next, the same for a tile each
/// time it is drawn.
private struct Jitter {
    private var state: UInt64

    init(x: Int, y: Int) {
        state = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) | 1
    }

    /// A number between `-amount` and `amount`.
    mutating func next(_ amount: Float) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amount
    }
}

extension PlatformColor {
    /// A colour written as `#RRGGBB`, or `nil` if it isn't one.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
