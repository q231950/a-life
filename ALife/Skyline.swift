import ALifeClient
import CoreGraphics
import RealityKit

/// The city on the horizon across the bay, painted on the south wall (see
/// `HorizonPlan.city`): two rows of towers on a quay, taller in the middle
/// and in a cluster at the west end, each with a sliver of its side in
/// shade, and a few that stand out against the sky: a stepped tower with a
/// mast, one with a crown of shining tiers and a needle, a tapering glass
/// supertall with a spire, pencil-thin towers and a glass slab. Their
/// windows are dark by day and many light up at night (see
/// `NightLightsComponent`), and the tallest have red lights blinking on top.
@MainActor
enum Skyline {
    /// What a tower's walls are made of, its front and its side in shade.
    private enum Facade: Int, CaseIterable {
        case stone, glass, dark, metal, brick, quay

        var color: SIMD3<Float> {
            switch self {
            case .stone: [0.78, 0.75, 0.7]
            case .glass: [0.5, 0.63, 0.74]
            case .dark: [0.33, 0.35, 0.4]
            case .metal: [0.86, 0.87, 0.9]
            case .brick: [0.64, 0.42, 0.34]
            case .quay: [0.52, 0.52, 0.54]
            }
        }

        var front: Int { rawValue * 2 }
        var side: Int { rawValue * 2 + 1 }
    }

    /// The colour of a window by day, and of a lit one at night.
    static let darkWindow = SIMD3<Float>(0.1, 0.13, 0.18)
    static let litWindow = SIMD3<Float>(1, 0.82, 0.5)

    /// How far in from the wall the back row and the front row are.
    private static let backRow: Float = 0.14
    private static let frontRow: Float = 0.18
    /// Where the towers stand: just under the horizon, on the quay.
    private static let ground = HorizonPlan.horizonHeight - 0.25

    static func make() -> Entity {
        var painter = Painter()
        var random = SceneryRandom(seed: 11)
        let city = HorizonPlan.city
        let middle = (city.lowerBound + city.upperBound) / 2

        // The quay along the island's edge.
        painter.walls.rect(from: [city.lowerBound - 1.5, HorizonPlan.horizonHeight - 0.3], to: [city.upperBound + 1.5, HorizonPlan.horizonHeight + 0.3], inset: frontRow + 0.02, part: Facade.quay.front)

        // The landmarks, in the back row, by how far west of the middle
        // they are, and how wide.
        let landmarks: [(Float, Float, (inout Painter, Float, inout SceneryRandom) -> Void)] = [
            (0, 2.4, { addSteppedTower(at: $1, with: &$0, random: &$2) }),
            (5, 2.2, { addCrownedTower(at: $1, with: &$0, random: &$2) }),
            (15, 3.2, { addSupertall(at: $1, with: &$0, random: &$2) }),
            (-4, 1.1, { addPencil(at: $1, height: 16, with: &$0, random: &$2) }),
            (9.5, 1.1, { addPencil(at: $1, height: 14, with: &$0, random: &$2) }),
            (-11, 2.6, { addSlab(at: $1, with: &$0, random: &$2) }),
        ]
        var taken: [ClosedRange<Float>] = []
        for (across, width, build) in landmarks {
            build(&painter, middle + across, &random)
            taken.append((middle + across - width / 2 - 0.2)...(middle + across + width / 2 + 0.2))
        }

        // Ordinary towers, taller in the middle and at the west end.
        for (inset, isBack) in [(backRow, true), (frontRow, false)] {
            var left = city.lowerBound + random.next(in: 0...0.6)
            while left < city.upperBound - 1 {
                let width = random.next(in: 1.4...2.8)
                let span = left...(left + width)
                if isBack, taken.contains(where: { $0.overlaps(span) }) {
                    left += 0.5
                    continue
                }
                let across = left + width / 2 - middle
                let midtown = exp(-pow(across / 9, 2)), downtown = exp(-pow((across - 16) / 5, 2))
                let height = isBack
                    ? 3 + random.next(in: 0...3) + random.next(in: 5...12) * max(midtown, downtown)
                    : 1.5 + random.next(in: 0...2.5) + random.next(in: 2...5) * max(midtown, downtown)
                let facade = [Facade.stone, .glass, .dark, .brick, .stone][Int(random.next(in: 0...4.99))]
                painter.addTower(from: left, width: width, height: height, facade: facade, inset: inset, random: &random)
                if height < 6 && random.next(in: 0...1) < 0.3 {
                    // A water tank on the roof.
                    let tank = left + width * random.next(in: 0.3...0.7)
                    painter.walls.fill([[tank - 0.2, ground + height], [tank + 0.2, ground + height], [tank + 0.2, ground + height + 0.4], [tank, ground + height + 0.55], [tank - 0.2, ground + height + 0.4]], inset: inset + 0.005, part: Facade.brick.side)
                }
                left += width + random.next(in: 0.1...0.5)
            }
        }

        let skyline = Entity()
        skyline.name = "Skyline"
        skyline.addChild(painter.walls.makeEntity(named: "Towers", colors: Facade.allCases.flatMap { [$0.color, $0.color * 0.72] }))
        let lights = painter.windows.makeEntity(named: "Windows", materials: [UnlitMaterial(color: PlatformColor(darkWindow)), UnlitMaterial(color: PlatformColor(darkWindow))])
        lights.components.set(NightLightsComponent(off: darkWindow, on: litWindow))
        skyline.addChild(lights)
        for beacon in painter.beacons {
            skyline.addChild(makeBeacon(at: beacon))
        }
        return skyline
    }

