import ALifeClient
import Foundation
import RealityKit

/// One of the horses that come with a barn. It is a child of its barn, so
/// it goes when the barn does, and everything here is in the barn's space.
///
/// It feeds at the barn's trough for a while, then gallops off to a few
/// places around the lot, one after the other, and comes back to the trough
/// to feed again. Now and then, after feeding, it goes into the lunging ring
/// instead and canters round it a few times, one horse at a time.
struct HorseComponent: Component {
    enum Phase {
        /// At the trough, head down.
        case feeding
        /// Off round the lot, to a few places one after the other.
        case galloping
        /// Coming back to the trough.
        case returning
        /// On its way to the ring's gate.
        case goingToRing
        /// Through the gate into the ring.
        case enteringRing
        /// Round and round the ring.
        case lunging
        /// Back out through the gate.
        case leavingRing

        /// Whether it is in the ring, or on its way in or out.
        var isAtRing: Bool {
            switch self {
            case .goingToRing, .enteringRing, .lunging, .leavingRing: true
            case .feeding, .galloping, .returning: false
            }
        }
    }

    /// The barn's lunging ring.
    struct Ring {
        /// Its middle, on the floor.
        var centre: SIMD3<Float>
        /// To its fence, in metres.
        var radius: Float
        /// The tile on the lot just outside its gate.
        var gate: Tile
    }

    /// The tile on the lot where it stands to feed, in front of the trough.
    let feedTile: Tile
    /// The barn's lunging ring, if the barn has room for one.
    let ring: Ring?

    fileprivate(set) var phase = Phase.feeding
    /// How long it has been in its current phase, in seconds.
    fileprivate var elapsed: Float = 0
    /// How long to feed for, in seconds. Short to start with, so that the
    /// horses set off one by one soon after the barn is built.
    fileprivate var feedingTime: Float = .random(in: 1...5)
    /// How much longer to stand before galloping on, in seconds.
    fileprivate var pause: Float = 0
    /// How many more places to gallop to before coming back.
    fileprivate var gallopsLeft = 0
    /// How far round the ring it has gone, and how far it is going, in radians.
    fileprivate var lunged: Float = 0
    fileprivate var lungeLength: Float = 0
    fileprivate var stride = Stride()

    init(feedTile: Tile, ring: Ring?) {
        self.feedTile = feedTile
        self.ring = ring
    }
}

/// One of the foals the Gardener put out, a child of its bed, so it goes
/// when the bed does, and everything here is in the bed's space.
///
/// It stays near its bed: it grazes a while, trots or dashes off to a spot
/// a few tiles away, frisks now and then with a buck and a kick, and lies
/// down for a rest.
struct FoalComponent: Component {
    enum Phase {
        /// Standing, head down, nibbling at the grass.
        case grazing
        /// Off to somewhere near the bed, at a trot or a dash.
        case trotting
        /// Bucking and kicking up its heels on the spot.
        case frisking
        /// Lying down.
        case resting
    }

    /// The bed's tiles on the lot, which it never strays far from.
    let home: LotArea

    fileprivate(set) var phase = Phase.grazing
    /// How long it has been in its current phase, in seconds.
    fileprivate var elapsed: Float = 0
    /// How long to stay in this phase, in seconds, if it doesn't end by
    /// itself. Short to start with, so the foals get going soon.
    fileprivate var duration: Float = .random(in: 0.5...4)
    /// How far it is lying down, from 0 standing to 1 lying.
    fileprivate var lying: Float = 0
    fileprivate var stride = Stride()

    init(home: LotArea) {
        self.home = home
    }
}

/// Where a horse or a foal is in its stride, which `BarnSystem` keeps from
/// one frame to the next to move its legs, body and neck smoothly.
struct Stride {
    /// Where it is in its stride, in radians.
    var phase: Float = .random(in: 0..<(2 * .pi))
    /// How much it is moving, from 0 standing to 1 at full tilt.
    var motion: Float = 0
    /// How far its head is lowered, in radians.
    var neck: Float = 0
}

/// A chicken or a goat in a barn's pen, which potters about inside it.
struct PenAnimalComponent: Component {
    enum Kind {
        /// Pecks at the ground when it stops.
        case chicken
        /// Grazes when it stops.
        case goat
    }

    let kind: Kind
    /// Two opposite corners of where it may go, in its barn's space, as x and z.
    let low: SIMD2<Float>
    let high: SIMD2<Float>

