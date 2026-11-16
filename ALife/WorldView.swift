import ALifeClient
import RealityKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorldView: View {
    @Environment(ServerConnection.self) private var server
    @Environment(Voices.self) private var voices
    @State private var world: World?
    /// Says the characters' lines out loud while you stand near them.
    @State private var narrator: Narrator?
    /// The character you are talking to. `nil` means the first one.
    @State private var selectedID: String?
    @State private var showsSettings = false
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    var body: some View {
        RealityView { content in
            let world = World()
            world.show(server.lot, popsUp: false)
            world.show(residents, selectedID: selected?.id)
            content.add(world.root)
            self.world = world
        }
        .ignoresSafeArea()
        .gesture(tap)
        .simultaneousGesture(orbit)
        .simultaneousGesture(zoom)
        .onChange(of: residents) { _, residents in
            world?.show(residents, selectedID: selected?.id)
        }
        .onChange(of: selected?.id) { _, id in
            world?.show(residents, selectedID: id)
        }
        .onChange(of: speakers) { _, speakers in
            narrator?.listen(to: speakers, inEarshot: world?.residentsInEarshot() ?? [])
        }
        .task(id: server.serverURL) {
            voices.load(from: server.voiceModelURL)
        }
        .task {
            await keepEarshot()
        }
        .onChange(of: server.lot) { old, new in
            // Only news from the server this app has heard from already
            // pops up, not what was on the lot when it connected.
            world?.show(new, popsUp: old.revision > 0 && new.revision > old.revision)
        }
        .overlay(alignment: .top) {
            SessionStatusBar(showsSettings: $showsSettings)
                .padding()
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                AgentPanel(selectedID: $selectedID)
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
            server.connect()
            showsSettings = server.phase == .needsServer
        }
        #if os(macOS)
        .onAppear(perform: startScrollZoom)
        .onDisappear(perform: stopScrollZoom)
        #endif
    }

    /// The character you are talking to.
    private var selected: AgentSession? {
        server.session(selectedBy: selectedID)
    }

    /// What the lot shows of each session.
    private var residents: [World.Resident] {
        server.sessions.map { session in
            World.Resident(
                id: session.id,
                name: session.name,
                color: session.color,
                isAtWork: session.status == .running || session.isWaitingForYou,
                isWaitingForYou: session.isWaitingForYou,
                subagents: session.subagents.map(\.id)
            )
        }
    }

    // MARK: Voices

    /// What each character has said lately, for the narrator.
    private var speakers: [Narrator.Speaker] {
        server.sessions.map { Narrator.Speaker(id: $0.id, messages: $0.newMessages) }
    }

    /// Keeps an ear on who is close enough to hear, as you and the
    /// characters walk about, so a character you walk away from stops
    /// talking.
    private func keepEarshot() async {
        let narrator = Narrator(engine: voices)
        narrator.listen(to: speakers, inEarshot: []) // what was said before is let go
        self.narrator = narrator
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            narrator.listenerMoved(inEarshot: world?.residentsInEarshot() ?? [])
        }
        narrator.hush()
    }

    // MARK: Gestures

    /// Tap (or click) a character to talk to it, or a floor tile to walk there.
    private var tap: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                if let id = world?.residentID(of: value.entity) {
                    selectedID = id
                } else {
                    world?.walk(to: value.entity)
                }
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
    private let hint = "Click a character to talk to it · click the grass to walk · drag to orbit · scroll or pinch to zoom"

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
    private let hint = "Tap a character to talk to it · tap the grass to walk · drag to orbit · pinch to zoom"
    #endif
}

#Preview {
    WorldView()
        .environment(ServerConnection(serverURLStore: InMemoryServerURLStore()))
        .environment(Voices())
}
