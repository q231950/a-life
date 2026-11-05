#if os(iOS)
import ARKit
import Observation
import RealityKit
import SwiftUI

/// Puts the lot on whichever real surface the person picks: a floor, a table
/// or a wall.
///
/// While placing, a see-through lot follows the middle of the screen, lying
/// flat on the surface under it. A tap pins it there with an ARKit anchor,
/// which keeps it in place while you walk around it.
@MainActor
@Observable
final class SurfacePlacement {
    enum Phase {
        /// Nothing under the middle of the screen yet.
        case searching
        /// The see-through lot shows where a tap would put it.
        case previewing
        /// Pinned to a surface.
        case placed
    }

    private(set) var phase: Phase = .searching

    /// The ARKit session behind the RealityView. We hand it to RealityKit
    /// ourselves so we can raycast against real surfaces and add anchors.
    let session = ARSession()

    /// Follows the surface under the middle of the screen while placing.
    /// Add it to the RealityView's content.
    let preview = Entity()

    private let world: World
    private let tracking = SpatialTrackingSession()
    @ObservationIgnored private var pin: (anchor: ARAnchor, entity: AnchorEntity)?
    @ObservationIgnored private var framesWithoutSurface = 0

    init(world: World) {
        self.world = world
        preview.addChild(world.contentForSurface())
        preview.isEnabled = false
        world.setPreview(true)
    }

    func start() async {
        // The Simulator SDK has no `run(_:session:arConfiguration:)`. The
        // Simulator never gets here anyway: `Stage.choose()` picks the window.
        #if !targetEnvironment(simulator)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        await tracking.run(
            SpatialTrackingSession.Configuration(tracking: [.world, .plane]),
            session: session,
            arConfiguration: configuration
        )
        // With this overload the app runs the ARKit session, per Apple's
        // docs. Running it again with the same configuration is harmless.
        session.run(configuration)
        #endif
    }

    /// Call every frame. Moves the preview onto the surface in the middle of the screen.
    func update(deltaTime: Float) {
        guard phase != .placed, let frame = session.currentFrame else { return }

        guard let pose = surfacePose(in: frame) else {
            // Raycasts drop out now and then. Only give up after a moment.
            framesWithoutSurface += 1
            if framesWithoutSurface > 20 {
                preview.isEnabled = false
                change(to: .searching)
            }
            return
        }
        framesWithoutSurface = 0

        if preview.isEnabled {
            // Glide rather than jump, so a jittery estimate doesn't shake the lot.
            let t = 1 - exp(-deltaTime * 15)
            preview.position = simd_mix(preview.position, pose.translation, SIMD3(repeating: t))
            preview.orientation = simd_slerp(preview.orientation, pose.rotation, t)
        } else {
            preview.transform = pose
            preview.isEnabled = true
        }
        change(to: .previewing)
    }

    /// Pins the lot where the preview is.
    func place() {
        guard phase == .previewing, let scene = preview.scene else { return }
        let anchor = ARAnchor(name: "lot", transform: preview.transformMatrix(relativeTo: nil))
        session.add(anchor: anchor)
        let pinned = AnchorEntity(anchor: anchor)
        scene.addAnchor(pinned)
        pinned.addChild(world.root)

        preview.isEnabled = false
        world.setPreview(false)
        pin = (anchor, pinned)
        change(to: .placed)
    }

    /// Takes the lot off its surface so it can be placed somewhere else.
    func pickUp() {
        guard let pin else { return }
        // Start the preview where the lot is now, so it glides from there.
        preview.transform = Transform(matrix: pin.entity.transformMatrix(relativeTo: nil))
        preview.isEnabled = true
        preview.addChild(world.root)
        pin.entity.removeFromParent()
        session.remove(anchor: pin.anchor)

        self.pin = nil
        world.setPreview(true)
        framesWithoutSurface = 0
        change(to: .previewing)
    }

    /// Only touch `phase` when it changes, so SwiftUI isn't asked to redraw every frame.
    private func change(to newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }

    // MARK: Finding the surface

    /// Where the lot would go on the surface in the middle of the screen: on
    /// it, with the lot's up being the surface's normal.
    private func surfacePose(in frame: ARFrame) -> Transform? {
        func raycast(_ target: ARRaycastQuery.Target) -> ARRaycastResult? {
            let middle = CGPoint(x: 0.5, y: 0.5) // in the camera image, which is also the middle of the screen
            return session.raycast(frame.raycastQuery(from: middle, allowing: target, alignment: .any)).first
        }
        // Planes ARKit has already mapped are steadiest. Otherwise take an
        // estimate, which LiDAR makes quick and good.
        guard let hit = raycast(.existingPlaneGeometry) ?? raycast(.estimatedPlane) else { return nil }

        let position = hit.worldTransform.columns.3.xyz
        let toCamera = simd_normalize(frame.camera.transform.columns.3.xyz - position)

        // A plane anchor's y-axis is the plane's normal, and a hit follows
        // the same convention. Snap it level or upright where ARKit says so.
        var up = ((hit.anchor as? ARPlaneAnchor)?.transform ?? hit.worldTransform).columns.1.xyz
        switch hit.targetAlignment {
        case .horizontal: up = [0, 1, 0]
        case .vertical: up.y = 0
        default: break
        }
        guard simd_length(up) > 0.001 else { return nil }
        up = simd_normalize(up)
        // Face the camera: up on floors and tables, out of a wall, down from a ceiling.
        if simd_dot(up, toCamera) < 0 { up = -up }

        // Lying down, the lot's front edge faces you. Upright, its front edge
        // is at the bottom, like a map on a wall. Straight overhead there's no
        // "towards you", so keep the way the preview already faces.
        let lyingDown = abs(up.y) > 0.7
        let candidates: [SIMD3<Float>] = [
            lyingDown ? toCamera : [0, -1, 0],
            preview.isEnabled ? preview.transform.matrix.columns.2.xyz : [0, 0, 1],
            [1, 0, 0],
        ]
        guard let forward = candidates.lazy.map({ $0 - simd_dot($0, up) * up }).first(where: { simd_length($0) > 0.05 })
        else { return nil }

        let z = simd_normalize(forward)
        let x = simd_cross(up, z)
        return Transform(rotation: simd_quatf(simd_float3x3(columns: (x, up, z))), translation: position)
    }
}

/// Apple's standard "move your iPhone" coaching, shown until ARKit has found
/// a surface and again whenever tracking is lost.
struct CoachingOverlay: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARCoachingOverlayView {
        let view = ARCoachingOverlayView()
        view.session = session
        view.goal = .anyPlane
        view.activatesAutomatically = true
        return view
    }

    func updateUIView(_ view: ARCoachingOverlayView, context: Context) {}
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
#endif
