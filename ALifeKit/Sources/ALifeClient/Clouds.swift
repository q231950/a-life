import Foundation

/// A few soft clouds in the lot's sky. Each is a row of puffs with a flat
/// base, somewhere between low over the walls and high over the lot, where
/// it shows on the sky part of the walls or on the flat sky over them. They
/// drift slowly round the box, the way the sun goes, and are lit by the time
/// of day: white by day, dark and faint at night.
///
/// Where a cloud is, is said in the same terms as the sky: an azimuth, as on
/// a compass, and an elevation over the horizon, as seen from the middle of
/// the lot (see `HorizonPlan.skyPoint`).
public enum Clouds {
    /// How many times the clouds go round the sky in a day on the lot: about
    /// once every 25 minutes, so they drift slowly, but you can see them go.
    public static let turnsPerDay: Double = 12

    /// Under this elevation there are no clouds, so they fade out before the
    /// world on the walls; and over the top one, none either, so they never
    /// bunch up straight overhead, where the azimuth runs together.
    public static let lowest: Double = 10 * .pi / 180
    public static let highest: Double = 70 * .pi / 180

    /// One round puff of a cloud: where its middle is, and how big it is, in
    /// radians.
    public struct Puff: Equatable, Sendable {
        public var azimuth: Double
        public var elevation: Double
        public var radius: Double
    }

    /// One cloud: its puffs, and the elevation of its flat base.
    public struct Cloud: Equatable, Sendable {
        public var puffs: [Puff]
        public var base: Double
    }

    /// The clouds as they are at midnight, before they have drifted: where
    /// each is (azimuth and elevation of its base, in degrees) and how wide
    /// (in degrees of arc).
    public static let clouds: [Cloud] = [
        (azimuth: 20.0, base: 24.0, width: 26.0),
        (azimuth: 75, base: 33, width: 18),
        (azimuth: 140, base: 20, width: 30),
        (azimuth: 205, base: 40, width: 20),
        (azimuth: 260, base: 22, width: 24),
        (azimuth: 320, base: 30, width: 16),
    ].enumerated().map { index, cloud in
        makeCloud(azimuth: cloud.azimuth, base: cloud.base, width: cloud.width, seed: Double(index))
    }

    /// A row of puffs `width` degrees across, biggest in the middle, sitting
    /// on a flat base.
    private static func makeCloud(azimuth: Double, base: Double, width: Double, seed: Double) -> Cloud {
        let degree = Double.pi / 180
        let count = 7
        let puffs = (0..<count).map { index -> Puff in
            // From -1 at the left end to 1 at the right, a little uneven.
            let across = Double(index) / Double(count - 1) * 2 - 1 + 0.12 * sin(seed * 3.1 + Double(index) * 1.7)
            let radius = width * 0.22 * (1 - 0.55 * abs(across)) * (0.85 + 0.3 * abs(sin(seed * 5.3 + Double(index) * 2.3)))
            let arc = across * width / 2
            // Across the sky, an arc of `arc` degrees spans more azimuth the
            // higher it is.
            return Puff(
                azimuth: (azimuth + arc / cos(base * degree)) * degree,
                elevation: (base + radius * 0.55) * degree,
                radius: radius * degree
            )
        }
        return Cloud(puffs: puffs, base: base * degree)
    }

    /// How thick the clouds are, from 0 (clear sky) to 1, at `azimuth` and
    /// `elevation`, before they have drifted.
    public static func cover(azimuth: Double, elevation: Double) -> Double {
        var thickest = 0.0
        for cloud in clouds {
            var field = 0.0
            for puff in cloud.puffs {
                let across = remainder(azimuth - puff.azimuth, 2 * .pi) * cos(puff.elevation)
                let up = elevation - puff.elevation
                field += exp(-(across * across + up * up) / (puff.radius * puff.radius))
            }
            // A soft edge, and a flat base.
            let degree = Double.pi / 180
            let thickness = smoothstep(0.3, 0.9, field) * smoothstep(cloud.base - 1.2 * degree, cloud.base + 0.6 * degree, elevation)
            thickest = max(thickest, thickness)
        }
        return thickest * smoothstep(lowest, lowest + 6 * .pi / 180, elevation) * (1 - smoothstep(highest - 10 * .pi / 180, highest, elevation))
    }

    /// How brightly the clouds are lit at `azimuth` and `elevation`, from 0
    /// to 1: a little grey at a cloud's base, bright on its top.
    public static func light(azimuth: Double, elevation: Double) -> Double {
        var nearest: Cloud?
        var distance = Double.infinity
        for cloud in clouds {
            for puff in cloud.puffs {
                let across = remainder(azimuth - puff.azimuth, 2 * .pi) * cos(puff.elevation)
                let apart = (across * across + pow(elevation - puff.elevation, 2)).squareRoot() / puff.radius
                if apart < distance { distance = apart; nearest = cloud }
            }
        }
        guard let nearest else { return 1 }
        let height = (nearest.puffs.map(\.radius).max() ?? 0) * 1.4
        return 0.72 + 0.28 * smoothstep(nearest.base, nearest.base + height, elevation)
    }

    /// How far round the sky the clouds have drifted in `sky`, as a share of
    /// a turn, from 0 up to, but not including, 1. A whole number of turns a
    /// day, so they carry on smoothly from one day to the next.
    public static func drift(in sky: Sky) -> Double {
        let turns = (sky.phase * turnsPerDay).truncatingRemainder(dividingBy: 1)
        return turns < 0 ? turns + 1 : turns
    }

    /// How much the clouds show, from 0 to 1: nearly fully by day, and
    /// faint at night, so the stars still show round them.
    public static func opacity(in sky: Sky) -> Double {
        0.3 + 0.62 * sky.daylight
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}
