import Foundation

func desktopCaptureURL(prefix: String, ext: String) -> URL {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return desktop.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).\(ext)")
}
