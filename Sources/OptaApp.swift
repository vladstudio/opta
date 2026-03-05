import SwiftUI

@main
struct OptaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 480, height: 400)
        .windowResizability(.contentSize)
    }
}
