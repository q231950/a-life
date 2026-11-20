import ALifeClient
import RealityKit

/// The land and sea round the lot, laid out by `HorizonPlan`: a meadow all
/// round it, a beach and a bay to the south with the city on its island
/// (see `Skyline`), mountains with snowy tops to the north with forests of
/// giant redwoods at their feet, and wooded hills to the east and the west.
/// It is only to look at: nothing in it takes taps, and the characters
/// never walk there.
@MainActor
enum Horizon {
    static func make() -> Entity {
        let horizon = Entity()
        horizon.name = "Horizon"
        for part in [makeLand(), makeSea(), makeForests(), Skyline.make()] {
            horizon.addChild(part)
        }
        // Far beyond the reach of the sun's shadows, and nothing out here
        // should darken the lot.
        horizon.visit { $0.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        return horizon
    }

    // MARK: Land and sea

    /// What the land is covered in, one material each.
    private enum Cover: Int, CaseIterable {
        case meadow, woods, sand, seabed, quay, rock, snow

        @MainActor var material: SimpleMaterial {
            switch self {
            case .meadow: Buildings.material(PlatformColor(red: 0.45, green: 0.66, blue: 0.32, alpha: 1), roughness: 1)
            case .woods: Buildings.material(PlatformColor(red: 0.24, green: 0.42, blue: 0.24, alpha: 1), roughness: 1)
            case .sand: Buildings.material(PlatformColor(red: 0.88, green: 0.8, blue: 0.6, alpha: 1), roughness: 1)
            case .seabed: Buildings.material(PlatformColor(red: 0.42, green: 0.45, blue: 0.4, alpha: 1), roughness: 1)
            case .quay: Buildings.material(PlatformColor(red: 0.52, green: 0.52, blue: 0.54, alpha: 1), roughness: 0.9)
            case .rock: Buildings.material(PlatformColor(red: 0.5, green: 0.47, blue: 0.45, alpha: 1), roughness: 1)
            case .snow: Buildings.material(PlatformColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1), roughness: 0.8)
            }
        }
    }

    /// The land and the sea floor, one flat-shaded mesh from the middle of
    /// the lot out to the edge, in rings that get further apart further out.
    private static func makeLand() -> Entity {
        var rings: [Float] = [0, 40, 55, 65, 72, 78, 84, 90, 96, 104, 112, 122, 132, 142]
        rings += stride(from: Float(150), to: 460, by: 10)
        rings += stride(from: Float(460), to: 760, by: 20)
        rings += stride(from: Float(760), through: HorizonPlan.radius, by: 50)
        let steps = 240

        // Every point on the rings, by ring and step round.
        let points = rings.map { distance in
            (0..<steps).map { step in
                let spot = HorizonPlan.point(bearing: Float(step) / Float(steps) * 2 * .pi, distance: distance)
                return SIMD3<Float>(spot.x, HorizonPlan.height(x: spot.x, z: spot.z), spot.z)
            }
        }

        var batch = MeshBatch(parts: Cover.allCases.count)
        for ring in 1..<rings.count {
            for step in 0..<steps {
                let next = (step + 1) % steps
                let inner = (points[ring - 1][step], points[ring - 1][next])
                let outer = (points[ring][step], points[ring][next])
                // The same cover for both halves, so where one gives way
                // to another follows the rings.
                let cover = cover(of: [inner.0, inner.1, outer.0, outer.1]).rawValue
                batch.addTriangle(inner.0, outer.0, outer.1, facing: [0, 1, 0], part: cover)
                batch.addTriangle(inner.0, outer.1, inner.1, facing: [0, 1, 0], part: cover)
            }
        }
        return batch.makeEntity(named: "Land", materials: Cover.allCases.map(\.material))
    }

    /// What a patch of land with these corners is covered in, by where it
    /// is and how high and steep.
    private static func cover(of corners: [SIMD3<Float>]) -> Cover {
        let middle = corners.reduce(.zero, +) / Float(corners.count)
        let distance = simd_length(SIMD2(middle.x, middle.z))
        let bearing = HorizonPlan.bearing(x: middle.x, z: middle.z)
        let heights = corners.map(\.y)
        let rise = (heights.max() ?? 0) - (heights.min() ?? 0)
        let steepness = rise / max(1, simd_distance(corners[0], corners[3]))

        if middle.y < HorizonPlan.waterLevel - 0.4 { return .seabed }
        if HorizonPlan.islandAmount(x: middle.x, z: middle.z) > 0.5 { return .quay }
        if HorizonPlan.regions(bearing: bearing).sea > 0.05, middle.y < HorizonPlan.groundLevel - 0.01, middle.y < HorizonPlan.waterLevel + 1 {
            return .sand
        }
        if middle.y > 135 + 20 * sin(7 * bearing) { return .snow }
        if HorizonPlan.regions(bearing: bearing).mountains > 0.3, middle.y > 95 || (steepness > 0.45 && middle.y > 30) { return .rock }
        return distance < HorizonPlan.flatRadius ? .meadow : .woods
    }

