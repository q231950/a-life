import ALifeClient
import RealityKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorldView: View {
    @Environment(AgentSession.self) private var agentSession
    @State private var world: World?
    @State private var showsSettings = false
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    var body: some View {
        RealityView { content in
            let world = World()
            world.show(agentSession.agents)
            content.add(world.root)
            self.world = world
        }
        .ignoresSafeArea()
        .gesture(tapToWalk)
        .simultaneousGesture(orbit)
        .simultaneousGesture(zoom)
        .onChange(of: agentSession.agents) { _, agents in
            world?.show(agents)
        }
        .overlay(alignment: .top) {
            SessionStatusBar(showsSettings: $showsSettings)
                .padding()
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                AgentPanel()
                Text(hint)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .task {
            agentSession.connect()
            showsSettings = agentSession.phase == .needsServer
        }
        #if os(macOS)
        .onAppear(perform: startScrollZoom)
        .onDisappear(perform: stopScrollZoom)
        #endif
    }

    // MARK: Gestures

    /// Tap (or click) a floor tile to walk there.
    private var tapToWalk: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                world?.walk(to: value.entity)
            }
    }

    /// Drag to turn and tilt the camera.
    private var orbit: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in world?.camera.drag(by: value.translation) }
            .onEnded { _ in world?.camera.endDrag() }
    }

    /// Pinch to zoom.
    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in world?.camera.zoom(by: value.magnification) }
            .onEnded { _ in world?.camera.endZoom() }
    }

    #if os(macOS)
    private let hint = "Click the grass to walk · drag to orbit · scroll or pinch to zoom"

    /// SwiftUI has no scroll-wheel gesture, so listen for the events directly.
    private func startScrollZoom() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = event.scrollingDeltaY
            MainActor.assumeIsolated {
                world?.camera.scroll(by: delta)
            }
            return event
        }
    }

    private func stopScrollZoom() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }
    #else
    private let hint = "Tap the grass to walk · drag to orbit · pinch to zoom"
    #endif
}

#Preview {
    WorldView()
        .environment(AgentSession(serverURLStore: InMemoryServerURLStore()))
}
