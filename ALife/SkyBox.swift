import ALifeClient
import CoreGraphics
import Foundation
import RealityKit

/// The sky in the lot's box: painted on the walls, behind the world on them
/// (see `Horizon`), and on a flat sky over the top, coloured from the
/// horizon up, with the sun crossing it by day and the moon and the stars
/// by night. Each is painted where you would see it from the middle of the
/// lot (`HorizonPlan.skyPoint`). `DaySystem` keeps it, the sunlight and the
/// world on the walls in step with the time of day, from `DayClock`.
@MainActor
enum SkyBox {
    /// How wide the sun and the moon look, in radians, from the middle of
    /// the lot.
    nonisolated static let sunSize: Float = 0.062
    nonisolated static let moonSize: Float = 0.044
    /// How far in from the sky the sun, the moon and the stars are painted,
    /// in front of the sky but behind the world on the walls.
    nonisolated static let bodyInset: Float = 0.03
    nonisolated static let starInset: Float = 0.02

    /// The sky, which lights the lot with `sunlight`, and with a soft light
    /// from all round that every entity under `root` takes in.
    static func make(sunlight: DirectionalLight, root: Entity) -> Entity {
        let sky = Entity()
        sky.name = "Sky"

        let gradient = makeGradient(for: Sky(phase: 0.5))
        var paint = UnlitMaterial(applyPostProcessToneMap: false)
        if let gradient {
            paint.color = .init(tint: .white, texture: .init(gradient))
        }
        sky.addChild(makeSky(material: paint))

        let disc = makeDisc()
        let sun = ModelEntity(mesh: disc, materials: [UnlitMaterial(applyPostProcessToneMap: false)])
        sun.name = "Sun"
        sky.addChild(sun)

        let moon = ModelEntity(mesh: disc, materials: [UnlitMaterial(applyPostProcessToneMap: false)])
        moon.name = "Moon"
        sky.addChild(moon)

        var starMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        starMaterial.color = .init(tint: PlatformColor(SIMD3(0.95, 0.96, 1)))
        starMaterial.blending = .transparent(opacity: .init(floatLiteral: 0))
        let stars = ModelEntity()
        stars.name = "Stars"
        stars.model = ModelComponent(mesh: .generatePlane(width: 0.01, height: 0.01), materials: [starMaterial])
        stars.isEnabled = false
        sky.addChild(stars)

        // A soft light from all round, the sky's and the ground's, which
        // dims at night.
        let ambience = Entity()
        ambience.name = "Ambience"
        if let image = makeAmbienceImage(), let environment = try? EnvironmentResource(equirectangular: image) {
            ambience.components.set(ImageBasedLightComponent(source: .single(environment)))
            root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ambience))
        }
        sky.addChild(ambience)

        sky.visit { $0.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        sky.components.set(SkyComponent(
            clock: DayClock(),
            sunlight: sunlight,
            gradient: gradient,
            sun: sun,
            moon: moon,
            stars: stars,
            ambience: ambience
        ))
        return sky
    }

    // MARK: Colours

    /// The sky's colour `elevation` radians over the horizon, or under it.
    nonisolated static func color(at elevation: Float, in sky: Sky) -> SIMD3<Float> {
        let daylight = Float(sky.daylight), glow = Float(sky.glow)
        let night = (zenith: SIMD3<Float>(0.01, 0.015, 0.05), horizon: SIMD3<Float>(0.05, 0.08, 0.16))
        let day = (zenith: SIMD3<Float>(0.22, 0.47, 0.85), horizon: SIMD3<Float>(0.72, 0.85, 0.97))
        let dusk = (zenith: SIMD3<Float>(0.24, 0.26, 0.52), horizon: SIMD3<Float>(1, 0.55, 0.25))

        let zenith = mix(mix(night.zenith, day.zenith, daylight), dusk.zenith, glow * 0.5)
        let horizon = mix(mix(night.horizon, day.horizon, daylight), dusk.horizon, glow * 0.95)
        let degrees = elevation * 180 / .pi
        if degrees >= 0 {
            return mix(horizon, zenith, pow(min(1, degrees / 90), 0.45))
        }
        // A haze under the horizon, behind the world on the walls.
        return mix(horizon, horizon * 0.8, min(1, -degrees / 10))
    }

    /// The colour of the sun's disc: white when high, orange near the horizon.
    nonisolated static func sunColor(in sky: Sky) -> SIMD3<Float> {
        mix(SIMD3(1, 0.5, 0.22), SIMD3(1, 0.97, 0.86), smoothstep(0, 20, Float(sky.sun.elevation) * 180 / .pi))
    }

    /// The light the world on the walls is painted in: full by day, warm at
    /// dawn and dusk, and a dim blue at night.
    nonisolated static func paintLight(in sky: Sky) -> SIMD3<Float> {
        let night = SIMD3<Float>(0.15, 0.18, 0.32)
        let light = mix(night, SIMD3(1, 1, 1), Float(sky.daylight))
        return mix(light, light * SIMD3(1, 0.78, 0.62), Float(sky.glow) * 0.6)
    }

    /// A strip of the sky's colours from the top of the sky, at the top of
    /// the image, to the bottom.
    nonisolated static func gradientImage(for sky: Sky) -> CGImage? {
        let rows = 256, columns = 4
        var pixels = [UInt8](repeating: 255, count: rows * columns * 4)
        for row in 0..<rows {
            let elevation = (0.5 - Float(row) / Float(rows - 1)) * .pi
            let color = color(at: elevation, in: sky)
            for column in 0..<columns {
                let index = (row * columns + column) * 4
                pixels[index] = UInt8(max(0, min(1, color.x)) * 255)
                pixels[index + 1] = UInt8(max(0, min(1, color.y)) * 255)
                pixels[index + 2] = UInt8(max(0, min(1, color.z)) * 255)
            }
        }
        return makeImage(pixels, width: columns, height: rows)
    }

    private static func makeGradient(for sky: Sky) -> TextureResource? {
        guard let image = gradientImage(for: sky) else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
    }

    /// What the soft light from all round comes from: a pale sky over
    /// green and brown ground.
    private static func makeAmbienceImage() -> CGImage? {
        let width = 64, height = 32
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let up = 1 - Float(row) / Float(height - 1) * 2 // 1 at the top, -1 at the bottom
            let color = up > 0
                ? mix(SIMD3<Float>(0.78, 0.84, 0.9), SIMD3(0.55, 0.7, 0.92), up)
                : mix(SIMD3<Float>(0.5, 0.52, 0.42), SIMD3(0.35, 0.32, 0.26), -up)
            for column in 0..<width {
                let index = (row * width + column) * 4
                pixels[index] = UInt8(color.x * 255)
                pixels[index + 1] = UInt8(color.y * 255)
                pixels[index + 2] = UInt8(color.z * 255)
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    nonisolated private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    nonisolated static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        a + (b - a) * amount
    }

    /// 0 up to `low`, 1 from `high`, and an S-curve in between.
    nonisolated static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Parts

    /// The sky painted on the inside of the box: on the four walls from the
    /// grass to the top, and flat over them, with the gradient running from
    /// under the horizon to straight up, as seen from the middle of the lot.
    private static func makeSky(material: UnlitMaterial) -> ModelEntity {
        let half = HorizonPlan.halfWidth, top = HorizonPlan.wallHeight
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], coordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        /// A grid of `columns` by `rows` points, `point(column, row)`,
        /// facing `inward`.
        func addGrid(columns: Int, rows: Int, inward: SIMD3<Float>, point: (Int, Int) -> SIMD3<Float>) {
            let first = UInt32(positions.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    let spot = point(column, row)
                    positions.append(spot)
                    normals.append(inward)
                    // Just inside the gradient's ends, so the very top doesn't
                    // wrap round to the bottom.
                    coordinates.append([0.5, min(0.995, max(0.005, (HorizonPlan.skyElevation(at: spot) + .pi / 2) / .pi))])
                }
            }
            for row in 0..<(rows - 1) {
                for column in 0..<(columns - 1) {
                    let a = first + UInt32(row * columns + column), b = a + 1
                    let c = a + UInt32(columns), d = c + 1
                    // Wound to face `inward`.
                    let cross = simd_cross(positions[Int(b)] - positions[Int(a)], positions[Int(c)] - positions[Int(a)])
                    indices += simd_dot(cross, inward) > 0 ? [a, b, c, b, d, c] : [a, c, b, b, c, d]
                }
            }
        }

        // Closer together low down, where the colours change most.
        let heights: [Float] = [0, 1, 2, 3, 4, 5.5, 7, 9, 11, 14, 17, 21, 25, 30, top]
        let steps = 16
        for start in stride(from: Float(0), to: HorizonPlan.perimeter, by: 2 * half) {
            // From one corner of a wall to the next.
            let corner = start + half
            let inward = HorizonPlan.wallSpot(around: corner + half).wall.inward
            addGrid(columns: steps + 1, rows: heights.count, inward: inward) { column, row in
                HorizonPlan.wallPoint(around: corner + Float(column) / Float(steps) * 2 * half, height: heights[row])
            }
        }
        addGrid(columns: steps + 1, rows: steps + 1, inward: [0, -1, 0]) { column, row in
            [-half + Float(column) / Float(steps) * 2 * half, top, -half + Float(row) / Float(steps) * 2 * half]
        }

        var descriptor = MeshDescriptor(name: "Sky")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)
        let sky = ModelEntity()
        sky.name = "Painted sky"
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            sky.model = ModelComponent(mesh: mesh, materials: [material])
        }
        return sky
    }

    /// A round disc of radius 1, facing +z, for the sun and the moon.
    private static func makeDisc() -> MeshResource {
        var batch = MeshBatch(parts: 1)
        let sides = 32
        for side in 0..<sides {
            let a = Float(side) / Float(sides) * 2 * .pi, b = Float(side + 1) / Float(sides) * 2 * .pi
            batch.addTriangle(.zero, [cos(a), sin(a), 0], [cos(b), sin(b), 0], facing: [0, 0, 1], part: 0)
        }
        return batch.makeMesh(named: "Disc") ?? .generatePlane(width: 2, height: 2, cornerRadius: 1)
    }

    /// Puts the sun's or the moon's disc on the sky where it is seen in
    /// `direction`, as big as it looks from the middle of the lot.
    nonisolated static func paint(_ body: Entity, toward direction: SIMD3<Float>, size: Float) {
        let (point, inward) = HorizonPlan.skyPoint(direction: direction)
        body.position = point + inward * bodyInset
        body.orientation = facing(inward)
        body.scale = .one * (size / 2 * simd_distance(point, HorizonPlan.skyCentre))
    }

    /// Turns something facing +z to face `inward`.
    nonisolated private static func facing(_ inward: SIMD3<Float>) -> simd_quatf {
        inward.z < -0.5 ? simd_quatf(angle: .pi, axis: [0, 1, 0]) : simd_quatf(from: [0, 0, 1], to: inward)
    }

    // MARK: Stars

    /// About 1,600 stars all round the sky, by the way each is seen from the
    /// middle of the lot at midnight, and how big it looks, in radians.
    nonisolated static let starField: [(direction: SIMD3<Float>, size: Float)] = {
        var random = SceneryRandom(seed: 3)
        return (0..<1600).map { _ in
            let up = random.next(in: -1...1), angle = random.next(in: 0...(2 * .pi))
            let across = (1 - up * up).squareRoot()
            let direction = SIMD3<Float>(across * sin(angle), up, across * cos(angle))
            let size = random.next(in: 0...1) < 0.06 ? random.next(in: 0.0047...0.007) : random.next(in: 0.0021...0.0042)
            return (direction, size)
        }
    }()

    /// The stars, turned by `turn` round the sky's pole, painted on the sky
    /// as little squares. Those under the walls' tops show between the
    /// world painted on them; those under the horizon are left out.
    nonisolated static func makeStars(turn: simd_quatf) -> MeshResource? {
        var batch = MeshBatch(parts: 1)
        for star in starField {
            let direction = turn.act(star.direction)
            guard direction.y > 0.02 else { continue }
            let (point, inward) = HorizonPlan.skyPoint(direction: direction)
            let size = star.size * simd_distance(point, HorizonPlan.skyCentre)
            let centre = point + inward * starInset
            let side = simd_normalize(simd_cross(inward, abs(inward.y) < 0.9 ? [0, 1, 0] : [1, 0, 0])) * size / 2
            let other = simd_cross(inward, side)
            batch.addQuad(centre - side - other, centre + side - other, centre + side + other, centre - side + other, awayFrom: centre - inward, part: 0)
        }
        return batch.makeMesh(named: "Stars")
    }
}

/// The sky's parts, for `DaySystem` to keep in step with the time of day.
struct SkyComponent: Component {
    let clock: DayClock
    /// The light from the sun by day, and from the moon by night.
    let sunlight: DirectionalLight
    /// The sky's colours, drawn again as the day goes on.
    let gradient: TextureResource?
    let sun: ModelEntity
    let moon: ModelEntity
    let stars: ModelEntity
    /// The soft light from all round.
    let ambience: Entity
    /// When the sky was last brought up to date.
    var updated: Date?
    /// How far round the stars were turned when they were last painted.
    var starTurn: Float?
}
