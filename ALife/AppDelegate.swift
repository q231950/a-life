#if os(iOS)
import ALifeClient
import UIKit
import UserNotifications

/// The iPhone and iPad app's delegate, for what SwiftUI doesn't offer: the
/// device's token for push notifications, and notifications being shown and
/// tapped. It is the notification centre's delegate from the moment the app
/// launches, so a tap that launched the app isn't missed.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Where a tapped notification leads, for `WorldView` to follow.
    let router = NotificationRouter()
    private weak var server: ServerConnection?
    private var registration: PushRegistration?
    /// A token that came before the registration was attached.
    private var token: Data?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Hands the delegate the app's connection and its registration, once
    /// the app has them.
    func attach(server: ServerConnection, registration: PushRegistration) {
        self.server = server
        self.registration = registration
        if let token {
            Task { await registration.setDeviceToken(token) }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        token = deviceToken
        if let registration {
            Task { await registration.setDeviceToken(deviceToken) }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registration?.couldNotGetToken(error.localizedDescription)
    }

    // MARK: Notifications

    /// While you're in the app, a notification from the server you're
    /// following isn't shown: you hear about the job already. One from
    /// another server, or the test, is.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let route = PushRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            completionHandler(self.presentation(of: route))
        }
    }

    /// A tapped notification: the app opens on that character, at its reply.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if opened, let route {
                self.router.pending = route
            }
            completionHandler()
        }
    }

    private func presentation(of route: PushRoute?) -> UNNotificationPresentationOptions {
        if let route, registration?.isFromThisServer(route) == true, server?.phase == .live {
            return []
        }
        return [.banner, .list, .sound]
    }

    // MARK: Which of Apple's servers

    /// Which of Apple's servers this build's tokens belong to: sandbox for a
    /// build signed for development, as its provisioning profile says, and
    /// production for TestFlight and the App Store, which have none. Read
    /// from the profile rather than `DEBUG`, which a release build run from
    /// Xcode would get wrong.
    static var pushEnvironment: PushEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return .production }
        // A signed property list, with the XML readable in the middle.
        let profile = String(decoding: data, as: UTF8.self)
        guard let key = profile.range(of: "<key>aps-environment</key>") else { return .production }
        let rest = profile[key.upperBound...]
        guard let start = rest.range(of: "<string>"), let end = rest.range(of: "</string>"), start.upperBound <= end.lowerBound else {
            return .production
        }
        let value = rest[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "development" ? .sandbox : .production
        #endif
    }
}

/// Asking iOS for notifications, and for the device's token.
@MainActor
enum PushPermission {
    /// Turns notifications on or off. Turning them on asks iOS first, the
    /// first time, then asks for the device's token, which registers it.
    static func set(_ wanted: Bool, for registration: PushRegistration) async {
        await registration.setWanted(wanted)
        guard wanted else { return }
        await askForToken(registration, mayAsk: true)
    }

    /// On launch: if you want notifications, asks for the token again,
    /// which registers the device again, so the server knows it's about.
    static func resume(_ registration: PushRegistration) async {
        guard registration.isWanted else {
            await registration.refresh() // takes back anything left over
            return
        }
        await askForToken(registration, mayAsk: false)
    }

    private static func askForToken(_ registration: PushRegistration, mayAsk: Bool) async {
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            guard mayAsk else { return }
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            allowed = false
        }
        if allowed {
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            await registration.notAllowed()
        }
    }

    /// Takes a character's notifications out of Notification Centre, once
    /// you've opened its conversation: you've seen what they were about.
    static func removeDelivered(about sessionID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered
                .filter { $0.request.content.threadIdentifier == sessionID }
                .map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
}
#endif
