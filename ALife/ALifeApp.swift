import ManagedAgents
import RealityKit
import SwiftUI

@main
struct ALifeApp: App {
    /// The app's handle on the multiagent session. The session itself runs on
    /// Anthropic's side; this remembers its ID and follows it.
    @State private var agentSession: AgentSession

    init() {
        _agentSession = State(initialValue: AgentSession(
            apiKeyStore: KeychainAPIKeyStore(service: "com.q231950.alife")
        ))

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
