import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Media Tabs

enum MediaTab: String, CaseIterable {
    case images = "Images"
    case video = "Video"
    case audio = "Audio"
}

// MARK: - Image Types (existing)

let acceptedImageTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
let acceptedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp"]

enum ImageOutputFormat: String, CaseIterable {
    case png = "PNG"
    case jpg = "JPG"
    case webp = "WebP"

    var ext: String {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
        case .webp: return "webp"
        }
    }
}

// MARK: - Video Types

let acceptedVideoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv", "wmv", "ts", "mts"]
let acceptedVideoTypes: [UTType] = acceptedVideoExtensions.compactMap { UTType(filenameExtension: $0) }

enum VideoOutputFormat: String, CaseIterable {
    case mp4H264 = "MP4 (H.264)"
    case mp4H265 = "MP4 (H.265)"
    case webmVP9 = "WebM (VP9)"
    case mov = "MOV"
    case gif = "GIF"

    var ext: String {
        switch self {
        case .mp4H264, .mp4H265: return "mp4"
        case .webmVP9: return "webm"
        case .mov: return "mov"
        case .gif: return "gif"
        }
    }

    var crfRange: ClosedRange<Double> {
        switch self {
        case .mp4H264, .mov: return 16...36
        case .mp4H265: return 18...34
        case .webmVP9: return 12...45
        case .gif: return 0...0
        }
    }

    var crfDefault: Double {
        switch self {
        case .mp4H264, .mov: return 30
        case .mp4H265: return 24
        case .webmVP9: return 25
        case .gif: return 0
        }
    }

    var hasCRF: Bool { self != .gif }
}

enum DimensionPreset: Int, CaseIterable {
    case original = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
    case p360 = 360

    var label: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }
}

// MARK: - Audio Types

let acceptedAudioExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"]
let acceptedAudioTypes: [UTType] = acceptedAudioExtensions.compactMap { UTType(filenameExtension: $0) }

enum AudioOutputFormat: String, CaseIterable {
    case mp3 = "MP3"
    case aac = "AAC"
    case m4a = "M4A"
    case oggVorbis = "OGG Vorbis"
    case opus = "Opus"
    case flac = "FLAC"
    case wav = "WAV"

    var ext: String {
        switch self {
        case .mp3: return "mp3"
        case .aac, .m4a: return "m4a"
        case .oggVorbis: return "ogg"
        case .opus: return "opus"
        case .flac: return "flac"
        case .wav: return "wav"
        }
    }

    var isLossless: Bool {
        self == .flac || self == .wav
    }

    var bitrateSteps: [Int] {
        switch self {
        case .mp3: return [128, 160, 192, 224, 256, 320]
        case .aac, .m4a: return [128, 160, 192, 256, 320]
        case .oggVorbis: return [128, 192, 256, 320, 500]
        case .opus: return [96, 128, 192, 256, 320]
        case .flac, .wav: return []
        }
    }

    var bitrateDefault: Int {
        switch self {
        case .mp3: return 320
        case .aac, .m4a: return 256
        case .oggVorbis: return 320
        case .opus: return 256
        case .flac, .wav: return 0
        }
    }
}

// MARK: - Shared

func classifyFile(_ url: URL) -> MediaTab? {
    let ext = url.pathExtension.lowercased()
    if acceptedImageExtensions.contains(ext) { return .images }
    if acceptedVideoExtensions.contains(ext) { return .video }
    if acceptedAudioExtensions.contains(ext) { return .audio }
    return nil
}

// MARK: - File Status & Item

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
