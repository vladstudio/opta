import SwiftUI

class AppState: ObservableObject {
    @Published var pendingURLs: [URL] = []
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            self.appState.pendingURLs.append(contentsOf: urls)
        }
    }
}

@main
struct OptaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.appState)
        }
        .defaultSize(width: 480, height: 400)
        .windowResizability(.contentSize)
    }
}
