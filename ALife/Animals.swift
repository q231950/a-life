import ALifeClient
import RealityKit

/// The animals the Conservationist puts out: a bed whose kind is an animal
/// (see `LotItem.animal`) has one on each tile, on a patch of long grass:
/// foals, brown bears, bigger polar bears, small birds, unicorns with a
/// golden horn, pegasuses with wings, and the dinosaurs and pterosaurs in
/// `Dinosaurs`. Each is in the bed's colour or a coat of its own. They are
/// the bed's children, so they go when it is dug up, and their parts are
/// named as a horse's are ("Gait", "FrontLeg", "BackLeg", "Neck", and
/// "Wing" for those that fly), so `BarnSystem` takes them all playing round
/// their bed the same way.
@MainActor
enum Animals {
    /// A bed of `item`'s animals, `animal`s, one on each of `tiles`,
    /// positions relative to the bed's centre.
    static func make(_ item: LotItem, as animal: LotItem.Animal, tiles: [(x: Int, y: Int, position: SIMD3<Float>)]) -> Entity {
        let bed = Entity()
        bed.name = item.id

        let blades = Buildings.material(PlatformColor(red: 0.42, green: 0.72, blue: 0.28, alpha: 1), roughness: 1)
        let coats = coats(of: animal)
        let color = item.color.flatMap(PlatformColor.init(hex:))

        for (index, tile) in tiles.enumerated() {
            // A few tufts of long grass, the same each time it is drawn.
            for (dx, dz) in [(Float(-0.3), Float(-0.25)), (0.28, -0.1), (-0.12, 0.3), (0.2, 0.32)] {
                let mesh = MeshResource.generateCone(height: 0.16, radius: 0.05)
                let tuft = ModelEntity(mesh: mesh, materials: [blades])
                tuft.position = tile.position + [dx, -mesh.bounds.min.y, dz]
                bed.addChild(tuft)
            }

            // The same coat for the same tile each time it is drawn.
            let pick = tile.x &* 7 &+ tile.y &* 3 &+ index
            let coat = color ?? coats[pick % coats.count]
            let creature: Entity
            switch animal {
            case .foal: creature = Foals.makeFoal(coat: coat, blaze: (tile.x + tile.y).isMultiple(of: 2))
            case .bear: creature = makeBear(coat: coat, polar: false)
            case .polarBear: creature = makeBear(coat: coat, polar: true)
            case .bird: creature = makeBird(feathers: coat)
            case .unicorn: creature = makeUnicorn(coat: coat, mane: manes[pick % manes.count])
            case .pegasus: creature = makePegasus(coat: coat)
            case .stegosaurus: creature = Dinosaurs.makeStegosaurus(hide: coat)
            case .diplodocus: creature = Dinosaurs.makeDiplodocus(hide: coat)
            case .pterosaur: creature = Dinosaurs.makePterosaur(hide: coat)
            case .triceratops: creature = Dinosaurs.makeTriceratops(hide: coat)
            case .tyrannosaurus: creature = Dinosaurs.makeTyrannosaurus(hide: coat)
            }
            creature.position = tile.position
            creature.orientation = simd_quatf(angle: .random(in: 0..<(2 * .pi)), axis: [0, 1, 0])
            creature.components.set(WalkComponent())
            creature.components.set(AnimalComponent(animal: animal, home: item.area))
            bed.addChild(creature)
        }
        return bed
    }

