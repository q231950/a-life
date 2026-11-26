import ALifeClient
import RealityKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorldView: View {
    @Environment(ServerConnection.self) private var server
    @Environment(Voices.self) private var voices
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Where a tapped notification leads, and this device's registration
    /// for them. Only the iPhone and iPad app has them.
    @Environment(NotificationRouter.self) private var router: NotificationRouter?
    @Environment(PushRegistration.self) private var registration: PushRegistration?
    @State private var world: World?
    /// Says the characters' lines out loud while you stand near them.
    @State private var narrator: Narrator?
    /// The character you are talking to. `nil` means the first one.
    @State private var selectedID: String?
    @State private var showsSettings = false
    @State private var showsLog = false
    /// How wide the panels at the top left are, the usage and the context,
    /// so the status pill keeps clear of them. 0 while neither shows.
    @State private var topLeftWidth: CGFloat = 0
    /// Whether the agent panel shows the conversation, as the panel keeps it.
    @AppStorage("agentPanelIsExpanded") private var panelIsExpanded = true
    /// Each character's shirt on the lot, for the panel to show them in.
    @State private var shirts: [String: PlatformColor] = [:]
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    var body: some View {
        RealityView { content in
            let world = World()
            world.setDayClock(.lot(for: server.usage), eases: false)
            world.show(server.lot, popsUp: false)
            world.show(residents, selectedID: selected?.id)
            content.add(world.root)
            self.world = world
            shirts = world.shirts
        }
        .ignoresSafeArea()
        .gesture(tap)
        .simultaneousGesture(orbit)
        .simultaneousGesture(zoom)
        .onChange(of: residents) { _, residents in
            world?.show(residents, selectedID: selected?.id)
            shirts = world?.shirts ?? [:]
        }
        .onChange(of: selected?.id) { _, id in
            world?.show(residents, selectedID: id)
        }
        .onChange(of: selectedID) { _, id in
            // Opening a character's conversation shows what it said, so its
            // missed call can go.
            if let id { narrator?.clearMissedCall(from: id) }
            #if os(iOS)
            // Nor its notifications.
            if let id { PushPermission.removeDelivered(about: id) }
            #endif
        }
        .task(id: router?.pending) {
            await followTappedNotification()
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
        .onChange(of: server.usage) { _, usage in
            // The lot's day is the usage window; the sky eases over to a
            // new one.
            world?.setDayClock(.lot(for: usage))
        }
        .overlay(alignment: .top) {
            SessionStatusBar(showsSettings: $showsSettings, showsLog: $showsLog)
                // Kept clear of the panels at the top left on both sides, so
                // it stays centred; on a narrow screen, only on the left, so
                // it has the room to the right of them.
                .padding(.leading, topLeftWidth > 0 ? topLeftWidth + 8 : 0)
                .padding(.trailing, topLeftWidth > 0 && !isNarrow ? topLeftWidth + 8 : 0)
                .padding()
        }
        .overlay(alignment: .topLeading) {
            // The usage, and under it how full the session of the character
            // you're talking to is, both as wide as the wider of the two.
            EqualWidthColumn {
                UsagePanel()
                if let selected {
                    // A fresh one for each character, so the ring doesn't
                    // sweep over from someone else's.
                    ContextPanel(session: selected)
                        .id(selected.id)
                        .environment(\.shirts, shirts)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topLeftWidth = $0 }
            .padding()
        }
        .overlay(alignment: .bottom) {
            AgentPanel(selectedID: $selectedID)
                .environment(\.shirts, shirts)
                .environment(\.narrator, narrator)
                .padding()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showsLog) {
            EventLogView { id in
                selectedID = id
                panelIsExpanded = true
            }
            .environment(\.shirts, shirts)
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

    /// Whether there is little room across, as on an iPhone held upright.
    private var isNarrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Opens the conversation a tapped notification is about, at its reply,
    /// as picking an entry in the log does, once the server has listed that
    /// character: on a cold launch that waits for the connection, for ten
    /// seconds at most. A notification from another server than this one
    /// opens the app as it is, since that character may not be here.
    private func followTappedNotification() async {
        guard let router, let route = router.pending else { return }
        guard registration?.isFromThisServer(route) == true else {
            router.pending = nil
            return
        }
        for _ in 0..<100 where server.session(route.session) == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        router.pending = nil
        guard server.session(route.session) != nil else { return }
        selectedID = route.session
        panelIsExpanded = true
        router.reply = route.message.map { NotificationRouter.Reply(session: route.session, message: $0) }
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
                // It stays at its desk until you've heard it out.
                isAtWork: session.isOnTheJob || narrator?.hasSomethingToSay(session.id) == true,
                isWaitingForYou: session.isWaitingForYou,
                isCalling: narrator?.isCalling(session.id) == true,
                subagents: session.subagents.map(\.id)
            )
        }
    }

    // MARK: Voices

    /// What each character has said lately, and whether it's still on the
    /// job, for the narrator. Only what it said since you came: what it did
    /// while you were away, or while finishing a job it had before, is left
    /// out of `newMessages`, and only goes to the log. A job it finished
    /// while you were away is a missed call.
    private var speakers: [Narrator.Speaker] {
        server.sessions.map {
            Narrator.Speaker(
                id: $0.id, name: $0.name, messages: $0.newMessages, isWorking: $0.isOnTheJob,
                finishedWhileAway: $0.finishedWhileAway
            )
        }
    }

    /// Keeps an ear on who is close enough to hear, as you and the
    /// characters walk about, so a character you walk away from stops
    /// talking, and calls you with the rest once its job is done. Its calls
    /// go in the log too, and which replies you have heard is kept between
    /// launches, for missed calls.
    private func keepEarshot() async {
        let narrator = Narrator(engine: voices, log: server.log, heardStore: UserDefaultsHeardRepliesStore())
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
    /// SwiftUI has no scroll-wheel gesture, so listen for the events directly,
    /// and zoom only when you scroll over the lot itself, not over the panel,
    /// the buttons or anything else laid over it.
    private func startScrollZoom() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = event.scrollingDeltaY
            MainActor.assumeIsolated {
                if event.isOverLot {
                    world?.camera.scroll(by: delta)
                }
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
    #endif
}

#if os(macOS)
extension NSEvent {
    /// Whether the pointer is over the lot itself rather than something laid
    /// over it. SwiftUI's overlays answer AppKit's hit test themselves, so
    /// only open lot finds the RealityView's own view underneath.
    @MainActor
    var isOverLot: Bool {
        guard let content = window?.contentView else { return false }
        let point = content.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        var view = content.hitTest(point)
        while let candidate = view {
            if candidate is ARView { return true }
            view = candidate.superview
        }
        return false
    }
}
#endif

#Preview {
    WorldView()
        .environment(ServerConnection(serverURLStore: InMemoryServerURLStore()))
        .environment(Voices())
}