    /// The sea: one flat disc at sea level, under the land wherever the land
    /// is higher.
    private static func makeSea() -> Entity {
        var batch = MeshBatch(parts: 1)
        let steps = 120
        let centre = SIMD3<Float>(0, HorizonPlan.waterLevel, 0)
        for step in 0..<steps {
            let here = HorizonPlan.point(bearing: Float(step) / Float(steps) * 2 * .pi, distance: HorizonPlan.radius)
            let next = HorizonPlan.point(bearing: Float(step + 1) / Float(steps) * 2 * .pi, distance: HorizonPlan.radius)
            batch.addTriangle(centre, [here.x, centre.y, here.z], [next.x, centre.y, next.z], facing: [0, 1, 0], part: 0)
        }
        let water = SimpleMaterial(color: PlatformColor(red: 0.07, green: 0.28, blue: 0.46, alpha: 1), roughness: 0.55, isMetallic: false)
        return batch.makeEntity(named: "Sea", materials: [water])
    }

    // MARK: Forests

    /// Giant redwoods in the mountains' foothills, and pines on the hills,
    /// all in one mesh: trunks, redwood crowns and pine crowns.
    private static func makeForests() -> Entity {
        var batch = MeshBatch(parts: 3)
        var random = SceneryRandom(seed: 7)

        let redwoods = scatter(count: 170, spacing: 16, distances: 190...320, random: &random) { spot, height in
            HorizonPlan.regions(bearing: spot.bearing).mountains > 0.55 && height > 1 && height < 115
        }
        for (base, _) in redwoods {
            addRedwood(at: base, height: random.next(in: 36...62), to: &batch, random: &random)
        }

        let pines = scatter(count: 520, spacing: 6, distances: 160...360, random: &random) { spot, height in
            HorizonPlan.regions(bearing: spot.bearing).hills > 0.6 && height > 1 && height < 85
        }
        for (base, _) in pines {
            addPine(at: base, height: random.next(in: 14...28), to: &batch, random: &random)
        }

        return batch.makeEntity(named: "Forests", materials: [
            Buildings.material(PlatformColor(red: 0.52, green: 0.24, blue: 0.15, alpha: 1), roughness: 1),
            Buildings.material(PlatformColor(red: 0.13, green: 0.3, blue: 0.16, alpha: 1), roughness: 1),
            Buildings.material(PlatformColor(red: 0.16, green: 0.34, blue: 0.2, alpha: 1), roughness: 1),
        ])
    }

    /// Up to `count` spots on the land, `distances` from the middle of the
    /// lot and at least `spacing` apart, where `fits` says a tree would grow.
    private static func scatter(
        count: Int,
        spacing: Float,
        distances: ClosedRange<Float>,
        random: inout SceneryRandom,
        fits: ((bearing: Float, distance: Float), Float) -> Bool
    ) -> [(SIMD3<Float>, Float)] {
        var spots: [(SIMD3<Float>, Float)] = []
        for _ in 0..<(count * 8) where spots.count < count {
            let bearing = random.next(in: 0...(2 * .pi))
            let distance = random.next(in: distances)
            let point = HorizonPlan.point(bearing: bearing, distance: distance)
            let height = HorizonPlan.height(x: point.x, z: point.z)
            let base = SIMD3<Float>(point.x, height, point.z)
            guard fits((bearing, distance), height),
                  !spots.contains(where: { simd_distance($0.0, base) < spacing }) else { continue }
            spots.append((base, height))
        }
        return spots
    }

    /// A giant redwood: a tall, thick red trunk, bare for its lower third,
    /// under a narrow dark crown.
    private static func addRedwood(at base: SIMD3<Float>, height: Float, to batch: inout MeshBatch, random: inout SceneryRandom) {
        let turn = random.next(in: 0...1)
        let trunk = height * random.next(in: 0.045...0.06)
        batch.addTube(at: base - [0, 3, 0], rings: [(0, trunk * 1.3), (3 + height * 0.1, trunk), (3 + height * 0.92, trunk * 0.3)], sides: 7, turn: turn, part: 0)
        let crown = height * random.next(in: 0.14...0.18)
        batch.addTube(at: base, rings: [
            (height * 0.36, 0), (height * 0.42, crown * 0.7), (height * 0.58, crown),
            (height * 0.76, crown * 0.85), (height * 0.92, crown * 0.45), (height, 0),
        ], sides: 7, turn: turn, part: 1)
    }

    /// A pine on the hills: a short trunk under two tiers of cone.
    private static func addPine(at base: SIMD3<Float>, height: Float, to batch: inout MeshBatch, random: inout SceneryRandom) {
        let turn = random.next(in: 0...1)
        batch.addTube(at: base - [0, 1, 0], rings: [(0, height * 0.035), (height * 0.35, height * 0.025)], sides: 5, turn: turn, part: 0)
        let width = height * random.next(in: 0.22...0.3)
        batch.addTube(at: base, rings: [(height * 0.15, width), (height * 0.7, width * 0.35), (height * 0.55, width * 0.75), (height, 0)], sides: 6, turn: turn, part: 2)
    }
}

