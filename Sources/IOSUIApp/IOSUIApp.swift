import SwiftUI

@main
struct IOSUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    LocalNotificationManager.shared.requestPermissionIfNeeded()
                }
        }
    }
}
