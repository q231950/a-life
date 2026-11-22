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

/// One of the animals the Conservationist put out, such as a foal, a bear
/// or a bird, a child of its bed, so it goes when the bed does, and
/// everything here is in the bed's space.
///
/// It stays near its bed: it grazes (or sniffs about, or pecks) a while,
/// trots or dashes off to a spot a few tiles away, frisks now and then (a
/// buck and a kick, a bear or a unicorn rearing up, a bird fluttering on
/// the spot, or a tyrannosaurus roaring), and lies down for a rest. A bird,
/// a pegasus or a pterosaur flies, too: up and round over its bed, then it
/// hovers a moment and comes down to land.
struct AnimalComponent: Component {
    enum Phase {
        /// Standing, head down, nibbling at the grass, sniffing or pecking.
        case grazing
        /// Off to somewhere near the bed, at a trot or a dash.
        case trotting
        /// Bucking, rearing up, fluttering on the spot or roaring.
        case frisking
        /// Lying down.
        case resting
        /// Up in the air, round over the bed.
        case flying
        /// Hanging in the air above where it lands.
        case hovering
        /// Coming down to land.
        case landing

        /// Whether it is off the ground.
        var isAirborne: Bool {
            switch self {
            case .flying, .hovering, .landing: true
            case .grazing, .trotting, .frisking, .resting: false
            }
        }
    }

    let animal: LotItem.Animal
    /// The bed's tiles on the lot, which it never strays far from.
    let home: LotArea

    fileprivate(set) var phase = Phase.grazing
    /// How long it has been in its current phase, in seconds.
    fileprivate var elapsed: Float = 0
    /// How long to stay in this phase, in seconds, if it doesn't end by
    /// itself. Short to start with, so the animals get going soon.
    fileprivate var duration: Float = .random(in: 0.5...4)
    /// How far it is lying down, from 0 standing to 1 lying.
    fileprivate var lying: Float = 0
    /// How far it is up and away, from 0 on the ground to 1 flying, with
    /// its legs tucked up.
    fileprivate var airborne: Float = 0
    /// Where it comes down when it has flown, on the floor.
    fileprivate var landing: SIMD3<Float> = .zero
    /// How high it hovers before it lands, in metres.
    fileprivate var hoverHeight: Float = 0
    fileprivate var stride = Stride()

    init(animal: LotItem.Animal, home: LotArea) {
        self.animal = animal
        self.home = home
    }
}

/// Where a horse or another animal is in its stride, which `BarnSystem`
/// keeps from one frame to the next to move its legs, body, neck and wings
/// smoothly.
struct Stride {
    /// Where it is in its stride, in radians.
    var phase: Float = .random(in: 0..<(2 * .pi))
    /// How much it is moving, from 0 standing to 1 at full tilt.
    var motion: Float = 0
    /// How far its head is lowered, in radians.
    var neck: Float = 0
    /// How far its wings are spread, from 0 folded to 1 flapping.
    var wings: Float = 0
    /// Where its wings are in their beat, in radians.
    var flap: Float = .random(in: 0..<(2 * .pi))
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

/// Takes every horse and every animal in a bed through its phases (see
/// `HorseComponent` and `AnimalComponent`), moves its legs, body, neck and
/// wings as it goes, and lets the chickens and goats potter about their
/// pens. Their walking across the lot, and flying over it, is left to
/// `WalkSystem`, along routes that go round whatever stands on the lot.
struct BarnSystem: System {
    private static let horses = EntityQuery(where: .has(HorseComponent.self))
    private static let animals = EntityQuery(where: .has(AnimalComponent.self))
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
    /// How far from its bed an animal goes, in tiles.
    private static let animalReach = 4
    /// How long an animal frisks for, in seconds.
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

