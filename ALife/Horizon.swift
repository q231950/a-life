import ALifeClient
import RealityKit

/// The world painted on the insides of the lot's box, laid out by
/// `HorizonPlan`: on the south wall a bay with a beach, and the city on the
/// horizon across it (see `Skyline`); on the north wall mountains with
/// snowy tops, over foothills and a forest of giant redwoods; and on the
/// east and west walls the coast turning into wooded hills. It is painted
/// in flat layers a few centimetres apart, in front of the sky (see
/// `SkyBox`), in colours that `DaySystem` dims and warms with the time of
/// day. It is only to look at: nothing in it takes taps, and it stands
/// behind the outermost tiles, so the characters walk in front of it.
@MainActor
enum Horizon {
    /// How far in from each wall each layer is, from the back to the front.
    private enum Layer {
        static let farLand: Float = 0.05
        static let sea: Float = 0.1
        static let nearLand: Float = 0.22
        static let trees: ClosedRange<Float> = 0.25...0.3
    }

    /// The colours the world on the walls is painted in, one part each.
    private enum Paint: Int, CaseIterable {
        case rockLit, rockShade, snowLit, snowShade, farHillLit, farHillShade, farShore
        case seaNear, seaMid, seaFar, surf, sand
        case foothillLit, foothillShade, hillLit, hillShade
        case trunkLit, trunkShade, redwoodLit, redwoodShade, pineLit, pineShade

        var color: SIMD3<Float> {
            switch self {
            case .rockLit: [0.63, 0.6, 0.62]
            case .rockShade: [0.42, 0.42, 0.5]
            case .snowLit: [0.97, 0.98, 1]
            case .snowShade: [0.76, 0.82, 0.92]
            case .farHillLit: [0.47, 0.62, 0.56]
            case .farHillShade: [0.37, 0.51, 0.51]
            case .farShore: [0.6, 0.68, 0.67]
            case .seaNear: [0.1, 0.35, 0.55]
            case .seaMid: [0.15, 0.44, 0.63]
            case .seaFar: [0.34, 0.58, 0.74]
            case .surf: [0.93, 0.96, 0.96]
            case .sand: [0.9, 0.82, 0.62]
            case .foothillLit: [0.27, 0.46, 0.28]
            case .foothillShade: [0.2, 0.36, 0.24]
            case .hillLit: [0.37, 0.57, 0.31]
            case .hillShade: [0.29, 0.47, 0.27]
            case .trunkLit: [0.6, 0.3, 0.18]
            case .trunkShade: [0.42, 0.2, 0.13]
            case .redwoodLit: [0.17, 0.36, 0.2]
            case .redwoodShade: [0.11, 0.26, 0.16]
            case .pineLit: [0.2, 0.41, 0.22]
            case .pineShade: [0.13, 0.3, 0.18]
            }
        }
    }

