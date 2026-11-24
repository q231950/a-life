#if canImport(simd)
import simd
#endif
import XCTest
import ALifeAPI
@testable import ALifeClient

/// The lot's box: walls on its edges with the world painted on them, a flat
/// sky over the top, and a camera that never leaves it.
final class HorizonPlanTests: XCTestCase {
    private let degree = Float.pi / 180
    private let half = HorizonPlan.halfWidth

    func testTheCompassPointsSouthBehindTheOffice() {
        // The office's front faces +z, so south is -z, behind it.
        XCTAssertEqual(HorizonPlan.bearing(x: 0, z: -1), .pi, accuracy: 1e-5)
        XCTAssertEqual(HorizonPlan.bearing(x: 0, z: 1), 0, accuracy: 1e-5)
        XCTAssertEqual(HorizonPlan.bearing(x: -1, z: 0), .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(HorizonPlan.bearing(x: 1, z: 0), 3 * .pi / 2, accuracy: 1e-5)
        let point = HorizonPlan.point(bearing: 1.2, distance: 30)
        XCTAssertEqual(HorizonPlan.bearing(x: point.x, z: point.z), 1.2, accuracy: 1e-5)
        XCTAssertEqual((point.x * point.x + point.z * point.z).squareRoot(), 30, accuracy: 1e-4)
    }

    func testTheWallsStandOnTheLotsEdges() {
        XCTAssertEqual(half * 2, Float(LotPlan.width))
        XCTAssertEqual(half * 2, Float(LotPlan.depth))
        var last = HorizonPlan.wallPoint(around: 0, height: 0)
        var lastBearing: Float = 0
        for around in stride(from: Float(0.25), through: HorizonPlan.perimeter, by: 0.25) {
            let spot = HorizonPlan.wallSpot(around: around)
            // On the edge, facing in.
            XCTAssertEqual(max(abs(spot.x), abs(spot.z)), half, accuracy: 1e-4)
            let inside = HorizonPlan.wallPoint(around: around, height: 0, inset: 1)
            XCTAssertEqual(simd_dot(inside, -spot.wall.inward), half - 1, accuracy: 1e-4)
            // All the way round without a gap, from left to right as seen
            // from inside, which is the way the bearing grows.
            let point = HorizonPlan.wallPoint(around: around, height: 0)
            XCTAssertEqual(simd_distance(point, last), 0.25, accuracy: 1e-3)
            last = point
            let bearing = HorizonPlan.bearing(around: around)
            if around < HorizonPlan.perimeter - 0.5 {
                XCTAssertGreaterThan(bearing, lastBearing)
            }
            lastBearing = bearing
        }
        XCTAssertEqual(HorizonPlan.wallSpot(around: 0).wall, .north)
        XCTAssertEqual(HorizonPlan.wallSpot(around: 2 * half).wall, .east)
        XCTAssertEqual(HorizonPlan.wallSpot(around: 4 * half).wall, .south)
        XCTAssertEqual(HorizonPlan.wallSpot(around: 6 * half).wall, .west)
        XCTAssertEqual(HorizonPlan.Wall.south.inward, [0, 0, 1])
        XCTAssertEqual(HorizonPlan.Wall.east.inward, [1, 0, 0])
    }

    func testTheRegionsGoRoundTheWalls() {
        // The bay all along the south wall, the mountains all along the
        // north wall, and the hills in the middle of the east and west.
        for around in stride(from: 3 * half, through: 5 * half, by: 1) {
            XCTAssertEqual(HorizonPlan.regions(around: around).sea, 1, accuracy: 1e-5)
        }
        for around in stride(from: -half, through: half, by: 1) {
            XCTAssertEqual(HorizonPlan.regions(around: around).mountains, 1, accuracy: 1e-5)
        }
        XCTAssertEqual(HorizonPlan.regions(around: 2 * half).hills, 1)
        XCTAssertEqual(HorizonPlan.regions(around: 6 * half).hills, 1)
        for bearing in stride(from: Float(0), to: 2 * .pi, by: 0.05) {
            let regions = HorizonPlan.regions(bearing: bearing)
            XCTAssertEqual(regions.sea + regions.mountains + regions.hills, 1, accuracy: 1e-5)
        }
        XCTAssertTrue([HorizonPlan.city.lowerBound, HorizonPlan.city.upperBound].allSatisfy { HorizonPlan.wallSpot(around: $0).wall == .south })
    }

    func testThePaintedWorldFitsOnTheWalls() {
        var highest: (ridge: Float, around: Float) = (0, 0)
        for around in stride(from: Float(0), to: HorizonPlan.perimeter, by: 0.5) {
            let ridge = HorizonPlan.farRidge(around: around)
            let land = HorizonPlan.nearLand(around: around)
            XCTAssertGreaterThan(ridge, 0)
            XCTAssertGreaterThan(land, 0)
            XCTAssertLessThan(ridge, HorizonPlan.wallHeight - 6, "the mountains reach the sky")
            XCTAssertLessThan(HorizonPlan.snowLine(around: around), HorizonPlan.wallHeight - 6)
            if ridge > highest.ridge { highest = (ridge, around) }
            // The bay's horizon shows over the beach on the south wall.
            if HorizonPlan.wallSpot(around: around).wall == .south {
                XCTAssertLessThan(land, HorizonPlan.horizonHeight)
                XCTAssertGreaterThan(ridge, HorizonPlan.horizonHeight)
            }
        }
        // The highest peaks, with snow on them, are to the north.
        XCTAssertGreaterThan(highest.ridge, HorizonPlan.snowLine(around: highest.around))
        XCTAssertGreaterThan(HorizonPlan.regions(around: highest.around).mountains, 0.5)
    }

    func testTheSkyIsPaintedOnTheWallsAndOverThem() {
        for elevation in stride(from: Float(1), through: 90, by: 4) {
            for bearing in stride(from: Float(0), to: 360, by: 7) {
                let flat = HorizonPlan.point(bearing: bearing * degree, distance: 1)
                let direction = SIMD3<Float>(flat.x * cos(elevation * degree), sin(elevation * degree), flat.z * cos(elevation * degree))
                let (point, inward) = HorizonPlan.skyPoint(direction: direction)
                // On the box, facing into it.
                let onWall = abs(max(abs(point.x), abs(point.z)) - half) < 1e-3 && point.y <= HorizonPlan.wallHeight + 1e-3
                let onSky = abs(point.y - HorizonPlan.wallHeight) < 1e-3 && max(abs(point.x), abs(point.z)) <= half + 1e-3
                XCTAssertTrue(onWall || onSky, "\(point) is off the box")
                XCTAssertLessThan(simd_dot(inward, point), 0)
                // Where you would see it from the middle.
                XCTAssertEqual(HorizonPlan.skyElevation(at: point), elevation * degree, accuracy: 1e-3)
                XCTAssertEqual(simd_dot(simd_normalize(point - HorizonPlan.skyCentre), simd_normalize(direction)), 1, accuracy: 1e-4)
            }
        }
    }

    // MARK: The edges

    func testTheBoxHasTwelveEdgesWhereItsSidesMeet() {
        let edges = HorizonPlan.edges
        XCTAssertEqual(edges.count, 12)
        XCTAssertEqual(HorizonPlan.sides.count, 6)
        var corners: [SIMD3<Float>: Int] = [:]
        for edge in edges {
            // Along the box's own lines: as long as a wall is wide, or tall.
            let length = simd_distance(edge.from, edge.to)
            XCTAssertTrue(abs(length - 2 * half) < 1e-4 || abs(length - HorizonPlan.wallHeight) < 1e-4, "\(length)")
            // Between two sides at right angles, lying on both of them.
            XCTAssertEqual(simd_dot(edge.sides.0, edge.sides.1), 0)
            XCTAssertEqual(simd_dot(edge.to - edge.from, edge.sides.0), 0, accuracy: 1e-4)
            XCTAssertEqual(simd_dot(edge.to - edge.from, edge.sides.1), 0, accuracy: 1e-4)
            for end in [edge.from, edge.to] {
                XCTAssertEqual(max(abs(end.x), abs(end.z)), half, accuracy: 1e-4)
                XCTAssertTrue(end.y == 0 || end.y == HorizonPlan.wallHeight)
                corners[end, default: 0] += 1
            }
        }
        // Three edges meet at each of the box's eight corners.
        XCTAssertEqual(corners.count, 8)
        XCTAssertTrue(corners.values.allSatisfy { $0 == 3 })
        // Four along the lot, four under the sky, and four up the corners.
        XCTAssertEqual(edges.filter { $0.from.y == 0 && $0.to.y == 0 }.count, 4)
        XCTAssertEqual(edges.filter { $0.from.y == HorizonPlan.wallHeight && $0.to.y == HorizonPlan.wallHeight }.count, 4)
        XCTAssertEqual(edges.filter { $0.from.y != $0.to.y }.count, 4)
    }

    func testTheSeamsShadeSoftlyAwayFromTheEdges() {
        XCTAssertEqual(HorizonPlan.seamShade(at: 0, width: 2), HorizonPlan.seamShade)
        XCTAssertGreaterThan(HorizonPlan.seamShade, 0)
        XCTAssertLessThan(HorizonPlan.seamShade, 0.5, "gently")
        XCTAssertEqual(HorizonPlan.seamShade(at: 2, width: 2), 0)
        XCTAssertEqual(HorizonPlan.seamShade(at: 5, width: 2), 0)
        var previous = HorizonPlan.seamShade(at: 0, width: 2)
        for distance in stride(from: Float(0.01), through: 2, by: 0.01) {
            let shade = HorizonPlan.seamShade(at: distance, width: 2)
            XCTAssertLessThan(shade, previous)
            XCTAssertLessThan(previous - shade, 0.01, "no hard line")
            previous = shade
        }
    }

    // MARK: The camera

    /// Every camera the rig allows, round pivots all over the lot, at a
    /// spread of turns, tilts (looking up as far as it goes) and zooms: it
    /// is inside the box, clear of the walls, the grass and the sky, and
    /// every ray it sees, out to the corners of a wide or a tall screen,
    /// ends on the lot, a wall or the sky, never beyond them.
    func testNoCameraLeavesTheBoxOrSeesPastItsWalls() {
        let edge = half - 0.5
        var pivots: [SIMD3<Float>] = []
        for x in stride(from: -edge, through: edge, by: edge / 2) {
            for z in stride(from: -edge, through: edge, by: edge / 2) {
                pivots.append([x, 0, z])
            }
        }
        let tilts = stride(from: CameraReach.tilt.lowerBound, through: CameraReach.tilt.upperBound, by: 7.5).map { $0 } + [CameraReach.pitch.lowerBound]
        let distances = [CameraReach.distance.lowerBound, 20, 40, CameraReach.distance.upperBound]
        let halfHeight = tan(CameraReach.fieldOfView / 2 * degree)
        // A phone held sideways, and upright.
        let screens: [Float] = [2.2, 0.46]
        let limit = half - CameraReach.wallGap

        var looked = 0
        for pivot in pivots {
            for yaw in stride(from: Float(0), to: 360, by: 15) {
                for tilt in tilts {
                    for distance in distances {
                        let view = CameraReach.view(lookingAt: pivot, yaw: yaw * degree, tilt: tilt * degree, distance: distance)
                        let eye = view.eye
                        guard abs(eye.x) <= limit + 1e-4, abs(eye.z) <= limit + 1e-4,
                              eye.y >= CameraReach.floor - 1e-4, eye.y <= CameraReach.ceiling + 1e-4 else {
                            return XCTFail("Round \(pivot) at yaw \(yaw)°, tilt \(tilt)°, \(distance) m, the camera is at \(eye), outside the box")
                        }
                        XCTAssertLessThanOrEqual(view.elevation, CameraReach.highestLook * degree + 1e-4)

                        let (forward, up, right) = axes(of: view)
                        for aspect in screens {
                            for across in stride(from: Float(-1), through: 1, by: 0.5) {
                                for upward in stride(from: Float(-1), through: 1, by: 0.5) {
                                    let ray = simd_normalize(forward + up * (upward * halfHeight) + right * (across * halfHeight * aspect))
                                    looked += 1
                                    let end = whereRayEnds(from: eye, along: ray)
                                    let inBox = max(abs(end.x), abs(end.z)) <= half + 1e-3 && end.y >= -1e-3 && end.y <= HorizonPlan.wallHeight + 1e-3
                                    if !inBox {
                                        return XCTFail("Round \(pivot) at yaw \(yaw)°, tilt \(tilt)°, \(distance) m, a ray leaves the box at \(end)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(looked, 100_000)
    }

    /// While it isn't looking up, the camera always has the point it turns
    /// round in view, however the walls have pushed it about.
    func testThePivotStaysInView() {
        let edge = half - 0.5
        let halfHeight = tan(CameraReach.fieldOfView / 2 * degree)
        for pivot: SIMD3<Float> in [[0, 0, 0], [edge, 0, 0], [edge, 0, edge], [-edge, 0, 10], [12, 0, -edge]] {
            for yaw in stride(from: Float(0), to: 360, by: 10) {
                for pitch in stride(from: CameraReach.pitch.lowerBound, through: CameraReach.pitch.upperBound, by: 5) {
                    for distance in stride(from: CameraReach.distance.lowerBound, through: CameraReach.distance.upperBound, by: 7) {
                        let view = CameraReach.view(lookingAt: pivot, yaw: yaw * degree, tilt: pitch * degree, distance: distance)
                        let (forward, up, right) = axes(of: view)
                        let toPivot = pivot - view.eye
                        let ahead = simd_dot(toPivot, forward)
                        XCTAssertGreaterThan(ahead, 0)
                        // Within the frame of a phone held upright.
                        XCTAssertLessThanOrEqual(abs(simd_dot(toPivot, up)) / ahead, halfHeight + 1e-3)
                        XCTAssertLessThanOrEqual(abs(simd_dot(toPivot, right)) / ahead, halfHeight * 0.46 + 1e-3, "round \(pivot) at yaw \(yaw)°, pitch \(pitch)°, \(distance) m")
                    }
                }
            }
        }
    }

    /// Dragging and zooming move the camera without jumps, even where the
    /// walls stop it: however small the step, the camera moves and turns
    /// only a little. (Where a long boom is stopped close to the pivot it
    /// can turn quickly, which the rig eases out.)
    func testTheCameraMovesWithoutJumps() {
        let pivots: [SIMD3<Float>] = [[0, 0, 0], [28, 0, 3], [-31, 0, -31], [31.5, 0, 31.5]]
        let step: Float = 0.0001
        for pivot in pivots {
            for distance in [CameraReach.distance.lowerBound, 30, CameraReach.distance.upperBound] {
                for tilt in [CameraReach.tilt.lowerBound, -30, 5, 45, CameraReach.pitch.upperBound] {
                    var last = CameraReach.view(lookingAt: pivot, yaw: 0, tilt: tilt * degree, distance: distance)
                    for yaw in stride(from: step, through: 2 * .pi, by: step) {
                        let view = CameraReach.view(lookingAt: pivot, yaw: yaw, tilt: tilt * degree, distance: distance)
                        XCTAssertLessThan(simd_distance(view.eye, last.eye), 0.02)
                        XCTAssertLessThan(simd_distance(view.forward, last.forward), 0.02, "round \(pivot) at yaw \(yaw / degree)°, tilt \(tilt)°, \(distance) m")
                        last = view
                    }
                }
                for yaw in stride(from: Float(0), to: 360, by: 30) {
                    var last = CameraReach.view(lookingAt: pivot, yaw: yaw * degree, tilt: CameraReach.tilt.lowerBound * degree, distance: distance)
                    for tilt in stride(from: CameraReach.tilt.lowerBound * degree, through: CameraReach.tilt.upperBound * degree, by: step) {
                        let view = CameraReach.view(lookingAt: pivot, yaw: yaw * degree, tilt: tilt, distance: distance)
                        XCTAssertLessThan(simd_distance(view.eye, last.eye), 0.02)
                        XCTAssertLessThan(simd_distance(view.forward, last.forward), 0.02)
                        last = view
                    }
                }
                var last = CameraReach.view(lookingAt: pivot, yaw: 1, tilt: 30 * degree, distance: CameraReach.distance.lowerBound)
                for zoom in stride(from: CameraReach.distance.lowerBound, through: CameraReach.distance.upperBound, by: 0.005) {
                    let view = CameraReach.view(lookingAt: pivot, yaw: 1, tilt: 30 * degree, distance: zoom)
                    XCTAssertLessThan(simd_distance(view.eye, last.eye), 0.02)
                    XCTAssertLessThan(simd_distance(view.forward, last.forward), 0.02)
                    last = view
                }
            }
        }
    }

    func testTiltingPastLevelLooksUpAtTheSky() {
        let level = CameraReach.view(lookingAt: .zero, yaw: 0, tilt: CameraReach.pitch.lowerBound * degree, distance: 20)
        XCTAssertEqual(level.elevation, -CameraReach.pitch.lowerBound * degree, accuracy: 1e-4)
        let up = CameraReach.view(lookingAt: .zero, yaw: 0, tilt: CameraReach.tilt.lowerBound * degree, distance: 20)
        // It stays where it was, and looks nearly straight up.
        XCTAssertEqual(simd_distance(up.eye, level.eye), 0, accuracy: 1e-4)
        XCTAssertGreaterThan(up.elevation, 75 * degree)
        XCTAssertGreaterThan(up.forward.y, 0.95)
    }

    /// The way the camera looks, its up, and its right.
    private func axes(of view: CameraReach.View) -> (forward: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>) {
        let forward = view.forward
        let right = SIMD3<Float>(cos(view.heading), 0, -sin(view.heading))
        return (forward, simd_cross(right, forward), right)
    }

    /// Where a ray from `eye`, inside the box, leaves it, or the grass it
    /// lands on.
    private func whereRayEnds(from eye: SIMD3<Float>, along ray: SIMD3<Float>) -> SIMD3<Float> {
        var reach = Float.infinity
        if ray.y < 0 { reach = min(reach, -eye.y / ray.y) }
        if ray.y > 0 { reach = min(reach, (HorizonPlan.wallHeight - eye.y) / ray.y) }
        if ray.x != 0 { reach = min(reach, ((ray.x > 0 ? half : -half) - eye.x) / ray.x) }
        if ray.z != 0 { reach = min(reach, ((ray.z > 0 ? half : -half) - eye.z) / ray.z) }
        return eye + ray * reach
    }
}