        for animal in context.entities(matching: Self.animals, updatingSystemWhen: .rendering) {
            guard var state = animal.components[AnimalComponent.self],
                  let bed = animal.parent,
                  let lot = bed.parent?.components[LotComponent.self] else { continue }
            play(animal, &state, in: Yard(lot: lot, origin: bed.position), deltaTime: deltaTime)
            animal.components[AnimalComponent.self] = state
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

    // MARK: The animals in the beds

    /// How each kind of animal gets about.
    private struct Habits {
        /// How fast it goes on foot, in metres per second.
        var trotSpeed: Float
        var dashSpeed: Float
        /// How much quicker its strides come than a horse's.
        var cadence: Float
        /// How much its body bobs as it goes, in metres.
        var bounce: Float = 0.1
        /// How far it lowers its head to graze or sniff, in radians.
        var graze: Float
        /// How it frisks.
        var frisk = Frisk.buck
        /// Whether it lies down to rest.
        var rests = true
        /// How likely it is to fly off, when it picks what to do next.
        var flightChance = 0.0
        /// How fast it flies, in metres per second.
        var flightSpeed: Float = 0
        /// How high it flies and hovers, in metres.
        var height: ClosedRange<Float> = 0...0
        /// How fast its wings beat, in radians per second.
        var flapRate: Float = 0

        enum Frisk {
            /// A buck and a kick, twice.
            case buck
            /// Up on its hind legs, once.
            case rear
            /// Wings spread, beating, hopping on the spot.
            case flutter
            /// Head thrown up and jaw wide open, once.
            case roar
        }
    }

    private static func habits(of animal: LotItem.Animal) -> Habits {
        switch animal {
        case .foal:
            Habits(trotSpeed: 1.5, dashSpeed: 3, cadence: 1.5, graze: 1.5)
        case .unicorn:
            Habits(trotSpeed: 1.8, dashSpeed: 3.6, cadence: 1, graze: 1.25, frisk: .rear)
        case .pegasus:
            Habits(trotSpeed: 1.8, dashSpeed: 3.6, cadence: 1, graze: 1.25, flightChance: 0.25, flightSpeed: 3.2, height: 1.8...3.2, flapRate: 9)
        case .bear:
            Habits(trotSpeed: 0.9, dashSpeed: 2.2, cadence: 1.1, bounce: 0.05, graze: 0.7, frisk: .rear)
        case .polarBear:
            Habits(trotSpeed: 1, dashSpeed: 2.4, cadence: 0.9, bounce: 0.05, graze: 0.7, frisk: .rear)
        case .bird:
            Habits(trotSpeed: 0.5, dashSpeed: 0.8, cadence: 2.5, bounce: 0.04, graze: 1, frisk: .flutter, rests: false, flightChance: 0.45, flightSpeed: 2.4, height: 0.9...2.4, flapRate: 30)
        case .stegosaurus:
            // Its frisk is a buck that swings its spiked tail.
            Habits(trotSpeed: 0.8, dashSpeed: 1.8, cadence: 0.8, bounce: 0.03, graze: 0.5)
        case .diplodocus:
            // Its long neck comes right down to the grass.
            Habits(trotSpeed: 0.7, dashSpeed: 1.5, cadence: 0.6, bounce: 0.03, graze: 1.35, frisk: .rear)
        case .pterosaur:
            Habits(trotSpeed: 0.6, dashSpeed: 1.2, cadence: 1.6, bounce: 0.04, graze: 0.9, frisk: .flutter, rests: false, flightChance: 0.4, flightSpeed: 3, height: 2...3.6, flapRate: 7)
        case .triceratops:
            // Its frisk lowers its horns and kicks up its heels.
            Habits(trotSpeed: 1, dashSpeed: 2.4, cadence: 0.9, bounce: 0.04, graze: 0.6)
        case .tyrannosaurus:
            Habits(trotSpeed: 1.2, dashSpeed: 3, cadence: 0.8, bounce: 0.06, graze: 0.5, frisk: .roar)
        }
    }

    /// Takes an animal through its phases: grazing, trotting off, frisking
    /// and resting, and flying, hovering and landing for those that fly,
    /// then on to whatever it fancies next.
    private func play(_ animal: Entity, _ state: inout AnimalComponent, in yard: Yard, deltaTime: Float) {
        let habits = Self.habits(of: state.animal)
        state.elapsed += deltaTime
        switch state.phase {
        case .grazing, .resting:
            if state.elapsed >= state.duration { startPlaying(animal, &state, in: yard) }
        case .trotting:
            if Self.hasArrived(animal) { startPlaying(animal, &state, in: yard) }
        case .frisking:
            if state.elapsed >= Self.friskTime { startPlaying(animal, &state, in: yard) }
        case .flying:
            if Self.hasArrived(animal) {
                state.elapsed = 0
                state.duration = .random(in: 0.6...1.6)
                state.phase = .hovering
            }
        case .hovering:
            // Bobbing gently in the air above where it lands.
            animal.position.y = state.hoverHeight + sin(state.elapsed * 5) * 0.05
            if state.elapsed >= state.duration {
                setWalk(animal, [state.landing], speed: max(habits.flightSpeed * 0.45, 0.8))
                state.elapsed = 0
                state.phase = .landing
            }
        case .landing:
            if Self.hasArrived(animal) {
                animal.position.y = 0
                startPlaying(animal, &state, in: yard)
            }
        }

        let ease = min(1, deltaTime * 2)
        state.lying += ((state.phase == .resting ? 1 : 0) - state.lying) * ease
        // Its legs come down as it nears the ground.
        let up: Float = switch state.phase {
        case .flying, .hovering: 1
        case .landing: min(1, animal.position.y / 0.6)
        default: 0
        }
        state.airborne += (up - state.airborne) * min(1, deltaTime * 4)

        let frisking = state.phase == .frisking
        let progress = state.elapsed / Self.friskTime
        // Two bucks, one after the other, or one long rear or roar.
        let buck = frisking && (habits.frisk == .buck || habits.frisk == .flutter) ? max(0, sin(progress * 4 * .pi)) : 0
        let rear = frisking && habits.frisk == .rear ? max(0, sin(min(progress, 1) * .pi)) : 0
        let roar = frisking && habits.frisk == .roar ? max(0, sin(min(progress, 1) * .pi)) : 0
        let wings: Float = state.phase.isAirborne ? 1 : frisking && state.animal.flies ? (habits.frisk == .flutter ? 1 : 0.5) : 0

        let neck: Float
        switch state.phase {
        case .grazing:
            // A bird pecks in quick dips; the others keep their heads down.
            neck = habits.frisk == .flutter ? (sin(state.elapsed * 8) > 0.3 ? 1 : 0.1) : habits.graze + sin(state.elapsed * 3) * 0.1
        case .resting: neck = 0.1
        case .trotting, .frisking: neck = state.stride.motion * 0.25 - roar * 0.7 // head thrown up to roar
        case .flying, .hovering, .landing: neck = -0.1 // head up
        }
        animate(
            animal, &state.stride, speed: Self.speed(of: animal), topSpeed: max(habits.dashSpeed, habits.flightSpeed), cadence: habits.cadence,
            neck: neck, lying: state.lying, buck: buck, rear: rear, jaw: roar, wings: wings, flapRate: habits.flapRate, tuck: state.airborne,
            bounce: habits.bounce, deltaTime: deltaTime
        )
    }

    /// Picks what an animal does next. One that flies often flies off and
    /// round its bed; otherwise it mostly trots off somewhere near its bed,
    /// now and then at a dash, or frisks, lies down or grazes.
    private func startPlaying(_ animal: Entity, _ state: inout AnimalComponent, in yard: Yard) {
        let habits = Self.habits(of: state.animal)
        let previous = state.phase
        state.elapsed = 0
        let flightRoll = Double.random(in: 0..<1)
        // Not straight up again on landing, as a rule.
        if flightRoll < habits.flightChance * (previous == .landing ? 0.3 : 1),
           let flight = flight(for: animal, near: state.home, in: yard, height: habits.height) {
            setWalk(animal, flight.path, speed: habits.flightSpeed)
            state.landing = flight.landing
            state.hoverHeight = flight.height
            state.phase = .flying
            return
        }

        let roll = Double.random(in: 0..<1)
        if roll < 0.5, previous != .trotting || roll < 0.2, let route = route(for: animal, near: state.home, in: yard) {
            setWalk(animal, route, speed: Double.random(in: 0..<1) < 0.3 ? habits.dashSpeed : habits.trotSpeed)
            state.phase = .trotting
        } else if roll < 0.65, previous != .frisking {
            state.phase = .frisking
        } else if roll < 0.75, previous != .resting, habits.rests {
            state.duration = .random(in: 6...12)
            state.phase = .resting
        } else {
            state.duration = .random(in: 2...6)
            state.phase = .grazing
        }
    }

    /// A way to a free tile a few tiles from the bed, ending a little off
    /// the tile's middle so that animals don't stand in one another.
    private func route(for animal: Entity, near home: LotArea, in yard: Yard) -> [SIMD3<Float>]? {
        let here = yard.tile(at: animal.position)
        let reach = Self.animalReach
        for _ in 0..<8 {
            let place = Tile(
                x: .random(in: (home.x - reach)...(home.xs.upperBound - 1 + reach)),
                z: .random(in: (home.y - reach)...(home.ys.upperBound - 1 + reach))
            )
            guard place != here, yard.lot.grid.isWalkable(place),
                  var route = yard.route(from: animal.position, to: place),
                  route.count <= reach * 3, // not all the way round a building
                  let last = route.popLast() else { continue }
            let nudge = yard.lot.tileSize * 0.25
            return route + [last + [.random(in: -nudge...nudge), 0, .random(in: -nudge...nudge)]]
        }
        return nil
    }

    /// A flight up and round over the bed, through a place or two in the
    /// air, to hover above a free tile near the bed where it then lands.
    /// Flying, it goes over whatever is in the way.
    private func flight(
        for animal: Entity, near home: LotArea, in yard: Yard, height: ClosedRange<Float>
    ) -> (path: [SIMD3<Float>], landing: SIMD3<Float>, height: Float)? {
        let here = yard.tile(at: animal.position)
        let reach = Self.animalReach
        for _ in 0..<8 {
            let place = Tile(
                x: .random(in: (home.x - reach)...(home.xs.upperBound - 1 + reach)),
                z: .random(in: (home.y - reach)...(home.ys.upperBound - 1 + reach))
            )
            guard place != here, yard.lot.grid.isWalkable(place) else { continue }
            let tileSize = yard.lot.tileSize
            let nudge = tileSize * 0.25
            let landing = yard.position(of: place) + [.random(in: -nudge...nudge), 0, .random(in: -nudge...nudge)]
            let altitude = Float.random(in: height)
            // Round over the bed, whose middle is where the bed itself is.
            var path: [SIMD3<Float>] = []
            for _ in 0..<Int.random(in: 1...2) {
                let angle = Float.random(in: 0..<(2 * .pi))
                let radius = Float(reach) * tileSize * .random(in: 0.3...0.9)
                path.append([cos(angle) * radius, altitude + .random(in: -0.2...0.4), sin(angle) * radius])
            }
            path.append(landing + [0, altitude, 0])
            return (path, landing, altitude)
        }
        return nil
    }

    // MARK: Moving the legs

    /// Swings its legs, bobs its body and rocks it as it runs, faster the
    /// faster it goes, and lowers its head to `neck` radians. A smaller
    /// animal's strides come quicker (`cadence`) and bob less or more
    /// (`bounce`), and it can lie down (`lying`, from 0 standing to 1 lying,
    /// its legs folded under it), buck (`buck`, from 0 to 1 at the top of a
    /// kick) or rear up (`rear`, from 0 to 1 up on its hind legs). One with
    /// a jaw opens it (`jaw`, from 0 shut to 1 wide open), and one with a
    /// tail sways it as it goes and lashes it as it bucks. One on two legs
    /// ("Leg") strides with one and then the other. One with wings spreads
    /// them (`wings`, from 0 folded to 1 spread) and beats them `flapRate`
    /// radians a second, and tucks its legs up as it flies (`tuck`, from 0
    /// to 1).
    private func animate(
        _ animal: Entity, _ stride: inout Stride, speed: Float, topSpeed: Float, cadence: Float = 1, neck: Float,
        lying: Float = 0, buck: Float = 0, rear: Float = 0, jaw: Float = 0, wings: Float = 0, flapRate: Float = 0, tuck: Float = 0,
        bounce: Float = 0.1, deltaTime: Float
    ) {
        let ease = min(1, deltaTime * 6)
        stride.motion += (min(speed / topSpeed, 1) - stride.motion) * ease
        stride.phase = (stride.phase + deltaTime * (4 + speed * 2) * cadence).truncatingRemainder(dividingBy: 2 * .pi)
        stride.neck += (neck - stride.neck) * min(1, deltaTime * 3)
        stride.wings += (wings - stride.wings) * min(1, deltaTime * 5)
        stride.flap = (stride.flap + deltaTime * flapRate).truncatingRemainder(dividingBy: 2 * .pi)

        guard let gait = animal.children.first(where: { $0.name == "Gait" }) else { return }
        // Settles down smoothly as it comes to a stop, and doesn't bob in the air.
        let bob = stride.motion * (1 - tuck)
        let backLeg = gait.children.first { $0.name == "BackLeg" || $0.name == "Leg" }?.position ?? .zero
        // Lying, its body comes down to just above the floor; rearing, its
        // hind feet stay on it.
        let rearAngle = rear * 0.9
        gait.position.y = abs(sin(stride.phase)) * bounce * bob + buck * bounce - lying * max(backLeg.y - 0.1, 0) + max(-backLeg.z, 0) * sin(rearAngle)
        // Nose down and heels up as it bucks, nose up as it rears.
        gait.orientation = simd_quatf(angle: sin(stride.phase) * 0.08 * bob + buck * 0.35 - rearAngle, axis: [1, 0, 0])
        for part in gait.children {
            switch part.name {
            case "FrontLeg", "BackLeg":
                let isBack = part.name == "BackLeg"
                // The hind legs push off half a stride after the front ones,
                // and the right leg of each pair just after the left.
                let lead: Float = (isBack ? .pi : 0) + (part.position.x > 0 ? 0.5 : 0)
                let swing = sin(stride.phase + lead) * (0.15 + 0.55 * stride.motion) * bob
                // Folded under it lying down or flying, the hind legs kicked
                // out behind in a buck, and the forelegs pawing as it rears.
                let fold = max(lying, tuck)
                let folded: Float = isBack ? -1.5 : 1.5
                let kick: Float = isBack ? 0.9 : -0.3
                let paw: Float = isBack ? 0.9 : 0.6 + sin(stride.phase * 2) * 0.3
                part.orientation = simd_quatf(angle: swing * (1 - fold) + folded * fold + kick * buck + paw * rear, axis: [1, 0, 0])
            case "Leg":
                // Two legs, half a stride apart, folded back under it lying down.
                let lead: Float = part.position.x > 0 ? .pi : 0
                let swing = sin(stride.phase + lead) * (0.15 + 0.45 * stride.motion) * bob
                let fold = max(lying, tuck)
                part.orientation = simd_quatf(angle: swing * (1 - fold) - 1.3 * fold, axis: [1, 0, 0])
            case "Neck":
                part.orientation = simd_quatf(angle: stride.neck, axis: [1, 0, 0])
            case "Jaw":
                part.orientation = simd_quatf(angle: jaw * 0.6, axis: [1, 0, 0])
            case "Tail":
                // Swaying from side to side, more as it hurries, and lashing out as it bucks.
                let sway = sin(stride.phase) * (0.06 + 0.14 * stride.motion) * (1 - lying) + buck * 0.7
                part.orientation = simd_quatf(angle: sway, axis: [0, 1, 0])
            case "Wing":
                // Folded back along its sides, or spread and beating.
                let side: Float = part.position.x > 0 ? 1 : -1
                let sweep = 1.35 * (1 - stride.wings)
                let lift = 0.25 * (1 - stride.wings) + sin(stride.flap) * 0.75 * stride.wings
                part.orientation = simd_quatf(angle: side * sweep, axis: [0, 1, 0]) * simd_quatf(angle: side * lift, axis: [0, 0, 1])
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

/// The lot as a barn's horses, or a bed's animals, see it: in the space of
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
