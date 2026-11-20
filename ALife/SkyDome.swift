import ALifeClient
import CoreGraphics
import Foundation
import RealityKit

/// The sky over the lot: a dome round the camera, coloured from the horizon
/// up, with the sun crossing it by day and the moon and the stars by night.
/// The dome goes wherever the camera goes, so the sky always looks as far
/// away as it is. `DaySystem` keeps it, the sunlight and the city's windows
/// in step with the time of day, from `DayClock`.
@MainActor
enum SkyDome {
    /// How far from the camera the sun, the moon and the stars are, just
    /// inside the dome.
    nonisolated static let bodyDistance = HorizonPlan.skyRadius * 0.92

    /// The sky, which lights the lot with `sunlight`, and with a soft light
    /// from all round that every entity under `root` takes in.
    static func make(sunlight: DirectionalLight, root: Entity) -> Entity {
        let sky = Entity()
        sky.name = "Sky"

        let gradient = makeGradient(for: Sky(phase: 0.5))
        var domeMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        if let gradient {
            domeMaterial.color = .init(tint: .white, texture: .init(gradient))
        }
        let dome = makeDome(material: domeMaterial)
        sky.addChild(dome)

        let sun = ModelEntity(mesh: .generateSphere(radius: 26), materials: [UnlitMaterial(applyPostProcessToneMap: false)])
        sun.name = "Sun"
        sky.addChild(sun)

        let moon = ModelEntity(mesh: .generateSphere(radius: 18), materials: [UnlitMaterial(applyPostProcessToneMap: false)])
        moon.name = "Moon"
        sky.addChild(moon)

        let stars = makeStars()
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
            dome: dome,
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
        // A haze under the horizon, which only shows between far hills.
        return mix(horizon, horizon * 0.8, min(1, -degrees / 10))
    }

    /// The colour of the sun's disc: white when high, orange near the horizon.
    nonisolated static func sunColor(in sky: Sky) -> SIMD3<Float> {
        mix(SIMD3(1, 0.5, 0.22), SIMD3(1, 0.97, 0.86), smoothstep(0, 20, Float(sky.sun.elevation) * 180 / .pi))
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

    /// A sphere round the camera, facing in, with the gradient running from
    /// the bottom of the sphere to its top.
    private static func makeDome(material: UnlitMaterial) -> ModelEntity {
        let radius = HorizonPlan.skyRadius
        let rings = 64, steps = 48
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], coordinates: [SIMD2<Float>] = []
        for ring in 0...rings {
            let elevation = (Float(ring) / Float(rings) - 0.5) * .pi
            for step in 0...steps {
                let angle = Float(step) / Float(steps) * 2 * .pi
                let outward = SIMD3<Float>(cos(elevation) * sin(angle), sin(elevation), cos(elevation) * cos(angle))
                positions.append(outward * radius)
                normals.append(-outward)
                coordinates.append([Float(step) / Float(steps), Float(ring) / Float(rings)])
            }
        }
        var indices: [UInt32] = []
        for ring in 0..<rings {
            for step in 0..<steps {
                let a = UInt32(ring * (steps + 1) + step), b = a + 1
                let c = a + UInt32(steps + 1), d = c + 1
                // Wound to face the middle.
                indices += [a, c, b, b, c, d]
            }
        }
        var descriptor = MeshDescriptor(name: "Sky")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)
        let dome = ModelEntity()
        dome.name = "Dome"
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            dome.model = ModelComponent(mesh: mesh, materials: [material])
        }
        return dome
    }

    /// Stars all round the sky, as little squares facing the camera, in one
    /// mesh. The ones under the horizon are hidden by the land.
    private static func makeStars() -> ModelEntity {
        var batch = MeshBatch(parts: 1)
        var random = SceneryRandom(seed: 3)
        for _ in 0..<1600 {
            let up = random.next(in: -1...1), angle = random.next(in: 0...(2 * .pi))
            let across = (1 - up * up).squareRoot()
            let outward = SIMD3<Float>(across * sin(angle), up, across * cos(angle))
            let centre = outward * HorizonPlan.skyRadius * 0.95
            let size = random.next(in: 0...1) < 0.06 ? random.next(in: 4...6) : random.next(in: 1.8...3.6)
            let side = simd_normalize(simd_cross(outward, abs(outward.y) < 0.9 ? [0, 1, 0] : [1, 0, 0])) * size / 2
            let other = simd_cross(outward, side)
            batch.addQuad(centre - side - other, centre + side - other, centre + side + other, centre - side + other, awayFrom: centre * 2, part: 0)
        }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: PlatformColor(SIMD3(0.95, 0.96, 1)))
        material.blending = .transparent(opacity: .init(floatLiteral: 0))
        let stars = batch.makeEntity(named: "Stars", materials: [material])
        stars.isEnabled = false
        return stars
    }
}

/// The sky's parts, for `DaySystem` to keep in step with the time of day.
struct SkyComponent: Component {
    let clock: DayClock
    /// The light from the sun by day, and from the moon by night.
    let sunlight: DirectionalLight
    let dome: ModelEntity
    /// The dome's colours, drawn again as the day goes on.
    let gradient: TextureResource?
    let sun: ModelEntity
    let moon: ModelEntity
    let stars: ModelEntity
    /// The soft light from all round.
    let ambience: Entity
    /// When the sky was last brought up to date.
    var updated: Date?
}
