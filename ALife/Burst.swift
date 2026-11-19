import AVFoundation
import RealityKit

/// What is left of a helper's sheep once it has popped like a balloon: a
/// puff of little scraps of wool and scarf flying out from where it stood,
/// falling and shrinking away, with a pop you can hear. `BurstSystem` moves
/// the scraps, and takes the whole thing away once they're gone.
struct BurstComponent: Component {
    /// How fast each of the burst's children is flying, in metres per
    /// second, and how fast it tumbles, in radians per second.
    var velocities: [SIMD3<Float>]
    var spins: [Float]
    /// How long it has been since the pop, in seconds.
    var age: Float = 0
    /// How long the scraps last.
    static let lifetime: Float = 0.7
}

/// Flies each burst's scraps out and down, shrinking them, and takes the
/// burst away once its time is up.
struct BurstSystem: System {
    private static let query = EntityQuery(where: .has(BurstComponent.self))
    private static let gravity: Float = 7
    /// How much speed the scraps keep after a second: they're light.
    private static let drag: Float = 0.08

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        var done: [Entity] = []
        for burst in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var state = burst.components[BurstComponent.self] else { continue }
            state.age += deltaTime
            let slowing = pow(Self.drag, deltaTime)
            // Full size for the first half, then shrinking away.
            let size = max(0.01, min(1, 2 * (1 - state.age / BurstComponent.lifetime)))
            for (index, scrap) in burst.children.enumerated() where index < state.velocities.count {
                state.velocities[index] *= slowing
                state.velocities[index].y -= Self.gravity * deltaTime
                scrap.position += state.velocities[index] * deltaTime
                scrap.orientation = simd_quatf(angle: state.spins[index] * deltaTime, axis: simd_normalize([1, 0.5, 0.3])) * scrap.orientation
                scrap.scale = SIMD3(repeating: size)
            }
            burst.components[BurstComponent.self] = state
            if state.age >= BurstComponent.lifetime {
                done.append(burst)
            }
        }
        // Not while going through the query's results.
        for burst in done {
            burst.removeFromParent()
        }
    }
}

/// Makes the bursts, and the pop that goes with them.
@MainActor
enum Burst {
    /// A burst of scraps in `colors`, flying out from `centre` in `parent`'s
    /// space, with a pop.
    @discardableResult
    static func pop(at centre: SIMD3<Float>, colors: [PlatformColor], in parent: Entity) -> Entity {
        let burst = Entity()
        burst.name = "Burst"
        burst.position = centre

        let materials = colors.map { SimpleMaterial(color: $0, roughness: 0.8, isMetallic: false) }
        let scrap = MeshResource.generateBox(width: 0.07, height: 0.07, depth: 0.02, cornerRadius: 0.01)
        let count = 18
        var velocities: [SIMD3<Float>] = []
        var spins: [Float] = []
        for index in 0..<count {
            // Out all round, a little upwards, at different speeds.
            let angle = Float(index) / Float(count) * 2 * .pi + .random(in: -0.2...0.2)
            let outward = SIMD3<Float>(sin(angle), 0, cos(angle))
            let speed = Float.random(in: 1.4...2.8)
            let rise = Float.random(in: 0.5...2.4)
            velocities.append(outward * speed + [0, rise, 0])
            spins.append(.random(in: 6...16))
            let piece = ModelEntity(mesh: scrap, materials: [materials.isEmpty ? SimpleMaterial() : materials[index % materials.count]])
            piece.position = outward * 0.08
            piece.orientation = simd_quatf(angle: .random(in: 0..<(2 * .pi)), axis: [0, 1, 0])
            burst.addChild(piece)
        }
        burst.components.set(BurstComponent(velocities: velocities, spins: spins))
        parent.addChild(burst)

        // As loud wherever the camera is: the lot is big, and a pop is short.
        if let sound = popSound {
            burst.components.set(ChannelAudioComponent())
            burst.playAudio(sound)
        }
        return burst
    }

    /// A balloon's pop, made rather than recorded: a sharp crack of noise
    /// over a quick, low thump, all over in a fifth of a second.
    private static let popSound: AudioBufferResource? = {
        let sampleRate = 44_100.0
        let length = AVAudioFrameCount(sampleRate * 0.2)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = length

        var noise: Float = 0
        var phase: Float = 0
        for index in 0..<Int(length) {
            let time = Float(Double(index) / sampleRate)
            // Noise, smoothed a little so it's more snap than hiss.
            noise = noise * 0.35 + Float.random(in: -1...1) * 0.65
            let crack = noise * exp(-time / 0.012)
            // A thump that drops from 180 Hz to 60 as it dies away.
            phase += 2 * .pi * (60 + 120 * exp(-time / 0.03)) / Float(sampleRate)
            let thump = sin(phase) * exp(-time / 0.05)
            let attack = min(1, time / 0.0008)
            samples[index] = attack * (crack * 0.8 + thump * 0.5)
        }
        return try? AudioBufferResource(buffer: buffer)
    }()
}
