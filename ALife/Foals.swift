import ALifeClient
import RealityKit

/// The foals the Gardener puts out: a bed whose kind is a foal (or a pony,
/// a colt, a filly or a baby horse) has a foal on each tile, on a patch of
/// long grass. They are built like the barn's horses but half their size,
/// with long legs, a short body and neck, a big head and a stubby tail, in
/// the bed's colour or a coat of their own. They are the bed's children, so
/// they go when it is dug up. `BarnSystem` takes them trotting, frisking,
/// grazing and resting round their bed.
@MainActor
enum Foals {
    /// A bed of `item`'s foals, one on each of `tiles`, positions relative
    /// to the bed's centre.
    static func make(_ item: LotItem, tiles: [(x: Int, y: Int, position: SIMD3<Float>)]) -> Entity {
        let bed = Entity()
        bed.name = item.id

        let blades = Buildings.material(PlatformColor(red: 0.42, green: 0.72, blue: 0.28, alpha: 1), roughness: 1)
        let coats: [PlatformColor] = [
            PlatformColor(red: 0.55, green: 0.3, blue: 0.15, alpha: 1), // chestnut
            PlatformColor(red: 0.32, green: 0.2, blue: 0.13, alpha: 1), // bay
            PlatformColor(red: 0.85, green: 0.84, blue: 0.8, alpha: 1), // grey
            PlatformColor(red: 0.85, green: 0.7, blue: 0.44, alpha: 1), // palomino
            PlatformColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1), // black
        ]
        let color = item.color.flatMap(PlatformColor.init(hex:))

        for (index, tile) in tiles.enumerated() {
            // A few tufts of long grass, the same each time it is drawn.
            for (dx, dz) in [(Float(-0.3), Float(-0.25)), (0.28, -0.1), (-0.12, 0.3), (0.2, 0.32)] {
                let mesh = MeshResource.generateCone(height: 0.16, radius: 0.05)
                let tuft = ModelEntity(mesh: mesh, materials: [blades])
                tuft.position = tile.position + [dx, -mesh.bounds.min.y, dz]
                bed.addChild(tuft)
            }

            let foal = makeFoal(coat: color ?? coats[(tile.x &* 7 &+ tile.y &* 3 &+ index) % coats.count], blaze: (tile.x + tile.y).isMultiple(of: 2))
            foal.position = tile.position
            foal.orientation = simd_quatf(angle: .random(in: 0..<(2 * .pi)), axis: [0, 1, 0])
            foal.components.set(WalkComponent())
            foal.components.set(FoalComponent(home: item.area))
            bed.addChild(foal)
        }
        return bed
    }

    /// A foal about half as tall as a horse, facing +z, its parts named as a
    /// horse's are so `BarnSystem` moves them the same way: its body is in
    /// "Gait", with its legs ("FrontLeg" and "BackLeg"), which swing from the
    /// hip, and its neck ("Neck"), which lowers its head. A white blaze runs
    /// down its face if `blaze`.
    private static func makeFoal(coat: PlatformColor, blaze: Bool) -> Entity {
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
