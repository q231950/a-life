import RealityKit
import CoreGraphics

/// A Sims-style orbit camera: a pivot on the ground that turns (yaw) and tilts
/// (pitch), with the camera sitting `distance` metres back along the pivot's +z.
/// The pivot glides to whatever the camera is told to look at.
@MainActor
final class CameraRig {
    /// Where the camera looks, on the ground. It moves, the pivot turns.
    let root = Entity()
    private let pivot = Entity()
    private let camera = PerspectiveCamera()

    private var yaw: Float = .pi / 4
    private var pitch: Float = 45 * .pi / 180
    private var distance: Float = 32

    private let pitchRange: ClosedRange<Float> = (20 * .pi / 180)...(80 * .pi / 180)
    /// Close enough to see the characters' faces, far enough to see the whole lot.
    private let distanceRange: ClosedRange<Float> = 5...100

    // Values at the start of the current drag or pinch.
    private var dragStart: (yaw: Float, pitch: Float)?
    private var zoomStart: Float?

    init() {
        camera.camera.fieldOfViewInDegrees = 45
        root.addChild(pivot)
        pivot.addChild(camera)
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
        let start = dragStart ?? (yaw: yaw, pitch: pitch)
        dragStart = start
        yaw = start.yaw - Float(translation.width) * 0.008
        pitch = (start.pitch + Float(translation.height) * 0.005).clamped(to: pitchRange)
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
        // Pitch first (tilt down towards the pivot), then yaw around the up axis.
        pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
        // A camera looks down its -z, so from +z it faces the pivot.
        camera.position = [0, 0, distance]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
