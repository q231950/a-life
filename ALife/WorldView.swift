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
    @State private var isOnTable = false
    @State private var anchoring: EventSubscription?
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
            switch stage {
            case .window:
                content.add(world.contentForWindow())
            #if os(iOS)
            case .table:
                content.camera = .spatialTracking
                let table = world.contentForTable()
                content.add(table)
                // The lot appears once RealityKit has found a table. Until
                // then the hint says what to do.
                anchoring = content.subscribe(to: SceneEvents.AnchoredStateChanged.self, on: table) { event in
                    isOnTable = event.isAnchored
                }
            #endif
            }
            self.world = world
        }
        .ignoresSafeArea()
        .gesture(tapToWalk)
        // On a table you walk around the lot instead, so the orbit gestures
        // are switched off there. `.subviews` leaves the tap working.
        .simultaneousGesture(orbit, including: stage == .window ? .all : .subviews)
        .simultaneousGesture(zoom, including: stage == .window ? .all : .subviews)
        .overlay(alignment: .bottom) {
            Text(hint(on: stage))
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
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
        case .table:
            return isOnTable
                ? "Tap the grass to walk · move around the table to look"
                : "Point the camera at a table and move it slowly"
        #endif
        }
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
