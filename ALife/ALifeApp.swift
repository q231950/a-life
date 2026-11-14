import ALifeClient
import RealityKit
import SwiftUI

@main
struct ALifeApp: App {
    /// The app's connection to the a-life-server, and through it a session
    /// per character. The sessions themselves live on the server.
    @State private var server: ServerConnection

    init() {
        _server = State(initialValue: ServerConnection())

        TileComponent.registerComponent()
        LotComponent.registerComponent()
        WalkComponent.registerComponent()
        SheepComponent.registerComponent()
        WalkSystem.registerSystem()
        SheepSystem.registerSystem()
    }

    // Spelled out because RealityKit has a `Scene` type too.
    var body: some SwiftUI.Scene {
        WindowGroup {
            WorldView()
                .environment(server)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
