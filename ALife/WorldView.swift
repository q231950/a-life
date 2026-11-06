import SwiftUI
import RealityKit
#if os(macOS)
import AppKit
#endif

struct WorldView: View {
    @State private var world: World?
    /// `nil` until `Stage.choose()` has answered, which on iOS can mean
    /// waiting for the camera permission prompt.
    @State private var stage: Stage?
    #if os(iOS)
    @State private var placement: SurfacePlacement?
    #endif
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    var body: some View {
        ZStack {
            if let stage {
                scene(on: stage)
            } else {
                Color.clear
            }
        }
        .task {
            stage = await Stage.choose()
        }
        #if os(macOS)
        .onAppear(perform: startScrollZoom)
        .onDisappear(perform: stopScrollZoom)
        #endif
    }

    private func scene(on stage: Stage) -> some View {
        RealityView { content in
            let world = World()
            self.world = world
            switch stage {
            case .window:
                #if os(iOS)
                // On iOS a RealityView shows the camera unless told otherwise.
                content.camera = .virtual
                #endif
                content.add(world.contentForWindow())
            #if os(iOS)
            case .surface:
                let placement = SurfacePlacement(world: world)
                self.placement = placement
                await placement.start(in: &content)
            #endif
            }
        }
        .ignoresSafeArea()
        // Taps on tiles are handled by the tiles themselves (see
        // `World.placeFloor()`). On a real surface you walk around the lot
        // instead of orbiting it.
        .simultaneousGesture(orbit, isEnabled: stage == .window)
        .simultaneousGesture(zoom, isEnabled: stage == .window)
        #if os(iOS)
        .simultaneousGesture(tapToPlace, isEnabled: placement?.phase == .previewing)
        .overlay {
            if let placement {
                CoachingOverlay(session: placement.session)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if placement.phase != .placed {
                    reticle
                }
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            GlassEffectContainer {
                HStack {
                    Text(hint(on: stage))
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect()
                    #if os(iOS)
                    if placement?.phase == .placed {
                        Button("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                            placement?.pickUp()
                        }
                        .font(.footnote)
                        .buttonStyle(.glass)
                    }
                    #endif
                }
            }
            .padding()
        }
    }

    private func hint(on stage: Stage) -> String {
        switch stage {
        case .window:
            #if os(macOS)
            return "Click the grass to walk · drag to orbit · scroll or pinch to zoom"
            #else
            return "Tap the grass to walk · drag to orbit · pinch to zoom"
            #endif
        #if os(iOS)
        case .surface:
            switch placement?.phase ?? .searching {
            case .searching: return "Point the camera at a floor, a table or a wall"
            case .previewing: return "Tap to put the lot here"
            case .placed: return "Tap the grass to walk"
            }
        #endif
        }
    }

    #if os(iOS)
    /// Marks the middle of the screen, where the lot will go.
    private var reticle: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 2)
            .frame(width: 28, height: 28)
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }
    #endif

    // MARK: Gestures

    #if os(iOS)
    /// Tap anywhere to put the lot where the preview is. The preview's tiles
    /// ignore taps, so this doesn't also start a walk.
    private var tapToPlace: some Gesture {
        TapGesture()
            .onEnded { placement?.place() }
    }
    #endif

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
    #endif
}

#Preview {
    WorldView()
}
