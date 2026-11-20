import ALifeClient
import CoreGraphics
import RealityKit

/// The city across the bay, on its island (see `HorizonPlan.island`): a
/// grid of towers, taller in the middle and in a cluster at the west end,
/// with a few that stand out against the sky: a stepped tower with a mast,
/// one with a crown of shining tiers and a needle, a tapering glass
/// supertall with a spire, pencil-thin towers and a glass slab. Their
/// windows are dark by day and many light up at night (see
/// `NightLightsComponent`), and the tallest have red lights blinking on top.
@MainActor
enum Skyline {
    /// What a tower's walls are made of, one material each.
    private enum Facade: Int, CaseIterable {
        case stone, glass, dark, metal, brick

        @MainActor var material: SimpleMaterial {
            switch self {
            case .stone: Buildings.material(PlatformColor(red: 0.78, green: 0.75, blue: 0.7, alpha: 1), roughness: 0.8)
            case .glass: SimpleMaterial(color: PlatformColor(red: 0.42, green: 0.55, blue: 0.66, alpha: 1), roughness: 0.15, isMetallic: true)
            case .dark: Buildings.material(PlatformColor(red: 0.3, green: 0.32, blue: 0.36, alpha: 1), roughness: 0.6)
            case .metal: SimpleMaterial(color: PlatformColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1), roughness: 0.25, isMetallic: true)
            case .brick: Buildings.material(PlatformColor(red: 0.62, green: 0.4, blue: 0.32, alpha: 1), roughness: 0.9)
            }
        }
    }

    /// The colour of a window by day, and of a lit one at night.
    static let darkWindow = SIMD3<Float>(0.1, 0.13, 0.18)
    static let litWindow = SIMD3<Float>(1, 0.82, 0.5)

    /// How far apart the blocks are, street to street, in metres.
    private static let block: Float = 24

    static func make() -> Entity {
        // The city is laid out on its own grid: x along the island from
        // west to east, z away from the lot, and its middle in the middle
        // of the island.
        let middle = HorizonPlan.point(bearing: .pi, distance: (HorizonPlan.island.near + HorizonPlan.island.far) / 2)
        let city = Entity()
        city.name = "Skyline"
        city.position = [middle.x, 0, middle.z]
        city.orientation = simd_quatf(angle: atan2(-HorizonPlan.east.z, HorizonPlan.east.x), axis: [0, 1, 0])

        var walls = MeshBatch(parts: Facade.allCases.count)
        var windows = MeshBatch(parts: 2)
        var beacons: [SIMD3<Float>] = []
        var random = SceneryRandom(seed: 11)

        for column in -6...6 {
            for row in -1...2 {
                let spot = SIMD2<Float>(Float(column) * block, Float(row) * block - block / 2)
                guard isOnTheIsland(spot, size: 20, city: city) else { continue }
                let base = SIMD3<Float>(spot.x, 0, spot.y)
                if let landmark = landmarks[SIMD2(Int32(column), Int32(row))] {
                    if let beacon = landmark(base, &walls, &windows, &random) {
                        beacons.append(beacon)
                    }
                } else {
                    addBlock(at: base, column: column, walls: &walls, windows: &windows, random: &random)
                }
            }
        }

        city.addChild(walls.makeEntity(named: "Towers", materials: Facade.allCases.map(\.material)))
        let lights = windows.makeEntity(named: "Windows", materials: [UnlitMaterial(color: PlatformColor(darkWindow)), UnlitMaterial(color: PlatformColor(darkWindow))])
        lights.components.set(NightLightsComponent(off: darkWindow, on: litWindow))
        city.addChild(lights)
        for spot in beacons {
            city.addChild(makeBeacon(at: spot))
        }
        return city
    }

    /// Whether a tower up to `size` across at `spot`, on the city's grid, is
    /// all on the island's flat top.
    private static func isOnTheIsland(_ spot: SIMD2<Float>, size: Float, city: Entity) -> Bool {
        [SIMD2<Float>(-1, -1), [1, -1], [1, 1], [-1, 1]].allSatisfy { corner in
            let local = spot + corner * size / 2
            let world = city.position + city.orientation.act([local.x, 0, local.y])
            return HorizonPlan.islandAmount(x: world.x, z: world.z) > 0.95
        }
    }

    // MARK: Ordinary towers

    /// A tower like most in the city: a box, sometimes stepped back near
    /// the top, sometimes with a water tank on its roof.
    private static func addBlock(at base: SIMD3<Float>, column: Int, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) {
        let across = Float(column) * block
        // Tallest in the middle of town, and in a cluster at the west end.
        let midtown = exp(-pow(across / 60, 2)), downtown = exp(-pow((across + 120) / 30, 2))
        let height = 18 + random.next(in: 0...22) + random.next(in: 30...85) * max(midtown, downtown)
        let width = random.next(in: 13...20), depth = random.next(in: 13...20)
        let facade = [Facade.stone, .glass, .dark, .brick, .stone][Int(random.next(in: 0...4.99))]

        if height > 70 && random.next(in: 0...1) < 0.5 {
            let step = height * random.next(in: 0.65...0.8)
            addStorey(from: base, width: width, depth: depth, to: step, facade: facade, walls: &walls, windows: &windows, random: &random)
            addStorey(from: base + [0, step, 0], width: width * 0.7, depth: depth * 0.7, to: height - step, facade: facade, walls: &walls, windows: &windows, random: &random)
        } else {
            addStorey(from: base, width: width, depth: depth, to: height, facade: facade, walls: &walls, windows: &windows, random: &random)
            if height < 60 && random.next(in: 0...1) < 0.35 {
                let tank = base + [random.next(in: -2...2), height, random.next(in: -2...2)]
                walls.addTube(at: tank, rings: [(0, 1.8), (3.5, 1.8), (5, 0)], sides: 8, part: Facade.brick.rawValue)
            }
        }
    }

    /// A box of `width` by `depth` from `base` up `height` metres, with a
    /// band of windows on each floor.
    private static func addStorey(from base: SIMD3<Float>, width: Float, depth: Float, to height: Float, facade: Facade, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) {
        let low = base - [width / 2, 0, depth / 2], high = base + [width / 2, height, depth / 2]
        walls.addBox(from: low, to: high, part: facade.rawValue)

        let centre = (low + high) / 2
        let out: Float = 0.12
        // Each side, from its left end to its right, seen from outside.
        let sides: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([low.x, 0, high.z + out], [high.x, 0, high.z + out]),
            ([high.x + out, 0, high.z], [high.x + out, 0, low.z]),
            ([high.x, 0, low.z - out], [low.x, 0, low.z - out]),
            ([low.x - out, 0, low.z], [low.x - out, 0, high.z]),
        ]
        for floor in stride(from: low.y + 3, through: high.y - 2.5, by: 3.6) {
            for (start, end) in sides {
                let length = simd_distance(start, end)
                let along = (end - start) / length
                let panes = max(1, Int((length - 2) / 5))
                let pane = (length - 2) / Float(panes)
                for index in 0..<panes {
                    let left = start + along * (1 + Float(index) * pane + 0.3)
                    let right = left + along * (pane - 0.6)
                    let lit = random.next(in: 0...1) < 0.45 ? 1 : 0
                    windows.addQuad(left + [0, floor, 0], right + [0, floor, 0], right + [0, floor + 1.7, 0], left + [0, floor + 1.7, 0], awayFrom: [centre.x, floor, centre.z], part: lit)
                }
            }
        }
    }

    // MARK: Landmarks

    /// Builds a landmark at a spot on the grid, and says where its red light
    /// goes, if it has one.
    private typealias Landmark = (SIMD3<Float>, inout MeshBatch, inout MeshBatch, inout SceneryRandom) -> SIMD3<Float>?

    /// The towers that stand out, by column and row on the city's grid.
    private static let landmarks: [SIMD2<Int32>: Landmark] = [
        [0, 0]: addSteppedTower,
        [2, 1]: addCrownedTower,
        [-5, 0]: addSupertall,
        [3, -1]: { base, walls, windows, random in addPencil(at: base, height: 150, walls: &walls, windows: &windows, random: &random) },
        [-2, 1]: { base, walls, windows, random in addPencil(at: base, height: 132, walls: &walls, windows: &windows, random: &random) },
        [5, 0]: addSlab,
    ]

    /// A stone tower stepping back as it rises, with a mast on top.
    private static func addSteppedTower(at base: SIMD3<Float>, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) -> SIMD3<Float>? {
        var floor: Float = 0
        for (width, depth, height) in [(Float(22), Float(18), Float(72)), (18, 14, 36), (14, 11, 22), (9, 8, 12)] {
            addStorey(from: base + [0, floor, 0], width: width, depth: depth, to: height, facade: .stone, walls: &walls, windows: &windows, random: &random)
            floor += height
        }
        walls.addTube(at: base + [0, floor, 0], rings: [(0, 4), (8, 3.2), (8, 2), (16, 1.6), (16, 1), (42, 0.15)], sides: 8, part: Facade.metal.rawValue)
        return base + [0, floor + 42, 0]
    }

    /// A stone tower with a crown of shining tiers, narrowing to a needle.
    private static func addCrownedTower(at base: SIMD3<Float>, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) -> SIMD3<Float>? {
        addStorey(from: base, width: 18, depth: 18, to: 104, facade: .stone, walls: &walls, windows: &windows, random: &random)
        walls.addTube(at: base + [0, 104, 0], rings: [
            (0, 10), (6, 8.6), (6, 7.6), (11, 6.4), (11, 5.6), (16, 4.4), (16, 3.7), (21, 2.5), (21, 1.8), (48, 0),
        ], sides: 8, turn: 0.5, part: Facade.metal.rawValue)
        return nil
    }

    /// A glass supertall on a dark base, its square turning a quarter as it
    /// tapers, so its sides are triangles, with a spire on top.
    private static func addSupertall(at base: SIMD3<Float>, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) -> SIMD3<Float>? {
        addStorey(from: base, width: 22, depth: 22, to: 14, facade: .dark, walls: &walls, windows: &windows, random: &random)
        let bottom: Float = 14, top: Float = 165
        func corner(_ angle: Float, radius: Float, height: Float) -> SIMD3<Float> {
            base + [cos(angle) * radius, height, sin(angle) * radius]
        }
        let quarter = Float.pi / 2
        let lower = (0..<4).map { corner(quarter / 2 + Float($0) * quarter, radius: 15, height: bottom) }
        let upper = (0..<4).map { corner(Float($0) * quarter, radius: 10.5, height: top) }
        let axis = base + [0, (bottom + top) / 2, 0]
        for index in 0..<4 {
            let next = (index + 1) % 4
            walls.addTriangle(lower[index], lower[next], upper[next], awayFrom: axis, part: Facade.glass.rawValue)
            walls.addTriangle(upper[index], lower[index], upper[next], awayFrom: axis, part: Facade.glass.rawValue)
        }
        walls.addQuad(upper[0], upper[1], upper[2], upper[3], awayFrom: axis, part: Facade.glass.rawValue)
        // A band of windows on each floor, on the slanting glass.
        for floor in stride(from: bottom + 4, to: top - 4, by: 3.6) {
            let share = (floor - bottom) / (top - bottom)
            // Where each floor crosses the eight edges up the sides, in order
            // round, just outside the glass.
            func edge(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> SIMD3<Float> {
                let point: SIMD3<Float> = low + (high - low) * share
                let outward = simd_normalize(SIMD3<Float>(point.x - base.x, 0, point.z - base.z))
                return point + outward * 0.15
            }
            var ring: [SIMD3<Float>] = []
            for index in 0..<4 {
                ring.append(edge(lower[index], upper[index]))
                ring.append(edge(lower[index], upper[(index + 1) % 4]))
            }
            for index in 0..<8 {
                let a = ring[index], b = ring[(index + 1) % 8]
                let lit = random.next(in: 0...1) < 0.45 ? 1 : 0
                windows.addQuad(a, b, b + [0, 1.5, 0], a + [0, 1.5, 0], awayFrom: [base.x, floor, base.z], part: lit)
            }
        }
        walls.addTube(at: base + [0, top, 0], rings: [(0, 3), (5, 2.4), (40, 0.25)], sides: 8, part: Facade.metal.rawValue)
        return base + [0, top + 40, 0]
    }

    /// A pencil-thin glass tower.
    private static func addPencil(at base: SIMD3<Float>, height: Float, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) -> SIMD3<Float>? {
        addStorey(from: base, width: 11, depth: 11, to: height, facade: .glass, walls: &walls, windows: &windows, random: &random)
        return base + [0, height + 1, 0]
    }

    /// A tall, thin slab of glass, broadside on to the lot.
    private static func addSlab(at base: SIMD3<Float>, walls: inout MeshBatch, windows: inout MeshBatch, random: inout SceneryRandom) -> SIMD3<Float>? {
        addStorey(from: base, width: 22, depth: 9, to: 112, facade: .glass, walls: &walls, windows: &windows, random: &random)
        return nil
    }

    /// A red light that blinks on top of a tall tower, for the aeroplanes.
    private static func makeBeacon(at spot: SIMD3<Float>) -> Entity {
        let beacon = Entity()
        beacon.position = spot
        beacon.components.set(BlinkComponent(period: 1.6, onFraction: 0.5))
        let light = ModelEntity(mesh: .generateSphere(radius: 1.3), materials: [UnlitMaterial(color: PlatformColor(red: 1, green: 0.1, blue: 0.08, alpha: 1))])
        beacon.addChild(light)
        return beacon
    }
}

extension PlatformColor {
    /// A colour from its red, green and blue, from 0 to 1.
    convenience init(_ rgb: SIMD3<Float>, alpha: CGFloat = 1) {
        self.init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: alpha)
    }
}
