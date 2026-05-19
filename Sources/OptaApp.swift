import AppKit
import SwiftUI
import UserNotifications

enum AppCommand {
    case selectTab(MediaTab)
    case previewSelection
    case trashSelection
}

class AppState: ObservableObject {
    @Published var pendingURLs: [URL] = []
    @Published private(set) var commandSerial = 0

    private(set) var pendingCommand: AppCommand?

    func send(_ command: AppCommand) {
        pendingCommand = command
        commandSerial &+= 1
    }

    func consumeCommand() -> AppCommand? {
        defer { pendingCommand = nil }
        return pendingCommand
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            CommandMenu("Tabs") {
                Button("Images") {
                    appDelegate.appState.send(.selectTab(.images))
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Video") {
                    appDelegate.appState.send(.selectTab(.video))
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Audio") {
                    appDelegate.appState.send(.selectTab(.audio))
                }
                .keyboardShortcut("3", modifiers: .command)
            }
            CommandMenu("Selection") {
                Button("Quick Look") {
                    appDelegate.appState.send(.previewSelection)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Move to Trash") {
                    appDelegate.appState.send(.trashSelection)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}
