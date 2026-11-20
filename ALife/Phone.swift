import RealityKit

/// A phone handset ringing over a character's head while it calls you,
/// because it finished a job while you were too far away to hear it.
enum Phone {
    /// A green handset, earpiece and mouthpiece pointing down, made to ring.
    static func makeRingingHandset() -> Entity {
        let material = UnlitMaterial(color: PlatformColor(red: 0.2, green: 0.8, blue: 0.35, alpha: 1))
        let handset = Entity()

        let grip = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.06, depth: 0.04, cornerRadius: 0.02), materials: [material])
        grip.position = [0, 0.07, 0]
        handset.addChild(grip)
        for side: Float in [-1, 1] {
            let end = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.09, depth: 0.05, cornerRadius: 0.025), materials: [material])
            end.position = [side * 0.12, 0.02, 0]
            handset.addChild(end)
        }
        handset.components.set(RingComponent())
        return handset
    }
}

/// A handset that rings: it rattles from side to side and hops in short
/// bursts, with a pause between them, as a phone's bell does.
struct RingComponent: Component {
    /// How long one ring takes, the burst and the pause, in seconds.
    var period: Float = 1.2
    /// How much of each ring it rattles for, in seconds.
    var burst: Float = 0.6
    /// How far into the current ring it is, in seconds.
    fileprivate var elapsed: Float = 0
}

/// Rings every handset with a `RingComponent`, every frame.
struct RingSystem: System {
    private static let ringing = EntityQuery(where: .has(RingComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        for entity in context.entities(matching: Self.ringing, updatingSystemWhen: .rendering) {
            guard var ring = entity.components[RingComponent.self], ring.period > 0 else { continue }
            ring.elapsed = (ring.elapsed + deltaTime).truncatingRemainder(dividingBy: ring.period)
            if ring.elapsed < ring.burst {
                let shake = sin(ring.elapsed * 2 * .pi * 12)
                entity.orientation = simd_quatf(angle: 0.3 * shake, axis: [0, 0, 1])
                entity.position.y = 0.03 * abs(shake)
            } else {
                entity.orientation = simd_quatf(angle: 0, axis: [0, 0, 1])
                entity.position.y = 0
            }
            entity.components[RingComponent.self] = ring
        }
    }
}
