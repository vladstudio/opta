import AppKit
import SwiftUI
import UserNotifications

class AppState: ObservableObject {
    @Published var pendingURLs: [URL] = []
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            self.appState.pendingURLs.append(contentsOf: urls)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct OptaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Opta", id: "main") {
            ContentView()
                .environmentObject(appDelegate.appState)
        }
        .defaultSize(width: 480, height: 400)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Opta") {
                    NSWorkspace.shared.open(URL(string: "https://apps.vlad.studio/opta")!)
                }
            }
        }
    }
}
