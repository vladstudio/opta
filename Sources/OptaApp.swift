import SwiftUI
import AppKit

@main
struct OptaApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