/// Triangles gathered into one mesh, one part for each material, so a whole
/// forest or city is one entity to draw. Each triangle has a normal of its
/// own, for a crisp, faceted look.
struct MeshBatch {
    private var parts: [(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])]

    init(parts: Int) {
        self.parts = Array(repeating: ([], [], []), count: parts)
    }

    /// A triangle whose front faces `facing`, more or less: the way it is
    /// seen from.
    mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, facing: SIMD3<Float>, part: Int) {
        let cross = simd_cross(b - a, c - a)
        guard simd_length_squared(cross) > 0 else { return }
        var normal = simd_normalize(cross)
        var corners = [a, b, c]
        if simd_dot(normal, facing) < 0 {
            normal = -normal
            corners = [a, c, b]
        }
        let first = UInt32(parts[part].positions.count)
        parts[part].positions += corners
        parts[part].normals += [normal, normal, normal]
        parts[part].indices += [first, first + 1, first + 2]
    }

    /// A triangle facing away from `centre`, as on the outside of something.
    mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, awayFrom centre: SIMD3<Float>, part: Int) {
        addTriangle(a, b, c, facing: (a + b + c) / 3 - centre, part: part)
    }

    /// A four-cornered face, its corners in order round its edge, facing away
    /// from `centre`.
    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, awayFrom centre: SIMD3<Float>, part: Int) {
        addTriangle(a, b, c, awayFrom: centre, part: part)
        addTriangle(a, c, d, awayFrom: centre, part: part)
    }

    /// The sides of a round tube standing at `base`, with `sides` faces round
    /// it, through `rings` of (height, radius) from the bottom up. A ring of
    /// radius 0 makes a point. `turn` turns it round, as a share of a face.
    mutating func addTube(at base: SIMD3<Float>, rings: [(height: Float, radius: Float)], sides: Int, turn: Float = 0, part: Int) {
        func corner(_ ring: (height: Float, radius: Float), _ side: Int) -> SIMD3<Float> {
            let angle = (Float(side) + turn) / Float(sides) * 2 * .pi
            return base + [sin(angle) * ring.radius, ring.height, cos(angle) * ring.radius]
        }
        for (low, high) in zip(rings, rings.dropFirst()) {
            // A little below the middle, so a flat step faces up.
            let axis = base + [0, (low.height + high.height) / 2 - 0.1, 0]
            for side in 0..<sides {
                let a = corner(low, side), b = corner(low, side + 1), c = corner(high, side + 1), d = corner(high, side)
                if low.radius > 0 { addTriangle(a, b, c, awayFrom: axis, part: part) }
                if high.radius > 0 { addTriangle(a, c, d, awayFrom: axis, part: part) }
            }
        }
    }

    /// A box from `low` to `high`, its sides lined up with x and z, with no
    /// floor: it stands on something.
    mutating func addBox(from low: SIMD3<Float>, to high: SIMD3<Float>, part: Int) {
        let centre = (low + high) / 2
        let corners = [SIMD3(low.x, 0, low.z), SIMD3(high.x, 0, low.z), SIMD3(high.x, 0, high.z), SIMD3(low.x, 0, high.z)]
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) {
            addQuad(a + [0, low.y, 0], b + [0, low.y, 0], b + [0, high.y, 0], a + [0, high.y, 0], awayFrom: centre, part: part)
        }
        addQuad(corners[0] + [0, high.y, 0], corners[1] + [0, high.y, 0], corners[2] + [0, high.y, 0], corners[3] + [0, high.y, 0], awayFrom: centre, part: part)
    }

    /// The mesh, with `materials` for its parts in order, as one entity.
    func makeEntity(named name: String, materials: [any Material]) -> ModelEntity {
        var descriptors: [MeshDescriptor] = []
        for (index, part) in parts.enumerated() where !part.indices.isEmpty {
            var descriptor = MeshDescriptor(name: "\(name) \(index)")
            descriptor.positions = MeshBuffers.Positions(part.positions)
            descriptor.normals = MeshBuffers.Normals(part.normals)
            descriptor.primitives = .triangles(part.indices)
            descriptor.materials = .allFaces(UInt32(index))
            descriptors.append(descriptor)
        }
        let entity = ModelEntity()
        entity.name = name
        if let mesh = try? MeshResource.generate(from: descriptors) {
            entity.model = ModelComponent(mesh: mesh, materials: materials)
        }
        return entity
    }
}

/// Random numbers that come out the same every time, so the trees and the
/// towers stand in the same places from one launch to the next.
struct SceneryRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// A number in `range`.
    mutating func next(in range: ClosedRange<Float>) -> Float {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Float(z >> 40) / Float(1 << 24)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

extension Entity {
    /// Calls `body` with this entity and every one under it.
    func visit(_ body: (Entity) -> Void) {
        body(self)
        for child in children {
            child.visit(body)
        }
    }
}
