import ALifeClient
import RealityKit
import SwiftUI

@main
struct ALifeApp: App {
    /// The app's connection to the a-life-server, and through it a session
    /// per character. The sessions themselves live on the server.
    @State private var server: ServerConnection
    /// The characters' voices, which speak on this device.
    @State private var voices = Voices()

    init() {
        _server = State(initialValue: ServerConnection())

        TileComponent.registerComponent()
        LotComponent.registerComponent()
        WalkComponent.registerComponent()
        SheepComponent.registerComponent()
        CommuteComponent.registerComponent()
        BurstComponent.registerComponent()
        SpinComponent.registerComponent()
        BlinkComponent.registerComponent()
        HorseComponent.registerComponent()
        FoalComponent.registerComponent()
        PenAnimalComponent.registerComponent()
        WalkSystem.registerSystem()
        SheepSystem.registerSystem()
        CommuteSystem.registerSystem()
        BurstSystem.registerSystem()
        TurbineSystem.registerSystem()
        BarnSystem.registerSystem()
    }

    // Spelled out because RealityKit has a `Scene` type too.
    var body: some SwiftUI.Scene {
        WindowGroup {
            WorldView()
                .environment(server)
                .environment(voices)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
