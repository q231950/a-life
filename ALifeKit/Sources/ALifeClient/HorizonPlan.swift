import Foundation

/// The land, the sea and the city round the lot, as far as the eye can see:
/// a meadow all round it, a bay with a beach to the south and a city of
/// towers on an island across it, mountains with snow on their tops to the
/// north with forests of giant trees at their feet, and a coast that turns
/// into wooded hills to the east and the west. They close the lot in on
/// every side, so wherever the camera goes (see `CameraReach`) you see the
/// lot, the land and sea round it, or the sky, and never the edge of the
/// world.
///
/// Positions are in metres from the middle of the lot, along the lot's x
/// (across) and z (towards the office's front), at the height of the grass.
/// The camera starts out looking south, at the back of the office.
public enum HorizonPlan {
    // MARK: Compass

    /// Which way north is, along x and z.
    public static let north = (x: Float(0.5).squareRoot(), z: Float(0.5).squareRoot())
    /// Which way east is, along x and z.
    public static let east = (x: -Float(0.5).squareRoot(), z: Float(0.5).squareRoot())

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

    // MARK: Sizes

    /// The height of the meadow round the lot, just under the grass.
    public static let groundLevel: Float = -0.05
    /// The height of the sea.
    public static let waterLevel: Float = -0.5
    /// Nothing rises within this distance of the middle of the lot, where
    /// the camera goes.
    public static let flatRadius: Float = 150
    /// How far out the land and the sea reach.
    public static let radius: Float = 950
    /// How far the sky is from the camera. Everything you can see below the
    /// horizon is nearer than this.
    public static let skyRadius: Float = 900

    /// The city's island, out in the bay: how far from the middle of the lot
    /// it starts and ends, and how far either side of south it reaches, in
    /// radians.
    public static let island = (near: Float(265), far: Float(365), halfWidth: Float(34 * Double.pi / 180))

    // MARK: The lie of the land

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
        let sea = 1 - smoothstep(radians(50), radians(80), angle(bearing, from: .pi))
        let mountains = 1 - smoothstep(radians(40), radians(75), angle(bearing, from: 0))
        return Regions(sea: sea, mountains: mountains, hills: max(0, 1 - sea - mountains))
    }

    /// How much of the city's island is at `x`, `z`, from 0 out at sea to
    /// 1 on its flat top, where the towers stand.
    public static func islandAmount(x: Float, z: Float) -> Float {
        let distance = (x * x + z * z).squareRoot()
        let across = 1 - smoothstep(island.halfWidth, island.halfWidth + radians(12), angle(bearing(x: x, z: z), from: .pi))
        let along = smoothstep(island.near - 15, island.near, distance) * (1 - smoothstep(island.far, island.far + 15, distance))
        return across * along * regions(bearing: bearing(x: x, z: z)).sea
    }

    /// The height of the land, or of the sea floor, at `x`, `z`.
    public static func height(x: Float, z: Float) -> Float {
        let distance = (x * x + z * z).squareRoot()
        let bearing = bearing(x: x, z: z)
        let regions = regions(bearing: bearing)
        var height = regions.hills * hills(distance, bearing) + regions.mountains * mountains(distance, bearing)
        if regions.sea > 0 {
            height += regions.sea * sea(distance, bearing, x: x, z: z)
        }
        return height
    }

    /// Meadow up to `flatRadius`, then hills rising to a wooded ridge, and
    /// higher ones behind.
    private static func hills(_ distance: Float, _ bearing: Float) -> Float {
        let near = (60 + 15 * (0.6 * sin(3 * bearing + 1.3) + 0.4 * sin(7 * bearing + 0.4))) * smoothstep(flatRadius, 330, distance)
        let far = (35 + 20 * (0.5 * sin(5 * bearing + 2.2) + 0.5 * sin(2 * bearing + 0.9))) * smoothstep(380, 620, distance)
        let ripple = 5 * sin(distance * 0.045 + 4 * bearing) * smoothstep(flatRadius, 260, distance)
        return groundLevel + near + far + ripple
    }

    /// Meadow up to `flatRadius`, then foothills where the giant trees
    /// grow, then a ring of peaks.
    private static func mountains(_ distance: Float, _ bearing: Float) -> Float {
        let peaks = 190 + 70 * sin(5 * bearing + 0.7) + 50 * sin(11 * bearing + 2.1)
        let peakDistance = 380 + 40 * sin(4 * bearing + 1)
        let foothills = (22 + 8 * sin(9 * bearing)) * smoothstep(flatRadius, 240, distance)
        let rise = smoothstep(240, peakDistance, distance)
        let fall = 1 - 0.35 * smoothstep(peakDistance, 750, distance)
        return groundLevel + foothills + peaks * rise * fall
    }

    /// Meadow, a beach down into the bay, the city's island, open water,
    /// and the far shore rising behind it all.
    private static func sea(_ distance: Float, _ bearing: Float, x: Float, z: Float) -> Float {
        let floor = waterLevel - 6
        let sand = waterLevel - 0.3
        let shore: Float = 72 + 6 * sin(3 * bearing)
        var height = groundLevel
            + (sand - groundLevel) * smoothstep(shore, shore + 20, distance)
            + (floor - sand) * smoothstep(shore + 20, shore + 40, distance)
        height = mix(height, waterLevel + 1.5, islandAmount(x: x, z: z))
        let farShore = 57 + 10 * sin(4 * bearing + 0.5) + 15 * smoothstep(560, 800, distance)
        return mix(height, farShore, smoothstep(430, 560, distance))
    }

    // MARK: Helpers

    private static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    /// How far apart two bearings are, from 0 to π.
    private static func angle(_ bearing: Float, from other: Float) -> Float {
        abs(remainder(bearing - other, 2 * .pi))
    }

    private static func mix(_ a: Float, _ b: Float, _ amount: Float) -> Float {
        a + (b - a) * amount
    }

    /// 0 up to `low`, 1 from `high`, and an S-curve in between.
    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}

/// How far the orbit camera can tilt and zoom, and how wide it sees. The
/// horizon is built so that from anywhere within these you never see the
/// edge of the world.
public enum CameraReach {
    /// How far the camera looks down, in degrees: from nearly level, to
    /// look out at the horizon, to nearly straight down.
    public static let pitch: ClosedRange<Float> = 5...80
    /// How far the camera is from the point it looks at, in metres: close
    /// enough to see the characters' faces, far enough to see the whole lot.
    public static let distance: ClosedRange<Float> = 5...100
    /// How much the camera sees from its bottom edge to its top, in degrees.
    public static let fieldOfView: Float = 45
}
