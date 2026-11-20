import ALifeAPI
import Foundation

/// The lot in its box: four walls standing on the lot's edges, with a world
/// painted on their insides, and a flat sky over the top. Behind the office,
/// where the camera starts out looking, the south wall has a bay with a
/// city of towers across it; the north wall has mountains with snow on
/// their tops, with giant trees at their feet; and on the east and the west
/// walls the coast turns into wooded hills. Nothing is outside the box, and
/// the camera stays inside it (see `CameraReach`), so all you ever see is
/// the lot, the walls or the sky.
///
/// Positions are in metres from the middle of the lot, along the lot's x
/// (across) and z (towards the office's front), with y up from the grass.
public enum HorizonPlan {
    // MARK: Compass

    /// Which way north is, along x and z: straight across the lot, away
    /// from the office's back.
    public static let north = (x: Float(0), z: Float(1))
    /// Which way east is, along x and z.
    public static let east = (x: Float(-1), z: Float(0))

    /// The compass bearing of the point at `x`, `z`, seen from the middle of
    /// the lot, in radians: 0 to the north, π/2 to the east, π to the south.
    public static func bearing(x: Float, z: Float) -> Float {
        let angle = atan2(x * east.x + z * east.z, x * north.x + z * north.z)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    /// The point `distance` metres from the middle of the lot on `bearing`.
    public static func point(bearing: Float, distance: Float) -> (x: Float, z: Float) {
        (
            x: distance * (cos(bearing) * north.x + sin(bearing) * east.x),
            z: distance * (cos(bearing) * north.z + sin(bearing) * east.z)
        )
    }

    // MARK: The box

    /// How far each wall is from the middle of the lot: on its edge.
    public static let halfWidth = Float(LotPlan.width) / 2
    /// How tall the walls are, up to the sky.
    public static let wallHeight: Float = 36
    /// How far round the walls it is, all the way.
    public static let perimeter = 8 * halfWidth
    /// Where the sky is painted from: over the middle of the lot, at about
    /// the height of your eyes. The sky's colours, the sun, the moon and the
    /// stars are where you would see them from here.
    public static let skyCentre = SIMD3<Float>(0, 1.6, 0)

    /// The four walls, named for the way they lie from the middle of the lot.
    public enum Wall: CaseIterable, Sendable {
        case north, east, south, west

        /// Which way its painted side faces: into the box.
        public var inward: SIMD3<Float> {
            switch self {
            case .north: [-HorizonPlan.north.x, 0, -HorizonPlan.north.z]
            case .east: [-HorizonPlan.east.x, 0, -HorizonPlan.east.z]
            case .south: [HorizonPlan.north.x, 0, HorizonPlan.north.z]
            case .west: [HorizonPlan.east.x, 0, HorizonPlan.east.z]
            }
        }
    }

    /// The foot of the walls `around` metres round them, from the middle of
    /// the north wall round through the east, the south and the west, so
    /// that, seen from inside, it goes from left to right. Any distance
    /// will do: it goes round and round.
    public static func wallSpot(around: Float) -> (x: Float, z: Float, wall: Wall) {
        let h = halfWidth
        var s = around.truncatingRemainder(dividingBy: perimeter)
        if s < 0 { s += perimeter }
        switch s {
        case ..<h: return (-s, h, .north)
        case ..<(3 * h): return (-h, h - (s - h), .east)
        case ..<(5 * h): return (-h + (s - 3 * h), -h, .south)
        case ..<(7 * h): return (h, -h + (s - 5 * h), .west)
        default: return (h - (s - 7 * h), h, .north)
        }
    }

    /// The point on the walls `around` metres round them, `height` metres
    /// up and `inset` metres out from the wall, into the box.
    public static func wallPoint(around: Float, height: Float, inset: Float = 0) -> SIMD3<Float> {
        let spot = wallSpot(around: around)
        return SIMD3(spot.x, height, spot.z) + spot.wall.inward * inset
    }

    /// The compass bearing of the walls `around` metres round them.
    public static func bearing(around: Float) -> Float {
        let spot = wallSpot(around: around)
        return bearing(x: spot.x, z: spot.z)
    }

    // MARK: What the walls show

    /// How high the sea's horizon is painted on the walls.
    public static let horizonHeight: Float = 5
    /// Where the city stands on the south wall, in metres round the walls,
    /// on the horizon across the bay.
    public static let city: ClosedRange<Float> = (3 * halfWidth + 9)...(5 * halfWidth - 9)

    /// What lies on a bearing, from 0 to 1 each, adding up to 1.
    public struct Regions: Equatable, Sendable {
        /// The bay, the city and the far shore, to the south.
        public var sea: Float
        /// The mountains, to the north.
        public var mountains: Float
        /// The wooded hills, to the east and the west.
        public var hills: Float
    }

    public static func regions(bearing: Float) -> Regions {
        let sea = 1 - smoothstep(radians(48), radians(72), angle(bearing, from: .pi))
        let mountains = 1 - smoothstep(radians(48), radians(72), angle(bearing, from: 0))
        return Regions(sea: sea, mountains: mountains, hills: max(0, 1 - sea - mountains))
    }

    public static func regions(around: Float) -> Regions {
        regions(bearing: bearing(around: around))
    }

    /// How high the furthest land reaches up the walls `around` metres round
    /// them: a ridge of peaks to the north, rolling hills to the east and
    /// west, and a low far shore behind the city.
    public static func farRidge(around: Float) -> Float {
        let b = bearing(around: around)
        let regions = regions(bearing: b)
        let hills = 10 + 3 * sin(5 * b + 2.2) + 2 * sin(11 * b + 0.9) + sin(23 * b)
        let shore = horizonHeight + 1.4 + 0.8 * sin(7 * b + 0.5) + 0.4 * sin(19 * b)
        return regions.mountains * peaks(around: around) + regions.hills * hills + regions.sea * shore
    }

    /// Above this, the mountains are white with snow.
    public static func snowLine(around: Float) -> Float {
        let b = bearing(around: around)
        return 18 + 1.5 * sin(9 * b) + sin(23 * b + 1)
    }

    /// How high the nearest land reaches up the walls: foothills under the
    /// mountains, wooded hills to the east and west, and a beach along the
    /// bay.
    public static func nearLand(around: Float) -> Float {
        let b = bearing(around: around)
        let regions = regions(bearing: b)
        let foothills = 5.5 + 1.5 * sin(9 * b + 1) + sin(17 * b)
        let hills = 7 + 1.5 * sin(7 * b + 0.4) + sin(13 * b)
        return regions.mountains * foothills + regions.hills * hills + regions.sea * 0.8
    }

    /// The mountains: a ridge of sharp peaks, each falling away steeply on
    /// both sides.
    private static func peaks(around: Float) -> Float {
        var ridge: Float = 9
        for (spot, height) in peakTops {
            var apart = abs(around - spot).truncatingRemainder(dividingBy: perimeter)
            apart = min(apart, perimeter - apart)
            ridge = max(ridge, height - 1.3 * apart)
        }
        return ridge
    }

    /// Where each peak is, round the walls, and how high.
    private static let peakTops: [(Float, Float)] = (0..<26).map { index in
        let i = Float(index)
        let spot = i * perimeter / 26 + 3 * sin(2.3 * i)
        let height = 17 + 6 * sin(1.7 * i + 0.5) + 4 * sin(3.1 * i + 1.2)
        return (spot, max(10, height))
    }

    // MARK: The sky

    /// Where the sky in `direction`, seen from `skyCentre`, is painted: on
    /// one of the walls or on the flat sky over them, with the way the sky
    /// faces there, into the box. `direction` should point over the
    /// horizon.
    public static func skyPoint(direction: SIMD3<Float>) -> (point: SIMD3<Float>, inward: SIMD3<Float>) {
        let d = direction / (direction * direction).sum().squareRoot()
        var reach = Float.infinity
        var inward = SIMD3<Float>(0, -1, 0)
        if d.y > 1e-6 {
            reach = (wallHeight - skyCentre.y) / d.y
        }
        if abs(d.x) > 1e-6 {
            let across = (halfWidth - skyCentre.x * sign(d.x)) / abs(d.x)
            if across < reach { reach = across; inward = [-sign(d.x), 0, 0] }
        }
        if abs(d.z) > 1e-6 {
            let along = (halfWidth - skyCentre.z * sign(d.z)) / abs(d.z)
            if along < reach { reach = along; inward = [0, 0, -sign(d.z)] }
        }
        return (skyCentre + d * reach, inward)
    }

    /// How high over the horizon a point on the sky is, seen from
    /// `skyCentre`, in radians.
    public static func skyElevation(at point: SIMD3<Float>) -> Float {
        let offset = point - skyCentre
        return atan2(offset.y, (offset.x * offset.x + offset.z * offset.z).squareRoot())
    }

    // MARK: Helpers

    private static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    private static func sign(_ value: Float) -> Float { value < 0 ? -1 : 1 }

    /// How far apart two bearings are, from 0 to π.
    private static func angle(_ bearing: Float, from other: Float) -> Float {
        abs(remainder(bearing - other, 2 * .pi))
    }

    /// 0 up to `low`, 1 from `high`, and an S-curve in between.
    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}

/// How the orbit camera moves inside the box. It turns round a point on the
/// lot and tilts down at it, from nearly level to nearly straight down; tilt
/// it up past level and it stays where it is and looks up instead, at the
/// sky. It never leaves the box: where it would go through a wall or too
/// near the sky, it stops at the wall, or under the sky, and looks down at
/// the point from there. So it reaches the opposite edge of the lot at the
/// most, and you never see the walls from behind.
public enum CameraReach {
    /// How far the camera looks down at the point it turns round, in
    /// degrees: from nearly level to nearly straight down.
    public static let pitch: ClosedRange<Float> = 5...80
    /// How far past the lowest pitch you can tilt to look up, in degrees.
    public static let lookUp: Float = 85
    /// How far you can tilt, in degrees: below the lowest pitch, the camera
    /// looks up by as much as you tilt past it.
    public static var tilt: ClosedRange<Float> { (pitch.lowerBound - lookUp)...pitch.upperBound }
    /// How far over level the camera ever looks, in degrees.
    public static let highestLook: Float = 85
    /// How far the camera is from the point it looks at, in metres, if the
    /// box leaves it room: close enough to see the characters' faces, far
    /// enough to see across the whole lot.
    public static let distance: ClosedRange<Float> = 5...64
    /// How much the camera sees from its bottom edge to its top, in degrees.
    public static let fieldOfView: Float = 45
    /// How near the walls the camera comes, in metres.
    public static let wallGap: Float = 0.5
    /// How high the camera goes, in metres: well under the sky.
    public static let ceiling: Float = HorizonPlan.wallHeight - 8
    /// How low the camera goes, in metres: over the grass.
    public static let floor: Float = 0.4