    /// The city's towers, windows and red lights as they are painted.
    private struct Painter {
        var walls = WallPainter(parts: Facade.allCases.count * 2)
        var windows = MeshBatch(parts: 2)
        var beacons: [SIMD3<Float>] = []

        /// A box tower `width` across from `left`, `height` tall, standing
        /// on `base` above the city's ground, with windows on each floor.
        mutating func addTower(from left: Float, width: Float, height: Float, base: Float = 0, facade: Facade, inset: Float, random: inout SceneryRandom) {
            let bottom = ground + base, top = bottom + height
            let side = min(0.4, width * 0.2)
            walls.rect(from: [left, bottom], to: [left + width - side, top], inset: inset, part: facade.front)
            walls.rect(from: [left + width - side, bottom], to: [left + width, top], inset: inset, part: facade.side)
            addWindows(from: bottom, to: top, inset: inset, random: &random) { _ in (left, left + width - side) }
        }

        /// Bands of windows, one each floor from `bottom` to `top`, across
        /// whatever `span` says the tower is at each height.
        mutating func addWindows(from bottom: Float, to top: Float, inset: Float, random: inout SceneryRandom, span: (Float) -> (Float, Float)) {
            for floor in stride(from: bottom + 0.35, through: top - 0.4, by: 0.5) {
                let (left, right) = span(floor + 0.11)
                let length = right - left - 0.2
                guard length > 0.25 else { continue }
                let panes = max(1, Int(length / 0.42))
                let pane = length / Float(panes)
                for index in 0..<panes {
                    let start = left + 0.1 + Float(index) * pane + 0.05
                    let lit = random.next(in: 0...1) < 0.45 ? 1 : 0
                    let corners = [[start, floor], [start + pane - 0.1, floor], [start + pane - 0.1, floor + 0.22], [start, floor + 0.22]].map {
                        HorizonPlan.wallPoint(around: $0[0], height: $0[1], inset: inset + 0.01)
                    }
                    windows.addQuad(corners[0], corners[1], corners[2], corners[3], awayFrom: corners[0] - HorizonPlan.Wall.south.inward, part: lit)
                }
            }
        }

        /// A spire or mast `height` tall on top of `base`, `width` across
        /// at its foot.
        mutating func addSpire(at around: Float, base: Float, width: Float, height: Float, inset: Float) {
            walls.fill([[around - width / 2, base], [around, base], [around, base + height]], inset: inset + 0.005, part: Facade.metal.front)
            walls.fill([[around, base], [around + width / 2, base], [around, base + height]], inset: inset + 0.005, part: Facade.metal.side)
        }
    }

    // MARK: Landmarks