    /// Where it is off to, as x and z, or `nil` while it stands.
    fileprivate var target: SIMD2<Float>?
    /// How much longer to stand, in seconds.
    fileprivate var pause: Float = .random(in: 0...3)
    /// A clock for its pecking and its little hops.
    fileprivate var clock: Float = .random(in: 0...10)
    /// How far its head is lowered, in radians.
    fileprivate var head: Float = 0

    init(kind: Kind, low: SIMD2<Float>, high: SIMD2<Float>) {
        self.kind = kind
        self.low = low
        self.high = high
    }
}

/// Takes every horse and foal through its phases (see `HorseComponent` and
/// `FoalComponent`), moves its legs, body and neck as it goes, and lets the
/// chickens and goats potter about their pens. The horses' and foals'
/// walking across the lot is left to `WalkSystem`, along routes that go
/// round whatever stands on the lot.
struct BarnSystem: System {
    private static let horses = EntityQuery(where: .has(HorseComponent.self))
    private static let foals = EntityQuery(where: .has(FoalComponent.self))
    private static let penAnimals = EntityQuery(where: .has(PenAnimalComponent.self))

    /// How fast a horse goes, in metres per second.
    private static let gallopSpeed: Float = 4.6
    private static let canterSpeed: Float = 3
    private static let lungeSpeed: Float = 2.6
    private static let walkSpeed: Float = 1.4
    /// How far from where it is a horse gallops to, in tiles.
    private static let gallopReach = 6...18
    /// How likely a horse is to go into the ring after feeding, if the ring is free.
    private static let lungeChance = 0.35
    /// How fast a foal goes, in metres per second.
    private static let foalTrotSpeed: Float = 1.5
    private static let foalDashSpeed: Float = 3
    /// How far from its bed a foal goes, in tiles.
    private static let foalReach = 4
    /// How long a foal frisks for, in seconds.
    private static let friskTime: Float = 1.2

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)

        for horse in context.entities(matching: Self.horses, updatingSystemWhen: .rendering) {
            guard var state = horse.components[HorseComponent.self],
                  let barn = horse.parent,
                  let lot = barn.parent?.components[LotComponent.self] else { continue }
            let yard = Yard(lot: lot, origin: barn.position)

            state.elapsed += deltaTime
            let phase = state.phase
            switch phase {
            case .feeding:
                feed(horse, &state, in: yard)
            case .galloping:
                gallop(horse, &state, in: yard, deltaTime: deltaTime)
            case .returning:
                if Self.hasArrived(horse) { startFeeding(horse, &state, in: yard) }
            case .goingToRing:
                if Self.hasArrived(horse), let ring = state.ring {
                    // Straight in through the gate, which is in the barn's
                    // own tiles, so off the lot's routes.
                    let front = ring.centre + [0, 0, ring.radius]
                    setWalk(horse, [front, Self.lungeStart(of: ring)], speed: Self.walkSpeed)
                    state.phase = .enteringRing
                }
            case .enteringRing:
                if Self.hasArrived(horse) {
                    state.lunged = 0
                    state.lungeLength = Float(Int.random(in: 2...3)) * 2 * .pi
                    state.phase = .lunging
                }
            case .lunging:
                lunge(horse, &state, in: yard, deltaTime: deltaTime)
            case .leavingRing:
                if Self.hasArrived(horse) { startGalloping(&state) }
            }
            if state.phase != phase {
                state.elapsed = 0
            }
            let speed = state.phase == .lunging ? Self.lungeSpeed : Self.speed(of: horse)
            let neck: Float = state.phase == .feeding ? 1.25 + sin(state.elapsed * 2.5) * 0.08 : state.stride.motion * 0.35
            animate(horse, &state.stride, speed: speed, topSpeed: Self.gallopSpeed, neck: neck, deltaTime: deltaTime)
            horse.components[HorseComponent.self] = state
        }

        for foal in context.entities(matching: Self.foals, updatingSystemWhen: .rendering) {
            guard var state = foal.components[FoalComponent.self],
                  let bed = foal.parent,
                  let lot = bed.parent?.components[LotComponent.self] else { continue }
            play(foal, &state, in: Yard(lot: lot, origin: bed.position), deltaTime: deltaTime)
            foal.components[FoalComponent.self] = state
        }

        for animal in context.entities(matching: Self.penAnimals, updatingSystemWhen: .rendering) {
            guard var state = animal.components[PenAnimalComponent.self] else { continue }
            potter(animal, &state, deltaTime: deltaTime)
            animal.components[PenAnimalComponent.self] = state
        }
    }

    // MARK: Horses

    /// Feeds until it has had enough, then either gallops off or, now and
    /// then, goes into the ring if no other horse is in it.
    private func feed(_ horse: Entity, _ state: inout HorseComponent, in yard: Yard) {
        guard state.elapsed >= state.feedingTime else { return }
        if let ring = state.ring, Double.random(in: 0..<1) < Self.lungeChance, !isRingTaken(by: horse),
           let route = yard.route(from: horse.position, to: ring.gate) {
            setWalk(horse, route, speed: Self.walkSpeed)
            state.phase = .goingToRing
        } else {
            startGalloping(&state)
        }
    }

    private func startGalloping(_ state: inout HorseComponent) {
        state.gallopsLeft = .random(in: 2...4)
        state.pause = 0
        state.phase = .galloping
    }

    /// Gallops to somewhere a good way off, stands a moment, and goes on to
    /// the next, until it has been to enough places and heads home.
    private func gallop(_ horse: Entity, _ state: inout HorseComponent, in yard: Yard, deltaTime: Float) {
        guard Self.hasArrived(horse) else { return }
        state.pause -= deltaTime
        guard state.pause <= 0 else { return }

        if state.gallopsLeft <= 0 {
            if let route = yard.route(from: horse.position, to: state.feedTile) {
                setWalk(horse, route, speed: Self.canterSpeed)
                state.phase = .returning
            } else {
                // There's no way back to the trough: it grazes where it is.
                startFeeding(horse, &state, in: yard)
            }
            return
        }

        let here = yard.tile(at: horse.position)
        for _ in 0..<8 {
            let reach = Self.gallopReach
            let place = Tile(x: here.x + .random(in: -reach.upperBound...reach.upperBound), z: here.z + .random(in: -reach.upperBound...reach.upperBound))
            guard max(abs(place.x - here.x), abs(place.z - here.z)) >= reach.lowerBound,
                  yard.lot.grid.isWalkable(place),
                  let route = yard.route(from: horse.position, to: place) else { continue }
            setWalk(horse, route, speed: Self.gallopSpeed)
            state.gallopsLeft -= 1
            state.pause = .random(in: 0.3...1.2)
            return
        }
        state.pause = 0.5 // nowhere this time; it tries again in a moment
    }

    /// Stands at the trough, facing it, for a while.
    private func startFeeding(_ horse: Entity, _ state: inout HorseComponent, in yard: Yard) {
        if yard.tile(at: horse.position) == state.feedTile {
            horse.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) // the trough is towards -z
        }
        state.feedingTime = .random(in: 4...8)
        state.phase = .feeding
    }

    /// Canters round the ring, then leaves it the way it came in.
    private func lunge(_ horse: Entity, _ state: inout HorseComponent, in yard: Yard, deltaTime: Float) {
        guard let ring = state.ring else {
            startGalloping(&state)
            return
        }
        let radius = Self.lungeRadius(of: ring)
        state.lunged = min(state.lunged + Self.lungeSpeed / radius * deltaTime, state.lungeLength)
        let angle = state.lunged
        horse.position = ring.centre + [sin(angle), 0, cos(angle)] * radius
        horse.orientation = simd_quatf(angle: atan2(cos(angle), -sin(angle)), axis: [0, 1, 0]) // along the circle
        guard state.lunged >= state.lungeLength else { return }

        let front = ring.centre + [0, 0, ring.radius]
        setWalk(horse, [front, yard.position(of: ring.gate)], speed: Self.walkSpeed)
        state.phase = .leavingRing
    }

    /// Whether another horse of the same barn is using the ring.
    private func isRingTaken(by horse: Entity) -> Bool {
        horse.parent?.children.contains { other in
            other !== horse && other.components[HorseComponent.self]?.phase.isAtRing == true
        } ?? false
    }

    // MARK: Foals

    /// Takes a foal through its phases: grazing, trotting off, frisking and
    /// resting, then on to whatever it fancies next.
    private func play(_ foal: Entity, _ state: inout FoalComponent, in yard: Yard, deltaTime: Float) {
        state.elapsed += deltaTime
        switch state.phase {
        case .grazing, .resting:
            if state.elapsed >= state.duration { startPlaying(foal, &state, in: yard) }
        case .trotting:
            if Self.hasArrived(foal) { startPlaying(foal, &state, in: yard) }
        case .frisking:
            if state.elapsed >= Self.friskTime { startPlaying(foal, &state, in: yard) }
        }

        state.lying += ((state.phase == .resting ? 1 : 0) - state.lying) * min(1, deltaTime * 2)
        // Two bucks, one after the other.
        let buck = state.phase == .frisking ? max(0, sin(state.elapsed / Self.friskTime * 4 * .pi)) : 0
        let neck: Float
        switch state.phase {
        case .grazing: neck = 1.5 + sin(state.elapsed * 3) * 0.1
        case .resting: neck = 0.1
        case .trotting, .frisking: neck = state.stride.motion * 0.25
        }
        animate(foal, &state.stride, speed: Self.speed(of: foal), topSpeed: Self.foalDashSpeed, cadence: 1.5, neck: neck, lying: state.lying, buck: buck, deltaTime: deltaTime)
    }

    /// Picks what a foal does next. Mostly it trots off somewhere near its
    /// bed, now and then at a dash; otherwise it frisks, lies down or grazes.
    private func startPlaying(_ foal: Entity, _ state: inout FoalComponent, in yard: Yard) {
        let previous = state.phase
        state.elapsed = 0
        let roll = Double.random(in: 0..<1)
        if roll < 0.5, previous != .trotting || roll < 0.2, let route = route(for: foal, near: state.home, in: yard) {
            setWalk(foal, route, speed: Double.random(in: 0..<1) < 0.3 ? Self.foalDashSpeed : Self.foalTrotSpeed)
            state.phase = .trotting
        } else if roll < 0.65, previous != .frisking {
            state.phase = .frisking
        } else if roll < 0.75, previous != .resting {
            state.duration = .random(in: 6...12)
            state.phase = .resting
        } else {
            state.duration = .random(in: 2...6)
            state.phase = .grazing
        }
    }

    /// A way to a free tile a few tiles from the bed, ending a little off
    /// the tile's middle so that foals don't stand in one another.
    private func route(for foal: Entity, near home: LotArea, in yard: Yard) -> [SIMD3<Float>]? {
        let here = yard.tile(at: foal.position)
        let reach = Self.foalReach
        for _ in 0..<8 {
            let place = Tile(
                x: .random(in: (home.x - reach)...(home.xs.upperBound - 1 + reach)),
                z: .random(in: (home.y - reach)...(home.ys.upperBound - 1 + reach))
            )
            guard place != here, yard.lot.grid.isWalkable(place),
                  var route = yard.route(from: foal.position, to: place),
                  route.count <= reach * 3, // not all the way round a building
                  let last = route.popLast() else { continue }
            let nudge = yard.lot.tileSize * 0.25
            return route + [last + [.random(in: -nudge...nudge), 0, .random(in: -nudge...nudge)]]
        }
        return nil
    }

    // MARK: Moving the legs

    /// Swings its legs, bobs its body and rocks it as it runs, faster the
    /// faster it goes, and lowers its head to `neck` radians. A foal's
    /// strides come quicker (`cadence`), it can lie down (`lying`, from 0
    /// standing to 1 lying, its legs folded under it) and buck (`buck`, from
    /// 0 to 1 at the top of a kick).
    private func animate(
        _ animal: Entity, _ stride: inout Stride, speed: Float, topSpeed: Float, cadence: Float = 1, neck: Float,
        lying: Float = 0, buck: Float = 0, deltaTime: Float
    ) {
        let ease = min(1, deltaTime * 6)
        stride.motion += (min(speed / topSpeed, 1) - stride.motion) * ease
        stride.phase = (stride.phase + deltaTime * (4 + speed * 2) * cadence).truncatingRemainder(dividingBy: 2 * .pi)
        stride.neck += (neck - stride.neck) * min(1, deltaTime * 3)

        guard let gait = animal.children.first(where: { $0.name == "Gait" }) else { return }
        // Settles down smoothly as it comes to a stop.
        let bob = stride.motion
        // Lying, its body comes down to just above the floor.
        let hips = gait.children.first { $0.name == "BackLeg" }?.position.y ?? 0
        gait.position.y = abs(sin(stride.phase)) * 0.1 * bob + buck * 0.1 - lying * max(hips - 0.1, 0)
        // Nose down and heels up as it bucks.
        gait.orientation = simd_quatf(angle: sin(stride.phase) * 0.08 * bob + buck * 0.35, axis: [1, 0, 0])
        for part in gait.children {
            switch part.name {
            case "FrontLeg", "BackLeg":
                let isBack = part.name == "BackLeg"
                // The hind legs push off half a stride after the front ones,
                // and the right leg of each pair just after the left.
                let lead: Float = (isBack ? .pi : 0) + (part.position.x > 0 ? 0.5 : 0)
                let swing = sin(stride.phase + lead) * (0.15 + 0.55 * stride.motion) * bob
                // Folded under it lying down, and the hind legs kicked out behind in a buck.
                let folded: Float = isBack ? -1.5 : 1.5
                let kick: Float = isBack ? 0.9 : -0.3
                part.orientation = simd_quatf(angle: swing * (1 - lying) + folded * lying + kick * buck, axis: [1, 0, 0])
            case "Neck":
                part.orientation = simd_quatf(angle: stride.neck, axis: [1, 0, 0])
            default:
                break
            }
        }
    }

    /// How fast it is walking, in metres per second, or 0 if it is standing.
    private static func speed(of animal: Entity) -> Float {
        guard let walk = animal.components[WalkComponent.self], !walk.waypoints.isEmpty else { return 0 }
        return walk.speed
    }

    private func setWalk(_ horse: Entity, _ waypoints: [SIMD3<Float>], speed: Float) {
        horse.components.set(WalkComponent(waypoints: waypoints, speed: speed))
    }

    private static func hasArrived(_ horse: Entity) -> Bool {
        horse.components[WalkComponent.self]?.waypoints.isEmpty ?? true
    }

    /// The circle a horse canters round, inside the fence.
    private static func lungeRadius(of ring: HorseComponent.Ring) -> Float {
        max(ring.radius - 0.55, 0.6)
    }

    /// Where it starts and finishes going round, just inside the gate.
    private static func lungeStart(of ring: HorseComponent.Ring) -> SIMD3<Float> {
        ring.centre + [0, 0, lungeRadius(of: ring)]
    }

    // MARK: The pen

    /// Walks to somewhere else in the pen, stands a while, pecking or
    /// grazing, and goes on.
    private func potter(_ animal: Entity, _ state: inout PenAnimalComponent, deltaTime: Float) {
        state.clock += deltaTime
        let isChicken = state.kind == .chicken
        let lowered: Float

        if let target = state.target {
            let here = SIMD2(animal.position.x, animal.position.z)
            let toTarget = target - here
            let distance = simd_length(toTarget)
            let step = (isChicken ? 0.45 : 0.35) * deltaTime
            if distance <= step {
                animal.position = [target.x, 0, target.y]
                state.target = nil
                state.pause = .random(in: 1...4)
            } else {
                let moved = here + toTarget / distance * step
                // A chicken hops a little as it goes.
                let hop = isChicken ? abs(sin(state.clock * 14)) * 0.015 : 0
                animal.position = [moved.x, hop, moved.y]
                animal.orientation = simd_quatf(angle: atan2(toTarget.x, toTarget.y), axis: [0, 1, 0])
            }
            lowered = 0
        } else {
            state.pause -= deltaTime
            if state.pause <= 0 {
                let low = state.low, high = state.high
                state.target = SIMD2(.random(in: low.x...max(low.x, high.x)), .random(in: low.y...max(low.y, high.y)))
            }
            // A chicken pecks in quick dips; a goat keeps its head down.
            lowered = isChicken ? (sin(state.clock * 6) > 0.2 ? 1.1 : 0.1) : 0.85
        }

        state.head += (lowered - state.head) * min(1, deltaTime * (isChicken ? 18 : 3))
        animal.children.first { $0.name == "Head" }?.orientation = simd_quatf(angle: state.head, axis: [1, 0, 0])
    }
}

/// The lot as a barn's horses, or a bed's foals, see it: in the space of
/// their barn or bed, which is the lot's space moved to its middle.
private struct Yard {
    let lot: LotComponent
    /// Where the barn or the bed stands on the lot.
    let origin: SIMD3<Float>

    func position(of tile: Tile) -> SIMD3<Float> {
        lot.position(of: tile) - origin
    }

    func tile(at position: SIMD3<Float>) -> Tile {
        lot.tile(at: position + origin)
    }

    func route(from start: SIMD3<Float>, to goal: Tile) -> [SIMD3<Float>]? {
        lot.route(from: start + origin, to: goal)?.map { $0 - origin }
    }
}
