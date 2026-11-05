import RealityKit
import CoreGraphics

/// A Sims-style orbit camera: a pivot on the ground that turns (yaw) and tilts
/// (pitch), with the camera sitting `distance` metres back along the pivot's +z.
@MainActor
final class CameraRig {
    let root = Entity()
    private let camera = PerspectiveCamera()

    private var yaw: Float = .pi / 4
    private var pitch: Float = 40 * .pi / 180
    private var distance: Float = 16

    private let pitchRange: ClosedRange<Float> = (20 * .pi / 180)...(80 * .pi / 180)
    private let distanceRange: ClosedRange<Float> = 5...30

    // Values at the start of the current drag or pinch.
    private var dragStart: (yaw: Float, pitch: Float)?
    private var zoomStart: Float?

    init() {
        camera.camera.fieldOfViewInDegrees = 45
        root.addChild(camera)
        apply()
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

    /// Mouse wheel / trackpad scroll on macOS.
    func scroll(by delta: CGFloat) {
        distance = (distance - Float(delta) * 0.05).clamped(to: distanceRange)
        apply()
    }

    private func apply() {
        // Pitch first (tilt down towards the pivot), then yaw around the up axis.
        root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
        // A camera looks down its -z, so from +z it faces the pivot.
        camera.position = [0, 0, distance]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