    static func make() -> Entity {
        let horizon = Entity()
        horizon.name = "Horizon"
        var painter = WallPainter(parts: Paint.allCases.count)
        var random = SceneryRandom(seed: 7)
        paintFarLand(with: &painter, random: &random)
        paintSea(with: &painter)
        paintNearLand(with: &painter, random: &random)
        paintRedwoods(with: &painter, random: &random)
        paintPines(with: &painter, random: &random)
        horizon.addChild(painter.makeEntity(named: "Land and sea", colors: Paint.allCases.map(\.color)))
        horizon.addChild(Skyline.make())
        // Nothing painted on the walls should darken the lot.
        horizon.visit { $0.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        return horizon
    }

    // MARK: Land and sea

    /// Which of the regions a strip of the walls is painted as. Where they
    /// meet, strips of each are mixed, more of one the further into it.
    private enum Region {
        case sea, mountains, hills
    }

    private static func region(around: Float, random: inout SceneryRandom) -> Region {
        let regions = HorizonPlan.regions(around: around)
        let pick = random.next(in: 0...1)
        if pick < regions.sea { return .sea }
        if pick < regions.sea + regions.mountains { return .mountains }
        return .hills
    }

    /// Each metre of the walls, all the way round, from its left end to its
    /// right, as seen from inside. The corners fall between strips.
    private static var strips: [(Float, Float)] {
        stride(from: Float(0), to: HorizonPlan.perimeter, by: 1).map { ($0, $0 + 1) }
    }

    /// The furthest land: the mountains' rocky faces and snowy tops, lit on
    /// one side and in shade on the other, the far hills, and the low far
    /// shore behind the city.
    private static func paintFarLand(with painter: inout WallPainter, random: inout SceneryRandom) {
        for (left, right) in strips {
            let top = (HorizonPlan.farRidge(around: left), HorizonPlan.farRidge(around: right))
            let strip: [SIMD2<Float>] = [[left, 0], [right, 0], [right, top.1], [left, top.0]]
            let isLit = top.1 >= top.0
            switch region(around: (left + right) / 2, random: &random) {
            case .mountains:
                let snow = ([left, HorizonPlan.snowLine(around: left)], [right, HorizonPlan.snowLine(around: right)]) as (SIMD2<Float>, SIMD2<Float>)
                painter.fill(WallPainter.clip(strip, below: snow), inset: Layer.farLand, part: (isLit ? Paint.rockLit : .rockShade).rawValue)
                painter.fill(WallPainter.clip(strip, above: snow), inset: Layer.farLand, part: (isLit ? Paint.snowLit : .snowShade).rawValue)
            case .hills:
                painter.fill(strip, inset: Layer.farLand, part: (isLit ? Paint.farHillLit : .farHillShade).rawValue)
            case .sea:
                painter.fill(strip, inset: Layer.farLand, part: Paint.farShore.rawValue)
            }
        }
    }

    /// The bay, from the beach out to the horizon, paler further out.
    private static func paintSea(with painter: inout WallPainter) {
        let bands: [(Float, Float, Paint)] = [(0, 2.2, .seaNear), (2.2, 4, .seaMid), (4, HorizonPlan.horizonHeight, .seaFar)]
        for (left, right) in strips where HorizonPlan.regions(around: left).sea > 0.01 || HorizonPlan.regions(around: right).sea > 0.01 {
            for (low, high, paint) in bands {
                painter.rect(from: [left, low], to: [right, high], inset: Layer.sea, part: paint.rawValue)
            }
        }
    }

    /// The nearest land: foothills under the mountains, green hills to the
    /// east and the west, and a beach with the surf along it by the bay.
    private static func paintNearLand(with painter: inout WallPainter, random: inout SceneryRandom) {
        for (left, right) in strips {
            let top = (HorizonPlan.nearLand(around: left), HorizonPlan.nearLand(around: right))
            let strip: [SIMD2<Float>] = [[left, 0], [right, 0], [right, top.1], [left, top.0]]
            let isLit = top.1 >= top.0
            switch region(around: (left + right) / 2, random: &random) {
            case .mountains:
                painter.fill(strip, inset: Layer.nearLand, part: (isLit ? Paint.foothillLit : .foothillShade).rawValue)
            case .hills:
                painter.fill(strip, inset: Layer.nearLand, part: (isLit ? Paint.hillLit : .hillShade).rawValue)
            case .sea:
                painter.fill(strip, inset: Layer.nearLand, part: Paint.sand.rawValue)
                painter.fill([[left, top.0], [right, top.1], [right, top.1 + 0.15], [left, top.0 + 0.15]], inset: Layer.nearLand, part: Paint.surf.rawValue)
            }
        }
    }

    // MARK: Trees

    /// Up to `count` spots round the walls, at least `spacing` apart and
    /// clear of the corners, where `fits` says a tree would grow.
    private static func scatter(count: Int, spacing: Float, random: inout SceneryRandom, fits: (Float) -> Bool) -> [Float] {
        var spots: [Float] = []
        for _ in 0..<(count * 8) where spots.count < count {
            let around = random.next(in: 0...HorizonPlan.perimeter)
            let fromCorner = abs((around + HorizonPlan.halfWidth).truncatingRemainder(dividingBy: 2 * HorizonPlan.halfWidth) - HorizonPlan.halfWidth)
            guard HorizonPlan.halfWidth - fromCorner > 1.5, fits(around),
                  !spots.contains(where: { abs($0 - around) < spacing }) else { continue }
            spots.append(around)
        }
        return spots
    }

    /// Giant redwoods at the mountains' feet: tall red trunks, bare for
    /// their lower third, under narrow dark crowns, lit on the left.
    private static func paintRedwoods(with painter: inout WallPainter, random: inout SceneryRandom) {
        let spots = scatter(count: 40, spacing: 1.6, random: &random) { HorizonPlan.regions(around: $0).mountains > 0.6 }
        for around in spots {
            let height = random.next(in: 10...19)
            let inset = random.next(in: Layer.trees)
            let trunk = height * random.next(in: 0.035...0.045)
            painter.fill([[around - trunk, 0], [around, 0], [around, height * 0.9], [around - trunk * 0.3, height * 0.9]], inset: inset, part: Paint.trunkLit.rawValue)
            painter.fill([[around, 0], [around + trunk, 0], [around + trunk * 0.3, height * 0.9], [around, height * 0.9]], inset: inset, part: Paint.trunkShade.rawValue)
            let crown = height * random.next(in: 0.1...0.13)
            let rings: [(Float, Float)] = [(0.34, 0), (0.42, 0.7), (0.58, 1), (0.76, 0.85), (0.92, 0.45), (1, 0)]
            for (low, high) in zip(rings, rings.dropFirst()) {
                let bottom = height * low.0, top = height * high.0
                let inner = inset + 0.005
                painter.fill([[around - crown * low.1, bottom], [around, bottom], [around, top], [around - crown * high.1, top]], inset: inner, part: Paint.redwoodLit.rawValue)
                painter.fill([[around, bottom], [around + crown * low.1, bottom], [around + crown * high.1, top], [around, top]], inset: inner, part: Paint.redwoodShade.rawValue)
            }
        }
    }

    /// Pines all over the hills: a short trunk under two tiers.
    private static func paintPines(with painter: inout WallPainter, random: inout SceneryRandom) {
        let spots = scatter(count: 170, spacing: 0.7, random: &random) { HorizonPlan.regions(around: $0).hills > 0.35 }
        for around in spots {
            let land = HorizonPlan.nearLand(around: around)
            let base = random.next(in: 0.2...max(0.3, land - 0.4))
            let height = random.next(in: 1.6...3.2)
            let inset = random.next(in: Layer.trees)
            let width = height * random.next(in: 0.2...0.26)
            painter.rect(from: [around - 0.06, base], to: [around + 0.06, base + height * 0.3], inset: inset, part: Paint.trunkShade.rawValue)
            for (bottom, top, spread) in [(Float(0.2), Float(0.7), Float(1)), (0.5, 1, 0.7)] {
                let low = base + height * bottom, high = base + height * top
                painter.fill([[around - width * spread, low], [around, low], [around, high]], inset: inset + 0.003, part: Paint.pineLit.rawValue)
                painter.fill([[around, low], [around + width * spread, low], [around, high]], inset: inset + 0.003, part: Paint.pineShade.rawValue)
            }
        }
    }
}

/// Paints flat shapes on the insides of the walls, all into one mesh with a
/// part for each colour. Shapes are given in the walls' own terms: metres
/// round them (see `HorizonPlan.wallSpot`), metres up, and how far in from
/// the wall they are.
struct WallPainter {
    private var batch: MeshBatch

