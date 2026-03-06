import SwiftUI
import UIKit

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            let granted = await LocalNotificationManager.shared.requestPermission()
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await ChatAPI.registerPushToken(token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Happens on simulator and on unsigned/unentitled builds.
        print("[push] failed to register: \(error.localizedDescription)")
    }
}

@main
struct IOSUIApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
