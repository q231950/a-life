import ALifeClient
import RealityKit

/// The foals the Conservationist puts out, in a bed whose kind is a foal
/// (or a pony, a colt, a filly or a baby horse), which `Animals` lays out.
/// They are built like the barn's horses but half their size, with long
/// legs, a short body and neck, a big head and a stubby tail.
@MainActor
enum Foals {
    /// A foal about half as tall as a horse, facing +z, its parts named as a
    /// horse's are so `BarnSystem` moves them the same way: its body is in
    /// "Gait", with its legs ("FrontLeg" and "BackLeg"), which swing from the
    /// hip, and its neck ("Neck"), which lowers its head. A white blaze runs
    /// down its face if `blaze`.
    static func makeFoal(coat: PlatformColor, blaze: Bool) -> Entity {
        let coat = Buildings.material(coat, roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.12, green: 0.1, blue: 0.09, alpha: 1), roughness: 0.7)
        let white = Buildings.material(PlatformColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1), roughness: 0.7)

        let foal = Entity()
        foal.name = "Foal"
        let gait = Entity()
        gait.name = "Gait"
        foal.addChild(gait)

        // A short body high up on long legs.
        let body = ModelEntity(mesh: .generateBox(width: 0.19, height: 0.19, depth: 0.44, cornerRadius: 0.08), materials: [coat])
        body.position = [0, 0.52, 0]
        gait.addChild(body)

        for z: Float in [0.14, -0.14] {
            for x: Float in [-0.055, 0.055] {
                let hip = Entity()
                hip.name = z > 0 ? "FrontLeg" : "BackLeg"
                hip.position = [x, 0.45, z]
                let leg = ModelEntity(mesh: .generateBox(width: 0.045, height: 0.38, depth: 0.045, cornerRadius: 0.015), materials: [coat])
                leg.position = [0, -0.2, 0]
                hip.addChild(leg)
                let hoof = ModelEntity(mesh: .generateBox(width: 0.055, height: 0.05, depth: 0.06, cornerRadius: 0.015), materials: [dark])
                hoof.position = [0, -0.42, 0.003]
                hip.addChild(hoof)
                gait.addChild(hip)
            }
        }

        // A short neck, nearly upright, with a big head on it.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.56, 0.18]
        gait.addChild(neck)
        let lean: Float = 0.3
        let neckPiece = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.26, depth: 0.12, cornerRadius: 0.04), materials: [coat])
        neckPiece.position = [0, 0.13 * cos(lean), 0.13 * sin(lean)]
        neckPiece.orientation = simd_quatf(angle: lean, axis: [1, 0, 0])
        neck.addChild(neckPiece)
        // A short, fluffy mane.
        let mane = ModelEntity(mesh: .generateBox(width: 0.04, height: 0.2, depth: 0.04, cornerRadius: 0.015), materials: [dark])
        mane.position = [0, 0.02, -0.065]
        neckPiece.addChild(mane)

        let head = ModelEntity(mesh: .generateBox(width: 0.11, height: 0.12, depth: 0.21, cornerRadius: 0.045), materials: [coat])
        head.position = [0, 0.27, 0.13]
        head.orientation = simd_quatf(angle: 0.3, axis: [1, 0, 0]) // nose down a little
        neck.addChild(head)
        if blaze {
            let stripe = ModelEntity(mesh: .generateBox(width: 0.03, height: 0.01, depth: 0.16, cornerRadius: 0.004), materials: [white])
            stripe.position = [0, 0.06, 0.01]
            head.addChild(stripe)
        }
        for x: Float in [-0.035, 0.035] {
            let ear = ModelEntity(mesh: .generateBox(width: 0.03, height: 0.07, depth: 0.025), materials: [coat])
            ear.position = [x, 0.36, 0.07]
            neck.addChild(ear)
        }

        let tail = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.14, depth: 0.05, cornerRadius: 0.02), materials: [dark])
        tail.position = [0, 0.55, -0.25]
        tail.orientation = simd_quatf(angle: -0.6, axis: [1, 0, 0]) // sticking out behind
        gait.addChild(tail)

        return foal
    }
}