    init(parts: Int) {
        batch = MeshBatch(parts: parts)
    }

    /// A shape with these corners, (around, up), in order round its edge.
    /// It should be convex, and on one wall.
    mutating func fill(_ corners: [SIMD2<Float>], inset: Float, part: Int) {
        guard corners.count >= 3 else { return }
        let middle = corners.reduce(.zero, +) / Float(corners.count)
        let inward = HorizonPlan.wallSpot(around: middle.x).wall.inward
        let points = corners.map { HorizonPlan.wallPoint(around: $0.x, height: $0.y, inset: inset) }
        for index in 1..<(points.count - 1) {
            batch.addTriangle(points[0], points[index], points[index + 1], facing: inward, part: part)
        }
    }

    /// A rectangle from its bottom left corner to its top right.
    mutating func rect(from low: SIMD2<Float>, to high: SIMD2<Float>, inset: Float, part: Int) {
        fill([low, [high.x, low.y], high, [low.x, high.y]], inset: inset, part: part)
    }

    /// The part of a convex shape under the line through `line`.
    static func clip(_ shape: [SIMD2<Float>], below line: (SIMD2<Float>, SIMD2<Float>)) -> [SIMD2<Float>] {
        clip(shape) { point in
            let share = (point.x - line.0.x) / (line.1.x - line.0.x)
            return line.0.y + (line.1.y - line.0.y) * share - point.y
        }
    }

    /// The part of a convex shape over the line through `line`.
    static func clip(_ shape: [SIMD2<Float>], above line: (SIMD2<Float>, SIMD2<Float>)) -> [SIMD2<Float>] {
        clip(shape) { point in
            let share = (point.x - line.0.x) / (line.1.x - line.0.x)
            return point.y - (line.0.y + (line.1.y - line.0.y) * share)
        }
    }

    /// The part of a convex shape where `side` isn't negative. `side`
    /// should change evenly across the shape, as it does either side of a
    /// straight line.
    private static func clip(_ shape: [SIMD2<Float>], keeping side: (SIMD2<Float>) -> Float) -> [SIMD2<Float>] {
        var kept: [SIMD2<Float>] = []
        for (index, point) in shape.enumerated() {
            let next = shape[(index + 1) % shape.count]
            let here = side(point), there = side(next)
            if here >= 0 { kept.append(point) }
            if (here >= 0) != (there >= 0) {
                kept.append(point + (next - point) * (here / (here - there)))
            }
        }
        return kept
    }

    /// The mesh, painted in `colors` (in full daylight) for its parts in
    /// order, as one entity.
    func makeEntity(named name: String, colors: [SIMD3<Float>]) -> ModelEntity {
        let entity = batch.makeEntity(named: name, materials: colors.map { UnlitMaterial(color: PlatformColor($0)) })
        entity.components.set(PaintComponent(colors: colors))
        return entity
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

    /// The mesh, its parts in order, or `nil` if there is nothing in it.
    func makeMesh(named name: String) -> MeshResource? {
        var descriptors: [MeshDescriptor] = []
        for (index, part) in parts.enumerated() where !part.indices.isEmpty {
            var descriptor = MeshDescriptor(name: "\(name) \(index)")
            descriptor.positions = MeshBuffers.Positions(part.positions)
            descriptor.normals = MeshBuffers.Normals(part.normals)
            descriptor.primitives = .triangles(part.indices)
            descriptor.materials = .allFaces(UInt32(index))
            descriptors.append(descriptor)
        }
        guard !descriptors.isEmpty else { return nil }
        return try? MeshResource.generate(from: descriptors)
    }

    /// The mesh, with `materials` for its parts in order, as one entity.
    func makeEntity(named name: String, materials: [any Material]) -> ModelEntity {
        let entity = ModelEntity()
        entity.name = name
        if let mesh = makeMesh(named: name) {
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