    /// Where the camera is and which way it looks.
    public struct View: Equatable, Sendable {
        /// Where it is, in the lot's space.
        public var eye: SIMD3<Float>
        /// Which way it faces round, in radians: as `yaw`.
        public var heading: Float
        /// How far over level it looks, in radians: below 0, it looks down.
        public var elevation: Float

        /// The way it looks.
        public var forward: SIMD3<Float> {
            [-sin(heading) * cos(elevation), sin(elevation), -cos(heading) * cos(elevation)]
        }
    }

    /// The camera turned `yaw` radians round `pivot`, tilted `tilt` radians
    /// down (or up, past the lowest pitch), `distance` metres away if the
    /// box leaves it room. At a yaw of 0 it is on the pivot's +z side.
    public static func view(lookingAt pivot: SIMD3<Float>, yaw: Float, tilt: Float, distance: Float) -> View {
        let degree = Float.pi / 180
        let lowest = pitch.lowerBound * degree
        let tilt = min(max(tilt, self.tilt.lowerBound * degree), self.tilt.upperBound * degree)
        let pitch = max(tilt, lowest)
        let gaze = lowest - min(tilt, lowest)

        let limit = HorizonPlan.halfWidth - wallGap
        let pivot = SIMD3<Float>(min(max(pivot.x, -limit), limit), pivot.y, min(max(pivot.z, -limit), limit))
        let boom = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        var eye = pivot + boom * max(0, distance)
        eye.x = min(max(eye.x, -limit), limit)
        eye.z = min(max(eye.z, -limit), limit)
        eye.y = min(max(eye.y, floor), ceiling)

        // At the pivot from wherever it ended up, then up by the gaze. A
        // wall only ever pulls the camera back towards the pivot, never past
        // it, so a little of the yaw's own way, more the higher it is,
        // keeps it from spinning round when it is right over the pivot.
        let offset = eye - pivot
        let across = (offset.x * offset.x + offset.z * offset.z).squareRoot()
        let pull = 0.1 * offset.y
        let heading = atan2(offset.x + sin(yaw) * pull, offset.z + cos(yaw) * pull)
        let down = atan2(offset.y, across)
        return View(eye: eye, heading: heading, elevation: min(gaze - down, highestLook * degree))
    }
}
