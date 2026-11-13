import ALifeClient
import RealityKit
import SwiftUI

@main
struct ALifeApp: App {
    /// The app's handle on the team's session. The session itself lives on
    /// the a-life-server; this follows it.
    @State private var agentSession: AgentSession

    init() {
        _agentSession = State(initialValue: AgentSession())

        TileComponent.registerComponent()
        WalkComponent.registerComponent()
        WalkSystem.registerSystem()
    }

    // Spelled out because RealityKit has a `Scene` type too.
    var body: some SwiftUI.Scene {
        WindowGroup {
            WorldView()
                .environment(agentSession)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