    /// The coats `animal`s come in when their bed has no colour. The first
    /// is the one in its picture in the Conservationist's conversation.
    static func coats(of animal: LotItem.Animal) -> [PlatformColor] {
        switch animal {
        case .foal:
            [
                PlatformColor(red: 0.55, green: 0.3, blue: 0.15, alpha: 1), // chestnut
                PlatformColor(red: 0.32, green: 0.2, blue: 0.13, alpha: 1), // bay
                PlatformColor(red: 0.85, green: 0.84, blue: 0.8, alpha: 1), // grey
                PlatformColor(red: 0.85, green: 0.7, blue: 0.44, alpha: 1), // palomino
                PlatformColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1), // black
            ]
        case .bear:
            [
                PlatformColor(red: 0.42, green: 0.26, blue: 0.15, alpha: 1), // brown
                PlatformColor(red: 0.3, green: 0.19, blue: 0.11, alpha: 1), // dark brown
                PlatformColor(red: 0.6, green: 0.36, blue: 0.18, alpha: 1), // cinnamon
                PlatformColor(red: 0.54, green: 0.42, blue: 0.27, alpha: 1), // grizzled
            ]
        case .polarBear:
            [
                PlatformColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1), // white
                PlatformColor(red: 0.94, green: 0.91, blue: 0.82, alpha: 1), // cream
            ]
        case .bird:
            [
                PlatformColor(red: 0.25, green: 0.44, blue: 0.85, alpha: 1), // blue
                PlatformColor(red: 0.84, green: 0.15, blue: 0.24, alpha: 1), // red
                PlatformColor(red: 0.96, green: 0.82, blue: 0.19, alpha: 1), // yellow
                PlatformColor(red: 0.54, green: 0.35, blue: 0.2, alpha: 1), // brown
                PlatformColor(red: 0.3, green: 0.62, blue: 0.35, alpha: 1), // green
            ]
        case .unicorn:
            [
                PlatformColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1), // white
                PlatformColor(red: 0.95, green: 0.91, blue: 0.84, alpha: 1), // cream
                PlatformColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1), // silver
            ]
        case .pegasus:
            [
                PlatformColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1), // white
                PlatformColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1), // silver
                PlatformColor(red: 0.72, green: 0.71, blue: 0.69, alpha: 1), // grey
            ]
        case .stegosaurus:
            [
                PlatformColor(red: 0.42, green: 0.48, blue: 0.23, alpha: 1), // olive
                PlatformColor(red: 0.6, green: 0.5, blue: 0.32, alpha: 1), // sand
                PlatformColor(red: 0.5, green: 0.32, blue: 0.2, alpha: 1), // rust
            ]
        case .diplodocus:
            [
                PlatformColor(red: 0.5, green: 0.53, blue: 0.48, alpha: 1), // grey-green
                PlatformColor(red: 0.43, green: 0.48, blue: 0.53, alpha: 1), // slate
                PlatformColor(red: 0.66, green: 0.58, blue: 0.42, alpha: 1), // sand
            ]
        case .pterosaur:
            [
                PlatformColor(red: 0.63, green: 0.36, blue: 0.22, alpha: 1), // rust
                PlatformColor(red: 0.55, green: 0.53, blue: 0.5, alpha: 1), // grey
                PlatformColor(red: 0.72, green: 0.58, blue: 0.35, alpha: 1), // ochre
            ]
        case .triceratops:
            [
                PlatformColor(red: 0.62, green: 0.52, blue: 0.36, alpha: 1), // sand
                PlatformColor(red: 0.4, green: 0.45, blue: 0.27, alpha: 1), // olive
                PlatformColor(red: 0.45, green: 0.36, blue: 0.28, alpha: 1), // brown
            ]
        case .tyrannosaurus:
            [
                PlatformColor(red: 0.3, green: 0.4, blue: 0.24, alpha: 1), // dark green
                PlatformColor(red: 0.42, green: 0.33, blue: 0.24, alpha: 1), // brown
                PlatformColor(red: 0.45, green: 0.44, blue: 0.4, alpha: 1), // grey
            ]
        }
    }

    /// A unicorn's pastel mane and tail.
    private static let manes: [PlatformColor] = [
        PlatformColor(red: 0.95, green: 0.6, blue: 0.78, alpha: 1), // pink
        PlatformColor(red: 0.72, green: 0.6, blue: 0.9, alpha: 1), // lilac
        PlatformColor(red: 0.55, green: 0.8, blue: 0.95, alpha: 1), // sky blue
        PlatformColor(red: 0.95, green: 0.82, blue: 0.45, alpha: 1), // gold
    ]

    // MARK: Bears

    /// A bear facing +z, low and broad on short, thick legs, with a round
    /// head, a pale muzzle and small round ears. A brown bear has a hump at
    /// its shoulders; a polar bear has none, a longer neck, and is a third
    /// bigger. Its parts are named as a horse's are.
    private static func makeBear(coat color: PlatformColor, polar: Bool) -> Entity {
        let coat = Buildings.material(color, roughness: 0.95)
        let muzzle = Buildings.material(color.mixed(with: PlatformColor(red: 0.85, green: 0.74, blue: 0.58, alpha: 1), by: polar ? 0.15 : 0.45), roughness: 0.9)
        let dark = Buildings.material(PlatformColor(red: 0.1, green: 0.09, blue: 0.09, alpha: 1), roughness: 0.5)

        let bear = Entity()
        bear.name = polar ? "PolarBear" : "Bear"
        let gait = Entity()
        gait.name = "Gait"
        bear.addChild(gait)

        let body = ModelEntity(mesh: .generateBox(width: 0.36, height: 0.32, depth: 0.62, cornerRadius: 0.14), materials: [coat])
        body.position = [0, 0.42, 0]
        gait.addChild(body)
        if !polar {
            let hump = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [coat])
            hump.position = [0, 0.53, 0.15]
            gait.addChild(hump)
        }

        for z: Float in [0.19, -0.19] {
            for x: Float in [-0.11, 0.11] {
                let hip = Entity()
                hip.name = z > 0 ? "FrontLeg" : "BackLeg"
                hip.position = [x, 0.32, z]
                let leg = ModelEntity(mesh: .generateBox(width: 0.11, height: 0.3, depth: 0.12, cornerRadius: 0.04), materials: [coat])
                leg.position = [0, -0.16, 0]
                hip.addChild(leg)
                let paw = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.05, depth: 0.15, cornerRadius: 0.02), materials: [coat])
                paw.position = [0, -0.3, 0.02]
                hip.addChild(paw)
                gait.addChild(hip)
            }
        }

        // A short, thick neck, held low, with the head on its end.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.46, 0.28]
        gait.addChild(neck)
        let reach: Float = polar ? 0.1 : 0
        let neckPiece = ModelEntity(mesh: .generateBox(width: 0.2, height: 0.19, depth: 0.16 + reach, cornerRadius: 0.07), materials: [coat])
        neckPiece.position = [0, 0, 0.06 + reach / 2]
        neck.addChild(neckPiece)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [coat])
        head.scale = [1, 0.9, 1.05]
        head.position = [0, 0.03, 0.17 + reach]
        neck.addChild(head)
        let snout = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.08, depth: 0.12, cornerRadius: 0.035), materials: [muzzle])
        snout.position = [0, -0.01, 0.29 + reach]
        neck.addChild(snout)
        let nose = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.035, depth: 0.03, cornerRadius: 0.012), materials: [dark])
        nose.position = [0, 0.02, 0.35 + reach]
        neck.addChild(nose)
        for x: Float in [-0.08, 0.08] {
            let ear = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [coat])
            ear.position = [x, 0.13, 0.14 + reach]
            neck.addChild(ear)
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.014), materials: [dark])
            eye.position = [x * 0.6, 0.07, 0.26 + reach]
            neck.addChild(eye)
        }

        let tail = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [coat])
        tail.position = [0, 0.5, -0.31]
        gait.addChild(tail)

        if polar {
            bear.scale = SIMD3(repeating: 1.35)
        }
        return bear
    }

    // MARK: Birds

    /// A small, round bird facing +z, in `feathers` with a paler breast, a
    /// beak and a tail, and two wings ("Wing") that fold along its back and
    /// flap as it flies. Its head is on "Neck", which dips to peck.
    private static func makeBird(feathers color: PlatformColor) -> Entity {
        let feathers = Buildings.material(color, roughness: 0.8)
        let breast = Buildings.material(color.mixed(with: PlatformColor(red: 0.98, green: 0.95, blue: 0.85, alpha: 1), by: 0.55), roughness: 0.85)
        let wingColor = Buildings.material(color.mixed(with: PlatformColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1), by: 0.25), roughness: 0.8)
        let beak = Buildings.material(PlatformColor(red: 0.96, green: 0.65, blue: 0.15, alpha: 1), roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)

        let bird = Entity()
        bird.name = "Bird"
        let gait = Entity()
        gait.name = "Gait"
        bird.addChild(gait)

        for x: Float in [-0.016, 0.016] {
            let leg = ModelEntity(mesh: .generateBox(width: 0.008, height: 0.05, depth: 0.008), materials: [beak])
            leg.position = [x, 0.025, 0]
            gait.addChild(leg)
        }
        let body = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [feathers])
        body.scale = [0.9, 0.85, 1.3]
        body.position = [0, 0.09, 0]
        gait.addChild(body)
        let front = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [breast])
        front.position = [0, 0.08, 0.03]
        gait.addChild(front)
        let tail = ModelEntity(mesh: .generateBox(width: 0.045, height: 0.008, depth: 0.07, cornerRadius: 0.003), materials: [wingColor])
        tail.position = [0, 0.11, -0.09]
        tail.orientation = simd_quatf(angle: -0.4, axis: [1, 0, 0]) // cocked up
        gait.addChild(tail)

        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.12, 0.05]
        gait.addChild(neck)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [feathers])
        head.position = [0, 0.02, 0.02]
        neck.addChild(head)
        let bill = ModelEntity(mesh: .generateCone(height: 0.035, radius: 0.011), materials: [beak])
        bill.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) // pointing forwards
        bill.position = [0, 0.015, 0.065]
        neck.addChild(bill)
        for x: Float in [-0.025, 0.025] {
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.007), materials: [dark])
            eye.position = [x, 0.03, 0.04]
            neck.addChild(eye)
        }

        for side: Float in [-1, 1] {
            let wing = Entity()
            wing.name = "Wing"
            wing.position = [side * 0.04, 0.115, 0.01]
            let feather = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.008, depth: 0.065, cornerRadius: 0.003), materials: [wingColor])
            feather.position = [side * 0.05, 0, -0.005]
            wing.addChild(feather)
            gait.addChild(wing)
        }

        // Big enough to see from across the lot.
        bird.scale = SIMD3(repeating: 1.6)
        return bird
    }

    // MARK: Unicorns and pegasuses

    /// A horse with a pastel `mane` and tail, and a golden horn on its
    /// forehead, pointing forwards and up.
    private static func makeUnicorn(coat: PlatformColor, mane: PlatformColor) -> Entity {
        let unicorn = Barn.makeHorse(coat: coat, mane: mane)
        unicorn.name = "Unicorn"
        let gold = Buildings.material(PlatformColor(red: 0.95, green: 0.78, blue: 0.3, alpha: 1), roughness: 0.3)
        if let head = unicorn.findEntity(named: "Head") {
            let root = Entity()
            root.position = [0, 0.07, 0.07]
            root.orientation = simd_quatf(angle: 0.55, axis: [1, 0, 0]) // forwards and up
            let horn = ModelEntity(mesh: .generateCone(height: 0.24, radius: 0.026), materials: [gold])
            horn.position = [0, 0.12, 0]
            root.addChild(horn)
            // A few twists round it.
            for step in 0..<3 {
                let twist = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.026 * (1 - Float(step) * 0.28)), materials: [gold])
                twist.position = [0, 0.035 + Float(step) * 0.055, 0]
                twist.orientation = simd_quatf(angle: 0.25, axis: [0, 0, 1])
                root.addChild(twist)
            }
            head.addChild(root)
        }
        return unicorn
    }

    /// A horse with a big feathered wing ("Wing") at each shoulder, which
    /// it folds back along its sides on the ground and spreads and flaps to
    /// fly.
    private static func makePegasus(coat color: PlatformColor) -> Entity {
        let pegasus = Barn.makeHorse(coat: color)
        pegasus.name = "Pegasus"
        let feathers = Buildings.material(color.mixed(with: PlatformColor(red: 1, green: 1, blue: 1, alpha: 1), by: 0.4), roughness: 0.8)
        let tips = Buildings.material(color.mixed(with: PlatformColor(red: 0.75, green: 0.78, blue: 0.85, alpha: 1), by: 0.3), roughness: 0.8)
        guard let gait = pegasus.findEntity(named: "Gait") else { return pegasus }
        for side: Float in [-1, 1] {
            let wing = Entity()
            wing.name = "Wing"
            wing.position = [side * 0.13, 0.8, 0.14]
            let inner = ModelEntity(mesh: .generateBox(width: 0.38, height: 0.03, depth: 0.28, cornerRadius: 0.012), materials: [feathers])
            inner.position = [side * 0.19, 0, 0]
            wing.addChild(inner)
            let outer = ModelEntity(mesh: .generateBox(width: 0.32, height: 0.022, depth: 0.2, cornerRadius: 0.01), materials: [tips])
            outer.position = [side * 0.52, 0, -0.04]
            wing.addChild(outer)
            gait.addChild(wing)
        }
        return pegasus
    }
}