    /// A stone tower stepping back as it rises, with a mast on top.
    private static func addSteppedTower(at around: Float, with painter: inout Painter, random: inout SceneryRandom) {
        var floor: Float = 0
        for (width, height) in [(Float(2.4), Float(8)), (2, 4), (1.5, 2.4), (1, 1.3)] {
            painter.addTower(from: around - width / 2, width: width, height: height, base: floor, facade: .stone, inset: backRow, random: &random)
            floor += height
        }
        painter.addSpire(at: around, base: ground + floor, width: 0.4, height: 4.6, inset: backRow)
        painter.beacons.append(HorizonPlan.wallPoint(around: around, height: ground + floor + 4.6, inset: backRow + 0.05))
    }

    /// A stone tower with a crown of shining tiers, narrowing to a needle.
    private static func addCrownedTower(at around: Float, with painter: inout Painter, random: inout SceneryRandom) {
        painter.addTower(from: around - 1, width: 2, height: 11.5, facade: .stone, inset: backRow, random: &random)
        var base = ground + 11.5
        for (low, high, height) in [(Float(1.1), Float(0.95), Float(0.66)), (0.85, 0.7, 0.55), (0.6, 0.48, 0.55), (0.4, 0.26, 0.55)] {
            painter.walls.fill([[around - low, base], [around, base], [around, base + height], [around - high, base + height]], inset: backRow + 0.005, part: Facade.metal.front)
            painter.walls.fill([[around, base], [around + low, base], [around + high, base + height], [around, base + height]], inset: backRow + 0.005, part: Facade.metal.side)
            base += height
        }
        painter.addSpire(at: around, base: base, width: 0.4, height: 3, inset: backRow)
    }

    /// A glass supertall on a dark base, tapering as it rises, its faces
    /// meeting in long triangles, with a spire on top.
    private static func addSupertall(at around: Float, with painter: inout Painter, random: inout SceneryRandom) {
        painter.addTower(from: around - 1.2, width: 2.4, height: 1.6, facade: .dark, inset: backRow, random: &random)
        let bottom = ground + 1.6, top = bottom + 16.6
        let lower: Float = 1.6, upper: Float = 1.1
        // A face in the light, pointing up, between two in shade.
        painter.walls.fill([[around - lower, bottom], [around + lower, bottom], [around, top]], inset: backRow, part: Facade.glass.front)
        painter.walls.fill([[around - lower, bottom], [around, top], [around - upper, top]], inset: backRow, part: Facade.glass.side)
        painter.walls.fill([[around + lower, bottom], [around + upper, top], [around, top]], inset: backRow, part: Facade.glass.side)
        painter.addWindows(from: bottom, to: top, inset: backRow, random: &random) { height in
            let share = (height - bottom) / (top - bottom)
            let half = lower + (upper - lower) * share
            return (around - half, around + half)
        }
        painter.addSpire(at: around, base: top, width: 0.35, height: 4.4, inset: backRow)
        painter.beacons.append(HorizonPlan.wallPoint(around: around, height: top + 4.4, inset: backRow + 0.05))
    }

    /// A pencil-thin glass tower.
    private static func addPencil(at around: Float, height: Float, with painter: inout Painter, random: inout SceneryRandom) {
        painter.addTower(from: around - 0.55, width: 1.1, height: height, facade: .glass, inset: backRow, random: &random)
        painter.beacons.append(HorizonPlan.wallPoint(around: around - 0.1, height: ground + height + 0.15, inset: backRow + 0.05))
    }

    /// A tall, thin slab of glass, broadside on to the lot.
    private static func addSlab(at around: Float, with painter: inout Painter, random: inout SceneryRandom) {
        painter.addTower(from: around - 1.3, width: 2.6, height: 12.5, facade: .glass, inset: backRow, random: &random)
    }

    /// A red light that blinks on top of a tall tower, for the aeroplanes.
    private static func makeBeacon(at spot: SIMD3<Float>) -> Entity {
        let beacon = Entity()
        beacon.position = spot
        beacon.components.set(BlinkComponent(period: 1.6, onFraction: 0.5))
        let light = ModelEntity(mesh: .generateSphere(radius: 0.15), materials: [UnlitMaterial(color: PlatformColor(red: 1, green: 0.1, blue: 0.08, alpha: 1))])
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
