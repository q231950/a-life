import SwiftUI
import RealityKit

@main
struct ALifeApp: App {
    init() {
        TileComponent.registerComponent()
        WalkComponent.registerComponent()
        WalkSystem.registerSystem()
    }

    // Spelled out because RealityKit has a `Scene` type too.
    var body: some SwiftUI.Scene {
        WindowGroup {
            WorldView()
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
