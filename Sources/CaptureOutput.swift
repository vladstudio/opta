import Foundation

func captureURL(folder: String?, prefix: String, ext: String) -> URL {
    let dir: URL
    if let path = folder, !path.isEmpty {
        dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return dir.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).\(ext)")
}
