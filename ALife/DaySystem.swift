import ALifeClient
import Foundation
import RealityKit

/// Windows that light up at night, such as the city's: a mesh in two parts,
/// windows that stay dark, and windows that are dark by day and lit at
/// night.
struct NightLightsComponent: Component {
    /// The colour of a window by day, and of a lit one at night.
    var off: SIMD3<Float>
    var on: SIMD3<Float>
    /// How lit the windows are, from 0 to 1, as last shown.
    var level: Float = -1

    init(off: SIMD3<Float>, on: SIMD3<Float>) {
        self.off = off
        self.on = on
    }
}

/// Keeps the sky with the camera every frame, and twice a second brings the
/// day up to date from `DayClock`: the sun crossing the sky from east to
/// west, warm at dawn and dusk, the moon and the stars coming out at night
/// with a dim blue moonlight, the sky's colours, and the city's windows
/// lighting up.
struct DaySystem: System {
    private static let skies = EntityQuery(where: .has(SkyComponent.self))
    private static let cameras = EntityQuery(where: .has(PerspectiveCameraComponent.self))
    private static let nightLights = EntityQuery(where: .has(NightLightsComponent.self))
    /// How often the day is brought up to date, in seconds. A day lasts five
    /// hours, so the sun moves only a little in between.
    private static let interval: TimeInterval = 0.5

    /// How bright the sunlight is at noon, and the moonlight at midnight, in lux.
    private static let sunlight: Float = 4000
    private static let moonlight: Float = 350

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let camera = context.entities(matching: Self.cameras, updatingSystemWhen: .rendering).first { _ in true }
        var night: Float?

        for entity in context.entities(matching: Self.skies, updatingSystemWhen: .rendering) {
            if let camera {
                entity.setPosition(camera.position(relativeTo: nil), relativeTo: nil)
            }
            guard var state = entity.components[SkyComponent.self] else { continue }
            let now = Date()
            if let updated = state.updated, now.timeIntervalSince(updated) < Self.interval { continue }
            state.updated = now
            entity.components.set(state)

            let sky = state.clock.sky(at: now)
            show(sky, in: state)
            night = 1 - Float(sky.daylight)
        }

        guard let night else { return }
        for entity in context.entities(matching: Self.nightLights, updatingSystemWhen: .rendering) {
            guard var lights = entity.components[NightLightsComponent.self],
                  abs(lights.level - night) > 0.01,
                  let model = entity as? ModelEntity else { continue }
            lights.level = night
            let lit = SkyDome.mix(lights.off, lights.on, SkyDome.smoothstep(0.2, 0.9, night))
            model.model?.materials = [UnlitMaterial(color: PlatformColor(lights.off)), UnlitMaterial(color: PlatformColor(lit))]
            entity.components.set(lights)
        }
    }

    private func show(_ sky: Sky, in state: SkyComponent) {
        let sun = Self.scene(sky.sun), moon = Self.scene(sky.moon)
        let sunElevation = Float(sky.sun.elevation) * 180 / .pi
        let daylight = Float(sky.daylight), moonlight = Float(sky.moonlight)

        // The sky's colours.
        if let gradient = state.gradient, let image = SkyDome.gradientImage(for: sky) {
            try? gradient.replace(withImage: image, options: .init(semantic: .color, mipmapsMode: .none))
        }

        // The sun's disc, and the moon's.
        state.sun.isEnabled = sunElevation > -5
        state.sun.position = sun * SkyDome.bodyDistance
        var sunMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        sunMaterial.color = .init(tint: PlatformColor(SkyDome.sunColor(in: sky)))
        state.sun.model?.materials = [sunMaterial]

        state.moon.isEnabled = sunElevation < 5
        state.moon.position = moon * SkyDome.bodyDistance
        var moonMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        moonMaterial.color = .init(tint: PlatformColor(SIMD3(0.92, 0.93, 0.98)))
        moonMaterial.blending = .transparent(opacity: .init(floatLiteral: 1 - 0.75 * daylight))
        state.moon.model?.materials = [moonMaterial]

        // The stars, turning round the pole with the sun.
        let starlight = Float(sky.starlight)
        state.stars.isEnabled = starlight > 0.01
        state.stars.orientation = simd_quatf(angle: Float(sky.turn), axis: Self.scene(Sky.pole))
        if var material = state.stars.model?.materials.first as? UnlitMaterial {
            material.blending = .transparent(opacity: .init(floatLiteral: starlight))
            state.stars.model?.materials = [material]
        }

        // The light on the lot: the sun's, warm while it is low, until it
        // is well down, then the moon's, dim and blue. It never comes from
        // lower than a little over the horizon, so shadows don't stretch
        // right across the lot.
        let light = state.sunlight
        let isSunlit = sunElevation > -6
        let from = isSunlit ? sun : moon
        let lowest: Float = 12 * .pi / 180
        let flat = simd_normalize(SIMD3(from.x, 0, from.z) + [0.0001, 0, 0])
        let elevation = max(asin(max(-1, min(1, from.y))), lowest)
        let direction = flat * cos(elevation) + [0, sin(elevation), 0]
        light.look(at: .zero, from: direction * 10, relativeTo: light.parent)
        if isSunlit {
            let height = SkyDome.smoothstep(0, 35, sunElevation)
            light.light.intensity = Self.sunlight * (0.4 + 0.6 * height) * daylight
            light.light.color = PlatformColor(SkyDome.mix(SIMD3(1, 0.68, 0.45), SIMD3(1, 0.98, 0.94), SkyDome.smoothstep(2, 25, sunElevation)))
        } else {
            light.light.intensity = Self.moonlight * moonlight * SkyDome.smoothstep(-6, -12, sunElevation)
            light.light.color = PlatformColor(SIMD3(0.62, 0.72, 1))
        }

        // The soft light from all round: full by day, a little at night.
        if var ambience = state.ambience.components[ImageBasedLightComponent.self] {
            ambience.intensityExponent = -2.6 * (1 - daylight) + 0.6 * moonlight * (1 - daylight)
            state.ambience.components.set(ambience)
        }
    }

    /// `direction` in the lot's space: x and z as on the lot, y up.
    private static func scene(_ direction: SkyDirection) -> SIMD3<Float> {
        let east = SIMD3<Float>(HorizonPlan.east.x, 0, HorizonPlan.east.z)
        let north = SIMD3<Float>(HorizonPlan.north.x, 0, HorizonPlan.north.z)
        return simd_normalize(east * Float(direction.east) + north * Float(direction.north) + [0, Float(direction.up), 0])
    }
}
