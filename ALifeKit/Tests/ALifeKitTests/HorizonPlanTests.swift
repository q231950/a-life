import XCTest
import ALifeAPI
@testable import ALifeClient

/// The land, sea and city round the lot: flat where the camera goes, and
/// high enough further out that no camera the rig allows sees past them.
final class HorizonPlanTests: XCTestCase {
    private let degree = Float.pi / 180

    func testTheCompassPointsTheWayTheCameraStartsOutLookingSouth() {
        // The camera starts out at +x, +z, looking back towards -x, -z.
        XCTAssertEqual(HorizonPlan.bearing(x: -1, z: -1), .pi, accuracy: 1e-5)
        XCTAssertEqual(HorizonPlan.bearing(x: 1, z: 1), 0, accuracy: 1e-5)
        XCTAssertEqual(HorizonPlan.bearing(x: -1, z: 1), .pi / 2, accuracy: 1e-5)
        let point = HorizonPlan.point(bearing: 1.2, distance: 300)
        XCTAssertEqual(HorizonPlan.bearing(x: point.x, z: point.z), 1.2, accuracy: 1e-5)
        XCTAssertEqual((point.x * point.x + point.z * point.z).squareRoot(), 300, accuracy: 1e-3)
    }

    func testTheRegionsGoRoundTheLot() {
        XCTAssertEqual(HorizonPlan.regions(bearing: .pi).sea, 1)
        XCTAssertEqual(HorizonPlan.regions(bearing: 0).mountains, 1)
        XCTAssertEqual(HorizonPlan.regions(bearing: .pi / 2).hills, 1)
        XCTAssertEqual(HorizonPlan.regions(bearing: 3 * .pi / 2).hills, 1)
        for bearing in stride(from: Float(0), to: 2 * .pi, by: 0.05) {
            let regions = HorizonPlan.regions(bearing: bearing)
            XCTAssertEqual(regions.sea + regions.mountains + regions.hills, 1, accuracy: 1e-5)
        }
    }

    func testTheLotAndTheMeadowRoundItAreFlat() {
        for x in stride(from: Float(-40), through: 40, by: 2) {
            for z in stride(from: Float(-40), through: 40, by: 2) {
                XCTAssertEqual(HorizonPlan.height(x: x, z: z), HorizonPlan.groundLevel, accuracy: 1e-4)
            }
        }
        // Nothing rises where the camera goes, though the beach goes down
        // into the bay.
        for bearing in stride(from: Float(0), to: 2 * .pi, by: 0.03) {
            for distance in stride(from: Float(0), through: HorizonPlan.flatRadius, by: 5) {
                let point = HorizonPlan.point(bearing: bearing, distance: distance)
                XCTAssertLessThanOrEqual(HorizonPlan.height(x: point.x, z: point.z), HorizonPlan.groundLevel + 1e-4)
            }
        }
    }

    func testTheCitysIslandStandsOutOfTheBay() {
        let middle = HorizonPlan.point(bearing: .pi, distance: (HorizonPlan.island.near + HorizonPlan.island.far) / 2)
        XCTAssertEqual(HorizonPlan.islandAmount(x: middle.x, z: middle.z), 1, accuracy: 1e-4)
        XCTAssertGreaterThan(HorizonPlan.height(x: middle.x, z: middle.z), HorizonPlan.waterLevel + 1)
        let bay = HorizonPlan.point(bearing: .pi, distance: 140)
        XCTAssertLessThan(HorizonPlan.height(x: bay.x, z: bay.z), HorizonPlan.waterLevel - 3)
        XCTAssertEqual(HorizonPlan.islandAmount(x: bay.x, z: bay.z), 0)
    }

    /// Every camera the rig allows, at a spread of turns, tilts and zooms,
    /// looking at the middle and the corners of the lot. Any ray it sees
    /// that points below the horizon has to land on the lot, the land or the
    /// sea, well inside the sky, so you never see past the edge of the
    /// world. Rays above the horizon may go on to the sky.
    func testNoCameraSeesPastTheEdgeOfTheWorld() {
        let half = Float(LotPlan.width) / 2
        let pivots: [SIMD2<Float>] = [[0, 0], [half, half], [-half, half], [half, -half], [-half, -half]]
        let pitches: [Float] = [CameraReach.pitch.lowerBound, 12, 19, 22, 25, 35, CameraReach.pitch.upperBound]
        let distances: [Float] = [CameraReach.distance.lowerBound, 40, CameraReach.distance.upperBound]
        let halfHeight = tan(CameraReach.fieldOfView / 2 * degree)
        // As wide as a phone held sideways.
        let halfWidth = halfHeight * 2.2

        var looked = 0
        for pivot in pivots {
            for yaw in stride(from: Float(0), to: 360, by: 22.5) {
                for pitch in pitches {
                    for distance in distances {
                        let (eye, forward, up, right) = camera(pivot: pivot, yaw: yaw * degree, pitch: pitch * degree, distance: distance)
                        XCTAssertGreaterThan(eye.y, HorizonPlan.height(x: eye.x, z: eye.z) + 0.3, "the camera is under the ground")

                        // The shallowest ray it sees, at its top corners.
                        let corner = forward + up * halfHeight + right * halfWidth
                        let shallowest = atan2(-corner.y, (corner.x * corner.x + corner.z * corner.z).squareRoot())
                        let depressions = [0, 0.5, 1.5, 4, 8].map { max(shallowest, 0.05 * degree) + $0 * degree }

                        // Every way it can see round the horizon.
                        let across = atan(halfWidth / cos(pitch * degree))
                        let heading = atan2(forward.x, forward.z)
                        for turn in stride(from: -across, through: across, by: 3 * degree) {
                            for depression in depressions {
                                let direction = SIMD3<Float>(
                                    sin(heading + turn) * cos(depression),
                                    -sin(depression),
                                    cos(heading + turn) * cos(depression)
                                )
                                looked += 1
                                if let gap = gap(from: eye, along: direction) {
                                    XCTFail("Looking at \(pivot) from yaw \(yaw)°, pitch \(pitch)°, \(distance) m away, a ray \(depression / degree)° down goes past the edge at \(gap)")
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(looked, 1000)
    }

    /// Where the camera is, and which ways it faces, as `CameraRig` places it.
    private func camera(pivot: SIMD2<Float>, yaw: Float, pitch: Float, distance: Float) -> (eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>) {
        func turned(_ v: SIMD3<Float>) -> SIMD3<Float> {
            [v.x * cos(yaw) + v.z * sin(yaw), v.y, -v.x * sin(yaw) + v.z * cos(yaw)]
        }
        let eye = turned([0, distance * sin(pitch), distance * cos(pitch)]) + [pivot.x, 0, pivot.y]
        return (eye, turned([0, -sin(pitch), -cos(pitch)]), turned([0, cos(pitch), -sin(pitch)]), turned([1, 0, 0]))
    }

    /// Where a ray from `eye` along `direction` gets to without landing on
    /// anything, or `nil` if it lands. The land counts as 2 m lower than
    /// planned, for the mesh it is drawn with being coarser.
    private func gap(from eye: SIMD3<Float>, along direction: SIMD3<Float>) -> SIMD3<Float>? {
        let reach = HorizonPlan.skyRadius - 50
        var travelled: Float = 0
        while travelled < reach {
            travelled += max(3, travelled * 0.03)
            let point = eye + direction * travelled
            if point.y < HorizonPlan.waterLevel { return nil }
            if point.y < HorizonPlan.height(x: point.x, z: point.z) - 2 { return nil }
        }
        return eye + direction * reach
    }
}
