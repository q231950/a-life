import RealityKit

/// Something that turns round and round, such as a wind turbine's rotor.
struct SpinComponent: Component {
    /// The axis it turns about, in its own space.
    var axis: SIMD3<Float>
    /// How fast it turns, in radians per second.
    var speed: Float
}

/// A light that blinks on and off, such as the red light on top of a wind
/// turbine. Its children are the light, shown and hidden in turn.
struct BlinkComponent: Component {
    /// How long one blink takes, on and off, in seconds.
    var period: Float
    /// How much of each blink it is on for, from 0 to 1.
    var onFraction: Float
    /// How far into the current blink it is, in seconds.
    fileprivate var elapsed: Float = 0

    init(period: Float, onFraction: Float) {
        self.period = period
        self.onFraction = onFraction
    }
}

/// Turns everything with a `SpinComponent` and blinks everything with a
/// `BlinkComponent`, every frame. Only what is on the lot is updated, so
/// once a building is taken away its rotor and light simply stop.
struct TurbineSystem: System {
    private static let spinning = EntityQuery(where: .has(SpinComponent.self))
    private static let blinking = EntityQuery(where: .has(BlinkComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)

        for entity in context.entities(matching: Self.spinning, updatingSystemWhen: .rendering) {
            guard let spin = entity.components[SpinComponent.self] else { continue }
            entity.orientation = entity.orientation * simd_quatf(angle: spin.speed * deltaTime, axis: spin.axis)
        }

        for entity in context.entities(matching: Self.blinking, updatingSystemWhen: .rendering) {
            guard var blink = entity.components[BlinkComponent.self], blink.period > 0 else { continue }
            blink.elapsed = (blink.elapsed + deltaTime).truncatingRemainder(dividingBy: blink.period)
            // Its light is a child, so the entity itself stays enabled and
            // keeps being updated while the light is off.
            let isOn = blink.elapsed < blink.period * blink.onFraction
            for light in entity.children where light.isEnabled != isOn {
                light.isEnabled = isOn
            }
            entity.components[BlinkComponent.self] = blink
        }
    }
}
