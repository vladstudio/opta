import AppKit
import Foundation
import UniformTypeIdentifiers

let acceptedImageTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
let acceptedExtensions = Set(["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp"])

enum OutputFormat: String, CaseIterable {
    case png = "PNG"
    case webp = "WebP"
}

enum FileStatus {
    case waiting, working, done(beforeKB: Int64, afterKB: Int64), error(String)
}

class FileItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let originalSize: Int64
    @Published var status: FileStatus?

    let icon: NSImage
    var filename: String { url.lastPathComponent }
    var isPNG: Bool { url.pathExtension.lowercased() == "png" }

    init(url: URL) {
        self.url = url
        self.originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int64) ?? 0
        self.icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}

let colorSteps = [0, 256, 128, 64, 32, 16, 4, 2]

func colorLabel(_ index: Int) -> String {
    colorSteps[index] == 0 ? "All" : "\(colorSteps[index])"
}
