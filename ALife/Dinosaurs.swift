import RealityKit

/// The Conservationist's dinosaurs, and the pterosaurs that fly over them,
/// each facing +z with its feet on the floor. Their parts are named as a
/// horse's are ("Gait", "FrontLeg", "BackLeg", "Neck", and "Wing" for the
/// pterosaur), with "Leg" for each of a tyrannosaurus's two legs, "Tail" for
/// a tail that sways as it goes and lashes as it frisks, and "Jaw" for a
/// tyrannosaurus's lower jaw, which drops as it roars, so `BarnSystem` takes
/// them playing round their bed as it does the other animals.
@MainActor
enum Dinosaurs {
    // MARK: Stegosaurus

    /// A stegosaurus: a bulky body, highest at the hips, on short front legs
    /// and longer back ones, a small head held low, two staggered rows of
    /// plates down its back, and four spikes at the end of its tail.
    static func makeStegosaurus(hide color: PlatformColor) -> Entity {
        let hide = Buildings.material(color, roughness: 0.85)
        let plates = Buildings.material(color.mixed(with: PlatformColor(red: 0.86, green: 0.42, blue: 0.2, alpha: 1), by: 0.55), roughness: 0.7)
        let bone = Buildings.material(PlatformColor(red: 0.9, green: 0.85, blue: 0.72, alpha: 1), roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)

        let stegosaurus = Entity()
        stegosaurus.name = "Stegosaurus"
        let gait = Entity()
        gait.name = "Gait"
        stegosaurus.addChild(gait)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.3), materials: [hide])
        body.scale = [0.85, 0.85, 1.65]
        body.position = [0, 0.75, -0.05]
        gait.addChild(body)

        addLegs(to: gait, front: (z: 0.28, y: 0.5), back: (z: -0.3, y: 0.58), apart: 0.15, thickness: 0.12, material: hide)

        // A small head on a short neck, held low.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.66, 0.38]
        gait.addChild(neck)
        neck.addChild(segment(from: .zero, to: [0, -0.1, 0.24], width: 0.15, height: 0.15, material: hide))
        let head = ModelEntity(mesh: .generateBox(width: 0.13, height: 0.12, depth: 0.22, cornerRadius: 0.05), materials: [hide])
        head.position = [0, -0.12, 0.34]
        neck.addChild(head)
        addEyes(to: neck, at: [0, -0.08, 0.38], apart: 0.065, size: 0.014, material: dark)

        // Two rows of plates, tallest over the hips, a little staggered.
        for step in 0..<6 {
            let z = 0.36 - Float(step) * 0.15
            let along = (z + 0.05) / 0.5
            let top = 0.75 + 0.255 * sqrt(max(0, 1 - along * along))
            let size = 0.13 + 0.11 * sin(Float(step + 1) / 7 * .pi)
            for side: Float in [-1, 1] {
                let plate = ModelEntity(mesh: .generateBox(width: 0.025, height: size, depth: size, cornerRadius: 0.01), materials: [plates])
                plate.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0]) // a diamond, seen from the side
                plate.position = [side * 0.05, top + size * 0.35, z + side * 0.04]
                gait.addChild(plate)
            }
        }

        let tail = Entity()
        tail.name = "Tail"
        tail.position = [0, 0.74, -0.5]
        gait.addChild(tail)
        tail.addChild(segment(from: .zero, to: [0, -0.1, -0.35], width: 0.2, height: 0.18, material: hide))
        tail.addChild(segment(from: [0, -0.1, -0.35], to: [0, -0.16, -0.68], width: 0.11, height: 0.1, material: hide))
        for (index, z) in [Float(-0.12), -0.3].enumerated() {
            let size: Float = index == 0 ? 0.14 : 0.1
            let plate = ModelEntity(mesh: .generateBox(width: 0.025, height: size, depth: size, cornerRadius: 0.01), materials: [plates])
            plate.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
            plate.position = [0, 0.06 + z * 0.3, z]
            tail.addChild(plate)
        }
        // The spikes, two to each side, pointing out and up.
        for side: Float in [-1, 1] {
            for z: Float in [-0.56, -0.66] {
                let spike = ModelEntity(mesh: .generateCone(height: 0.2, radius: 0.025), materials: [bone])
                spike.orientation = simd_quatf(angle: -side * 1.05, axis: [0, 0, 1])
                spike.position = [side * 0.1, -0.11, z]
                tail.addChild(spike)
            }
        }
        return stegosaurus
    }

    // MARK: Diplodocus

    /// A diplodocus: a big body on four thick, pillar-like legs, a very long
    /// neck that curves up and forwards to a small head, and an even longer
    /// tail that tapers to a whip.
    static func makeDiplodocus(hide color: PlatformColor) -> Entity {
        let hide = Buildings.material(color, roughness: 0.85)
        let belly = Buildings.material(color.mixed(with: PlatformColor(red: 0.92, green: 0.88, blue: 0.78, alpha: 1), by: 0.35), roughness: 0.85)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)

        let diplodocus = Entity()
        diplodocus.name = "Diplodocus"
        let gait = Entity()
        gait.name = "Gait"
        diplodocus.addChild(gait)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.35), materials: [hide])
        body.scale = [0.9, 0.85, 1.7]
        body.position = [0, 0.95, 0]
        gait.addChild(body)
        let underside = ModelEntity(mesh: .generateSphere(radius: 0.3), materials: [belly])
        underside.scale = [0.9, 0.6, 1.6]
        underside.position = [0, 0.85, 0]
        gait.addChild(underside)

        addLegs(to: gait, front: (z: 0.36, y: 0.75), back: (z: -0.36, y: 0.8), apart: 0.17, thickness: 0.16, material: hide)

        // The long neck, in pieces that taper as it curves up to the head.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 1.02, 0.5]
        gait.addChild(neck)
        let spine: [SIMD3<Float>] = [.zero, [0, 0.32, 0.3], [0, 0.6, 0.62], [0, 0.78, 0.96]]
        for index in 0..<(spine.count - 1) {
            let thickness = 0.24 - Float(index) * 0.05
            neck.addChild(segment(from: spine[index], to: spine[index + 1], width: thickness, height: thickness, material: hide))
        }
        let head = ModelEntity(mesh: .generateBox(width: 0.11, height: 0.1, depth: 0.22, cornerRadius: 0.04), materials: [hide])
        head.position = [0, 0.8, 1.06]
        head.orientation = simd_quatf(angle: 0.3, axis: [1, 0, 0]) // nose down a little
        neck.addChild(head)
        addEyes(to: neck, at: [0, 0.84, 1.06], apart: 0.06, size: 0.013, material: dark)

        // The tail, out behind and tapering to a whip.
        let tail = Entity()
        tail.name = "Tail"
        tail.position = [0, 0.95, -0.55]
        gait.addChild(tail)
        let whip: [SIMD3<Float>] = [.zero, [0, -0.12, -0.45], [0, -0.22, -0.95], [0, -0.24, -1.45], [0, -0.2, -1.9]]
        for index in 0..<(whip.count - 1) {
            let thickness = 0.22 - Float(index) * 0.05
            tail.addChild(segment(from: whip[index], to: whip[index + 1], width: thickness, height: thickness, material: hide))
        }

        // Big, but not so big that a bed of them fills the lot.
        diplodocus.scale = SIMD3(repeating: 0.85)
        return diplodocus
    }

    // MARK: Pterosaur

    /// A pterosaur: a small body on folded wings and short legs, a long,
    /// pointed beak with a crest sweeping back from the head, and big
    /// leathery wings ("Wing") that fold back along its sides on the ground
    /// and spread and beat to fly.
    static func makePterosaur(hide color: PlatformColor) -> Entity {
        let hide = Buildings.material(color, roughness: 0.8)
        let membrane = Buildings.material(color.mixed(with: PlatformColor(red: 0.45, green: 0.2, blue: 0.12, alpha: 1), by: 0.35), roughness: 0.75)
        let crest = Buildings.material(PlatformColor(red: 0.9, green: 0.38, blue: 0.18, alpha: 1), roughness: 0.6)
        let beak = Buildings.material(color.mixed(with: PlatformColor(red: 0.95, green: 0.85, blue: 0.55, alpha: 1), by: 0.5), roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)

        let pterosaur = Entity()
        pterosaur.name = "Pterosaur"
        let gait = Entity()
        gait.name = "Gait"
        pterosaur.addChild(gait)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.1), materials: [hide])
        body.scale = [0.9, 0.9, 1.5]
        body.position = [0, 0.36, 0]
        gait.addChild(body)

        // It walks on its folded wings in front, and short legs behind.
        for x: Float in [-0.1, 0.1] {
            let arm = Entity()
            arm.name = "FrontLeg"
            arm.position = [x, 0.36, 0.08]
            arm.addChild(segment(from: .zero, to: [x * 0.4, -0.34, 0.04], width: 0.035, height: 0.035, material: membrane))
            gait.addChild(arm)
            let leg = Entity()
            leg.name = "BackLeg"
            leg.position = [x * 0.6, 0.3, -0.07]
            leg.addChild(segment(from: .zero, to: [0, -0.28, 0.02], width: 0.03, height: 0.03, material: hide))
            let foot = ModelEntity(mesh: .generateBox(width: 0.04, height: 0.015, depth: 0.06, cornerRadius: 0.006), materials: [hide])
            foot.position = [0, -0.29, 0.03]
            leg.addChild(foot)
            gait.addChild(leg)
        }

        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.4, 0.12]
        gait.addChild(neck)
        neck.addChild(segment(from: .zero, to: [0, 0.14, 0.08], width: 0.05, height: 0.05, material: hide))
        let skull = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [hide])
        skull.scale = [0.8, 0.9, 1.2]
        skull.position = [0, 0.16, 0.1]
        neck.addChild(skull)
        let bill = ModelEntity(mesh: .generateCone(height: 0.3, radius: 0.03), materials: [beak])
        bill.orientation = simd_quatf(angle: .pi / 2 + 0.1, axis: [1, 0, 0]) // forwards, a little down
        bill.position = [0, 0.14, 0.27]
        neck.addChild(bill)
        let comb = ModelEntity(mesh: .generateCone(height: 0.22, radius: 0.035), materials: [crest])
        comb.orientation = simd_quatf(angle: -1.0, axis: [1, 0, 0]) // back and up
        comb.scale = [0.4, 1, 1]
        comb.position = [0, 0.24, 0.02]
        neck.addChild(comb)
        addEyes(to: neck, at: [0, 0.18, 0.13], apart: 0.06, size: 0.011, material: dark)

        for side: Float in [-1, 1] {
            let wing = Entity()
            wing.name = "Wing"
            wing.position = [side * 0.07, 0.41, 0.05]
            let inner = ModelEntity(mesh: .generateBox(width: 0.42, height: 0.018, depth: 0.24, cornerRadius: 0.008), materials: [membrane])
            inner.position = [side * 0.21, 0, -0.03]
            wing.addChild(inner)
            let outer = ModelEntity(mesh: .generateBox(width: 0.36, height: 0.014, depth: 0.12, cornerRadius: 0.006), materials: [membrane])
            outer.position = [side * 0.57, 0, 0.02]
            wing.addChild(outer)
            // The long finger along the wing's front edge.
            let finger = ModelEntity(mesh: .generateBox(width: 0.78, height: 0.025, depth: 0.025, cornerRadius: 0.01), materials: [hide])
            finger.position = [side * 0.39, 0.005, 0.085]
            wing.addChild(finger)
            gait.addChild(wing)
        }

        pterosaur.scale = SIMD3(repeating: 1.2)
        return pterosaur
    }

    // MARK: Triceratops

    /// A triceratops: a broad, heavy body on four thick legs, a big head
    /// with a parrot's beak, a short horn on its nose and two long ones over
    /// its eyes, a wide bony frill behind them, and a short, thick tail.
    static func makeTriceratops(hide color: PlatformColor) -> Entity {
        let hide = Buildings.material(color, roughness: 0.85)
        let frillColor = Buildings.material(color.mixed(with: PlatformColor(red: 0.85, green: 0.5, blue: 0.22, alpha: 1), by: 0.4), roughness: 0.75)
        let rimColor = Buildings.material(color.mixed(with: PlatformColor(red: 0.2, green: 0.15, blue: 0.12, alpha: 1), by: 0.4), roughness: 0.8)
        let bone = Buildings.material(PlatformColor(red: 0.92, green: 0.88, blue: 0.76, alpha: 1), roughness: 0.55)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)

        let triceratops = Entity()
        triceratops.name = "Triceratops"
        let gait = Entity()
        gait.name = "Gait"
        triceratops.addChild(gait)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.3), materials: [hide])
        body.scale = [1, 0.85, 1.55]
        body.position = [0, 0.64, 0]
        gait.addChild(body)

        addLegs(to: gait, front: (z: 0.28, y: 0.44), back: (z: -0.28, y: 0.47), apart: 0.17, thickness: 0.13, material: hide)

        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 0.62, 0.42]
        gait.addChild(neck)
        let skull = ModelEntity(mesh: .generateBox(width: 0.26, height: 0.24, depth: 0.34, cornerRadius: 0.08), materials: [hide])
        skull.position = [0, 0, 0.18]
        neck.addChild(skull)
        let snout = ModelEntity(mesh: .generateBox(width: 0.16, height: 0.16, depth: 0.16, cornerRadius: 0.05), materials: [hide])
        snout.position = [0, -0.04, 0.38]
        neck.addChild(snout)
        let beak = ModelEntity(mesh: .generateCone(height: 0.12, radius: 0.06), materials: [rimColor])
        beak.orientation = simd_quatf(angle: .pi / 2 + 0.5, axis: [1, 0, 0]) // forwards and down
        beak.position = [0, -0.08, 0.49]
        neck.addChild(beak)

        // A short horn on the nose, and two long ones over the eyes.
        let noseHorn = ModelEntity(mesh: .generateCone(height: 0.11, radius: 0.035), materials: [bone])
        noseHorn.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
        noseHorn.position = [0, 0.08, 0.41]
        neck.addChild(noseHorn)
        for side: Float in [-1, 1] {
            let horn = ModelEntity(mesh: .generateCone(height: 0.3, radius: 0.04), materials: [bone])
            horn.orientation = simd_quatf(angle: 1.05, axis: [1, 0, 0]) * simd_quatf(angle: -side * 0.15, axis: [0, 0, 1])
            horn.position = [side * 0.08, 0.17, 0.33]
            neck.addChild(horn)
        }
        addEyes(to: neck, at: [0, 0.06, 0.28], apart: 0.27, size: 0.018, material: dark)

        // The frill, a wide disc behind the horns leaning back, with a dark rim.
        let lean = simd_quatf(angle: 1.15, axis: [1, 0, 0])
        let frill = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: 0.3), materials: [frillColor])
        frill.orientation = lean
        frill.position = [0, 0.16, 0.04]
        neck.addChild(frill)
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.34), materials: [rimColor])
        rim.orientation = lean
        rim.position = [0, 0.15, 0.02]
        neck.addChild(rim)

        let tail = Entity()
        tail.name = "Tail"
        tail.position = [0, 0.62, -0.44]
        gait.addChild(tail)
        tail.addChild(segment(from: .zero, to: [0, -0.14, -0.3], width: 0.2, height: 0.18, material: hide))
        tail.addChild(segment(from: [0, -0.14, -0.3], to: [0, -0.26, -0.58], width: 0.1, height: 0.09, material: hide))
        return triceratops
    }

    // MARK: Tyrannosaurus

    /// A tyrannosaurus, upright on two strong legs ("Leg"), its body held
    /// level over them, balanced by a long, heavy tail, with two tiny arms,
    /// and a big head full of teeth, whose lower jaw ("Jaw") drops as it
    /// roars.
    static func makeTyrannosaurus(hide color: PlatformColor) -> Entity {
        let hide = Buildings.material(color, roughness: 0.8)
        let belly = Buildings.material(color.mixed(with: PlatformColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1), by: 0.4), roughness: 0.85)
        let teeth = Buildings.material(PlatformColor(red: 0.97, green: 0.95, blue: 0.88, alpha: 1), roughness: 0.4)
        let mouth = Buildings.material(PlatformColor(red: 0.6, green: 0.15, blue: 0.15, alpha: 1), roughness: 0.6)
        let dark = Buildings.material(PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), roughness: 0.4)
        let eyeColor = Buildings.material(PlatformColor(red: 0.95, green: 0.75, blue: 0.15, alpha: 1), roughness: 0.3)

        let tyrannosaurus = Entity()
        tyrannosaurus.name = "Tyrannosaurus"
        let gait = Entity()
        gait.name = "Gait"
        tyrannosaurus.addChild(gait)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.28), materials: [hide])
        body.scale = [0.9, 1, 1.5]
        body.position = [0, 0.9, 0.05]
        gait.addChild(body)
        let chest = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [belly])
        chest.scale = [0.9, 1, 1.1]
        chest.position = [0, 0.84, 0.26]
        gait.addChild(chest)

        // Two strong legs: a thick thigh forwards, a shin back, a big foot.
        for side: Float in [-1, 1] {
            let leg = Entity()
            leg.name = "Leg"
            leg.position = [side * 0.15, 0.72, -0.05]
            leg.addChild(segment(from: .zero, to: [0, -0.36, 0.1], width: 0.15, height: 0.17, material: hide))
            leg.addChild(segment(from: [0, -0.36, 0.1], to: [0, -0.68, -0.04], width: 0.09, height: 0.1, material: hide))
            let foot = ModelEntity(mesh: .generateBox(width: 0.13, height: 0.05, depth: 0.24, cornerRadius: 0.02), materials: [hide])
            foot.position = [0, -0.695, 0.05]
            leg.addChild(foot)
            gait.addChild(leg)

            // A tiny arm, with two claws.
            let arm = segment(from: [side * 0.15, 0.8, 0.38], to: [side * 0.16, 0.7, 0.48], width: 0.04, height: 0.04, material: hide)
            gait.addChild(arm)
            for dx: Float in [-0.012, 0.012] {
                let claw = ModelEntity(mesh: .generateCone(height: 0.04, radius: 0.008), materials: [teeth])
                claw.orientation = simd_quatf(angle: .pi * 0.85, axis: [1, 0, 0]) // pointing down and forwards
                claw.position = [side * 0.16 + dx, 0.67, 0.5]
                gait.addChild(claw)
            }
        }

        // A short, thick neck and a big head, whose lower jaw drops to roar.
        let neck = Entity()
        neck.name = "Neck"
        neck.position = [0, 1.0, 0.4]
        gait.addChild(neck)
        neck.addChild(segment(from: [0, -0.06, -0.06], to: [0, 0.12, 0.12], width: 0.18, height: 0.2, material: hide))
        let skull = ModelEntity(mesh: .generateBox(width: 0.24, height: 0.2, depth: 0.46, cornerRadius: 0.07), materials: [hide])
        skull.position = [0, 0.18, 0.34]
        neck.addChild(skull)
        let palate = ModelEntity(mesh: .generateBox(width: 0.19, height: 0.02, depth: 0.36, cornerRadius: 0.008), materials: [mouth])
        palate.position = [0, 0.075, 0.35]
        neck.addChild(palate)
        for step in 0..<6 {
            for side: Float in [-1, 1] {
                let tooth = ModelEntity(mesh: .generateCone(height: 0.04, radius: 0.01), materials: [teeth])
                tooth.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0]) // pointing down
                tooth.position = [side * 0.095, 0.065, 0.2 + Float(step) * 0.055]
                neck.addChild(tooth)
            }
        }
        for side: Float in [-1, 1] {
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [eyeColor])
            eye.position = [side * 0.115, 0.23, 0.24]
            neck.addChild(eye)
            let pupil = ModelEntity(mesh: .generateSphere(radius: 0.011), materials: [dark])
            pupil.position = [side * 0.13, 0.23, 0.25]
            neck.addChild(pupil)
            let brow = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.03, depth: 0.08, cornerRadius: 0.01), materials: [hide])
            brow.position = [side * 0.1, 0.29, 0.25]
            neck.addChild(brow)
        }

        let jaw = Entity()
        jaw.name = "Jaw"
        jaw.position = [0, 0.08, 0.14]
        neck.addChild(jaw)
        let lowerJaw = ModelEntity(mesh: .generateBox(width: 0.2, height: 0.07, depth: 0.42, cornerRadius: 0.025), materials: [belly])
        lowerJaw.position = [0, -0.04, 0.2]
        jaw.addChild(lowerJaw)
        let tongue = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.015, depth: 0.3, cornerRadius: 0.006), materials: [mouth])
        tongue.position = [0, 0, 0.18]
        jaw.addChild(tongue)
        for step in 0..<5 {
            for side: Float in [-1, 1] {
                let tooth = ModelEntity(mesh: .generateCone(height: 0.03, radius: 0.009), materials: [teeth])
                tooth.position = [side * 0.085, 0.01, 0.1 + Float(step) * 0.06]
                jaw.addChild(tooth)
            }
        }

        // The tail, straight out behind to balance the head.
        let tail = Entity()
        tail.name = "Tail"
        tail.position = [0, 0.92, -0.32]
        gait.addChild(tail)
        let spine: [SIMD3<Float>] = [.zero, [0, -0.02, -0.45], [0, -0.1, -0.85], [0, -0.16, -1.15]]
        for index in 0..<(spine.count - 1) {
            let thickness = 0.26 - Float(index) * 0.08
            tail.addChild(segment(from: spine[index], to: spine[index + 1], width: thickness, height: thickness, material: hide))
        }
        return tyrannosaurus
    }

    // MARK: Parts

    /// A rounded box from `start` to `end`, `width` across and `height`
    /// thick, for a neck, a tail or a leg.
    private static func segment(
        from start: SIMD3<Float>, to end: SIMD3<Float>, width: Float, height: Float, material: SimpleMaterial
    ) -> ModelEntity {
        let along = end - start
        let length = simd_length(along)
        let piece = ModelEntity(
            mesh: .generateBox(width: width, height: height, depth: length, cornerRadius: min(width, height, length) * 0.4),
            materials: [material]
        )
        piece.position = (start + end) / 2
        piece.orientation = simd_quatf(from: [0, 0, 1], to: along / length)
        return piece
    }

    /// Four legs ("FrontLeg" and "BackLeg"), straight down from hips at the
    /// heights given, `apart` either side of the middle, each with a broad,
    /// round foot.
    private static func addLegs(
        to gait: Entity, front: (z: Float, y: Float), back: (z: Float, y: Float), apart: Float, thickness: Float, material: SimpleMaterial
    ) {
        for (name, hip) in [("FrontLeg", front), ("BackLeg", back)] {
            for x in [-apart, apart] {
                let leg = Entity()
                leg.name = name
                leg.position = [x, hip.y, hip.z]
                let pillar = ModelEntity(
                    mesh: .generateBox(width: thickness, height: hip.y, depth: thickness * 1.1, cornerRadius: thickness * 0.35),
                    materials: [material]
                )
                pillar.position = [0, -hip.y / 2, 0]
                leg.addChild(pillar)
                let foot = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: thickness * 0.7), materials: [material])
                foot.position = [0, -hip.y + 0.02, 0.01]
                leg.addChild(foot)
                gait.addChild(leg)
            }
        }
    }

    /// Two eyes, either side of `centre`, `apart` from each other.
    private static func addEyes(to parent: Entity, at centre: SIMD3<Float>, apart: Float, size: Float, material: SimpleMaterial) {
        for side: Float in [-1, 1] {
            let eye = ModelEntity(mesh: .generateSphere(radius: size), materials: [material])
            eye.position = centre + [side * apart / 2, 0, 0]
            parent.addChild(eye)
        }
    }
}
