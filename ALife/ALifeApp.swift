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
    #if os(iOS)
    /// Push notifications when a character finishes, and where tapping one
    /// leads. The iPhone and iPad app only.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registration: PushRegistration
    #endif

    init() {
        let server = ServerConnection()
        _server = State(initialValue: server)
        #if os(iOS)
        _registration = State(initialValue: PushRegistration(
            server: server,
            environment: AppDelegate.pushEnvironment,
            bundleID: Bundle.main.bundleIdentifier ?? "com.q231950.alife",
            deviceName: UIDevice.current.name
        ))
        #endif

        TileComponent.registerComponent()
        LotComponent.registerComponent()
        WalkComponent.registerComponent()
        SheepComponent.registerComponent()
        CommuteComponent.registerComponent()
        BurstComponent.registerComponent()
        SpinComponent.registerComponent()
        BlinkComponent.registerComponent()
        HorseComponent.registerComponent()
        AnimalComponent.registerComponent()
        PenAnimalComponent.registerComponent()
        RingComponent.registerComponent()
        SkyComponent.registerComponent()
        NightLightsComponent.registerComponent()
        PaintComponent.registerComponent()
        BoxEdgesComponent.registerComponent()
        CameraRigComponent.registerComponent()
        WalkSystem.registerSystem()
        SheepSystem.registerSystem()
        CommuteSystem.registerSystem()
        BurstSystem.registerSystem()
        TurbineSystem.registerSystem()
        BarnSystem.registerSystem()
        RingSystem.registerSystem()
        DaySystem.registerSystem()
        CameraRigSystem.registerSystem()
    }

    // Spelled out because RealityKit has a `Scene` type too.
    var body: some SwiftUI.Scene {
        WindowGroup {
            WorldView()
                .environment(server)
                .environment(voices)
                #if os(iOS)
                .environment(appDelegate.router)
                .environment(registration)
                .task {
                    appDelegate.attach(server: server, registration: registration)
                    await PushPermission.resume(registration)
                }
                .onChange(of: server.serverURL) {
                    // Moves the registration to the new server.
                    Task { await registration.refresh() }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
