#if os(iOS)
import ARKit
import AVFoundation
#endif

/// Where the lot is shown. Decided once, at launch.
enum Stage {
    /// In a window, seen through the orbit camera: the Mac, the iOS Simulator,
    /// and iPhones or iPads where the camera may not be used.
    case window
    #if os(iOS)
    /// On a real table, seen through the device camera.
    case table
    #endif

    /// The table when this device can track the world and may use the camera,
    /// otherwise the window. Asks for camera access the first time.
    static func choose() async -> Stage {
        #if os(iOS)
        // False in the Simulator, which has no camera to track with.
        if ARWorldTrackingConfiguration.isSupported, await AVCaptureDevice.requestAccess(for: .video) {
            return .table
        }
        #endif
        return .window
    }
}
