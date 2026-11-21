import ALifeClient
import Foundation
import RealityKit
import CoreGraphics

/// A Sims-style orbit camera inside the lot's box: a pivot on the ground
/// that the camera turns (yaw) and tilts (pitch) round, `distance` metres
/// back, as far as the walls let it. Tilt it up past level and it looks up
/// at the sky instead. The pivot glides to whatever the camera is told to
/// look at, and `CameraRigSystem` places the camera every frame, where
/// `CameraReach` says it may be.
@MainActor
final class CameraRig {
    /// Where the camera looks, on the ground. It moves, the camera follows.
    let root = Entity()
    private let camera = PerspectiveCamera()

    private var yaw: Float = .pi / 4
    /// How far it tilts down, or below the lowest pitch, up.
    private var tilt: Float = 45 * .pi / 180
    private var distance: Float = 32

    /// From looking up at the sky, through nearly level, to nearly straight
    /// down (see `CameraReach`).
    private let tiltRange: ClosedRange<Float> = (CameraReach.tilt.lowerBound * .pi / 180)...(CameraReach.tilt.upperBound * .pi / 180)
    /// Close enough to see the characters' faces, far enough to see across
    /// the whole lot, as the walls allow.
    private let distanceRange = CameraReach.distance

    // Values at the start of the current drag or pinch.
    private var dragStart: (yaw: Float, tilt: Float)?
    private var zoomStart: Float?

    init() {
        camera.camera.fieldOfViewInDegrees = CameraReach.fieldOfView
        root.addChild(camera)
        apply()
    }

    /// Glides over the lot until it looks at `point`, in the space of the
    /// rig's parent.
    func focus(on point: SIMD3<Float>) {
        let goal = Transform(translation: [point.x, 0, point.z])
        if root.scene == nil {
            root.transform = goal
        } else {
            root.move(to: goal, relativeTo: root.parent, duration: 0.8, timingFunction: .easeInOut)
        }
    }

    func drag(by translation: CGSize) {
        let start = dragStart ?? (yaw: yaw, tilt: tilt)
        dragStart = start
        yaw = start.yaw - Float(translation.width) * 0.008
        tilt = (start.tilt + Float(translation.height) * 0.005).clamped(to: tiltRange)
        apply()
    }

    func endDrag() {
        dragStart = nil
    }

    func zoom(by magnification: CGFloat) {
        let start = zoomStart ?? distance
        zoomStart = start
        distance = (start / Float(max(magnification, 0.01))).clamped(to: distanceRange)
        apply()
    }

    func endZoom() {
        zoomStart = nil
    }

    /// Mouse wheel / trackpad scroll on macOS. Each step goes a bit of the
    /// way, so it feels the same close up and far out.
    func scroll(by delta: CGFloat) {
        distance = (distance * (1 - Float(delta) * 0.003)).clamped(to: distanceRange)
        apply()
    }

    private func apply() {
        var orbit = camera.components[CameraRigComponent.self] ?? CameraRigComponent()
        orbit.yaw = yaw
        orbit.tilt = tilt
        orbit.distance = distance
        camera.components.set(orbit)
    }
}

/// Where the rig's camera is turned, tilted and zoomed to. It sits on the
/// camera, a child of the rig's pivot.
struct CameraRigComponent: Component {
    var yaw: Float = 0
    var tilt: Float = 0
    var distance: Float = 0
    /// Where the camera was last put, in the lot's space, or `nil` until
    /// it has been, so the first time it goes straight there.
    fileprivate var eye: SIMD3<Float>?
}

/// Places the rig's camera every frame, where `CameraReach` says it may be
/// for the pivot's position just then, so it stays inside the box while the
/// pivot glides. It eases there over a few frames, so a quick swing where a
/// wall stops the camera close to the pivot plays out as a short pan.
struct CameraRigSystem: System {
    private static let cameras = EntityQuery(where: .has(CameraRigComponent.self))
    /// How quickly the camera catches up, in seconds.
    private static let ease: Float = 0.06

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        for camera in context.entities(matching: Self.cameras, updatingSystemWhen: .rendering) {
            guard var orbit = camera.components[CameraRigComponent.self], let pivot = camera.parent else { continue }
            let view = CameraReach.view(lookingAt: pivot.position, yaw: orbit.yaw, tilt: orbit.tilt, distance: orbit.distance)
            let orientation = simd_quatf(angle: view.heading, axis: [0, 1, 0]) * simd_quatf(angle: view.elevation, axis: [1, 0, 0])
            // Between two spots in the box is in the box, too.
            var eye = view.eye
            if let was = orbit.eye {
                let share = 1 - exp(-deltaTime / Self.ease)
                eye = was + (view.eye - was) * share
                camera.orientation = simd_slerp(camera.orientation, orientation, share)
            } else {
                camera.orientation = orientation
            }
            camera.position = eye - pivot.position
            orbit.eye = eye
            camera.components.set(orbit)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
