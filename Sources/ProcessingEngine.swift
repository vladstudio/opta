import Foundation
import ImageIO
import UserNotifications

enum OptaError: LocalizedError {
    case toolNotFound(String)
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            "\(tool) not found"
        case .toolFailed(let tool, let message):
            "\(tool): \(message)"
        }
    }
}

struct ImageJob {
    let format: ImageOutputFormat
    let suffix: String
    let stripMetadata: Bool
    let colorIndex: Int
    let quality: Int
    let oxipngLevel: Int

    var requiredTools: [String] {
        var tools: [String] = []
        if colorSteps.indices.contains(colorIndex), colorSteps[colorIndex] > 0 {
            tools.append("pngquant")
        }
        if format == .png {
            tools.append("oxipng")
        }
        if format == .webp {
            tools.append("cwebp")
        }
        return tools
    }
}

struct VideoJob {
    let format: VideoOutputFormat
    let suffix: String
    let stripMetadata: Bool
    let dimension: DimensionPreset
    let crf: Int

    var requiredTools: [String] { ["ffmpeg"] }
}

struct AudioJob {
    let format: AudioOutputFormat
    let suffix: String
    let stripMetadata: Bool
    let bitrate: Int

    var requiredTools: [String] { ["ffmpeg"] }
}

enum ProcessingJob {
    case images(ImageJob)
    case video(VideoJob)
    case audio(AudioJob)

    var requiredTools: [String] {
        switch self {
        case .images(let job):
            job.requiredTools
        case .video(let job):
            job.requiredTools
        case .audio(let job):
            job.requiredTools
        }
    }
}

final class ToolResolver {
    private var cachedPaths: [String: String] = [:]

    func missingTools(for job: ProcessingJob) -> [String] {
        job.requiredTools.filter { path(for: $0) == nil }
    }

    func path(for name: String) -> String? {
        if let cached = cachedPaths[name] {
            return cached
        }
        guard let resolved = findTool(named: name) else {
            return nil
        }
        cachedPaths[name] = resolved
        return resolved
    }

    private func findTool(named name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

actor ProcessRunner {
    private var cancelled = false
    private var currentProcess: Process?

    func prepareBatch() {
        cancelled = false
    }

    func cancel() {
        cancelled = true
        currentProcess?.terminate()
    }

    func isCancelled() -> Bool {
        cancelled
    }

    func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        currentProcess = process
        do {
            try process.run()
        } catch {
            currentProcess = nil
            throw error
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        currentProcess = nil
        guard !cancelled, process.terminationStatus == 0 else {
            if cancelled {
                throw CancellationError()
            }
            let tail = errData.count > 64_000 ? errData.suffix(64_000) : errData
            let errString = String(data: tail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = errString.isEmpty ? "exit \(process.terminationStatus)" : String(errString.suffix(500))
            throw OptaError.toolFailed(executable, message)
        }
    }
}

@MainActor
final class ProcessingEngine: ObservableObject {
    @Published var isProcessing = false

    private let tools = ToolResolver()
    private let runner = ProcessRunner()

    func checkTools(for job: ProcessingJob) -> String? {
        let missing = tools.missingTools(for: job)
        guard !missing.isEmpty else {
            return nil
        }

        switch job {
        case .images:
            let brewPackages = missing.map { $0 == "cwebp" ? "webp" : $0 }
            return "Missing tools: \(missing.joined(separator: ", "))\n\nInstall with:\nbrew install \(brewPackages.joined(separator: " "))"
        case .video, .audio:
            return "Missing tools: ffmpeg\n\nInstall with:\nbrew install ffmpeg"
        }
    }

    func cancel() {
        Task {
            await runner.cancel()
        }
    }

    func start(job: ProcessingJob, files: [FileItem]) {
        guard !files.isEmpty else {
            return
        }

        isProcessing = true
        for file in files {
            file.status = .waiting
        }

        Task { [weak self] in
            await self?.runBatch(job: job, files: files)
        }
    }

    func probeAudioTracks(file: FileItem) {
        Task.detached { [tools] in
            guard let ffprobe = tools.path(for: "ffprobe") else {
                return
            }
            let tracks = Self.parseAudioTracks(ffprobe: ffprobe, url: file.url)
            await MainActor.run {
                file.audioTracks = tracks
            }
        }
    }

    private func runBatch(job: ProcessingJob, files: [FileItem]) async {
        await runner.prepareBatch()
        let startTime = Date()

        for file in files {
            if await runner.isCancelled() {
                break
            }

            file.status = .working

            do {
                let outputURL = try await process(job: job, file: file)
                let beforeKB = file.originalSize / 1024
                let afterSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path(percentEncoded: false))[.size] as? Int64) ?? 0
                let afterKB = afterSize / 1024
                file.status = .done(beforeKB: beforeKB, afterKB: afterKB)
            } catch is CancellationError {
                file.status = nil
            } catch {
                file.status = .error(error.localizedDescription)
            }
        }

        let wasCancelled = await runner.isCancelled()
        isProcessing = false

        if wasCancelled {
            for file in files {
                if case .waiting = file.status {
                    file.status = nil
                }
            }
        } else if Date().timeIntervalSince(startTime) > 10 {
            sendCompletionNotification(fileCount: files.count)
        }
    }

    private func process(job: ProcessingJob, file: FileItem) async throws -> URL {
        switch job {
        case .images(let imageJob):
            return try await processImage(url: file.url, job: imageJob)
        case .video(let videoJob):
            return try await processVideo(url: file.url, job: videoJob)
        case .audio(let audioJob):
            let trackIndex = file.audioTracks.count > 1 ? file.selectedAudioTrack : nil
            return try await processAudio(url: file.url, job: audioJob, audioStreamIndex: trackIndex)
        }
    }

    private func sendCompletionNotification(fileCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Opta"
        content.body = fileCount == 1 ? "1 file optimized." : "\(fileCount) files optimized."
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func processImage(url: URL, job: ImageJob) async throws -> URL {
        let finalOutput = Self.outputURL(for: url, suffix: job.suffix, ext: job.format.ext)
        let output = Self.temporaryOutputURL(nextTo: finalOutput)
        defer { try? FileManager.default.removeItem(at: output) }

        let colors = colorSteps.indices.contains(job.colorIndex) ? colorSteps[job.colorIndex] : 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var current = url.path(percentEncoded: false)
        let isPNG = url.pathExtension.lowercased() == "png"
        let sipsOutput = isPNG ? nil : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        if let sipsOutput {
            try await runner.run(executable: "/usr/bin/sips", arguments: ["-s", "format", "png", current, "--out", sipsOutput.path(percentEncoded: false)])
            current = sipsOutput.path(percentEncoded: false)
        }
        defer { if let sipsOutput { try? FileManager.default.removeItem(at: sipsOutput) } }

        if colors > 0 {
            try await runner.run(
                executable: try requireTool("pngquant"),
                arguments: pngquantArguments(colors: colors, stripMetadata: job.stripMetadata, output: tmp.path(percentEncoded: false), input: current)
            )
            current = tmp.path(percentEncoded: false)
        }

        switch job.format {
        case .png:
            try await runner.run(
                executable: try requireTool("oxipng"),
                arguments: oxipngArguments(stripMetadata: job.stripMetadata, level: job.oxipngLevel, output: output.path(percentEncoded: false), input: current)
            )
        case .jpg:
            try writeJPEG(from: current, to: output.path(percentEncoded: false), quality: job.quality, stripMetadata: job.stripMetadata)
        case .webp:
            try await runner.run(
                executable: try requireTool("cwebp"),
                arguments: cwebpArguments(stripMetadata: job.stripMetadata, quality: job.quality, output: output.path(percentEncoded: false), input: current)
            )
        }

        try Self.persistOutput(from: output, to: finalOutput)
        return finalOutput
    }

    private func processVideo(url: URL, job: VideoJob) async throws -> URL {
        let finalOutput = Self.outputURL(for: url, suffix: job.suffix, ext: job.format.ext)
        let output = Self.temporaryOutputURL(nextTo: finalOutput)
        defer { try? FileManager.default.removeItem(at: output) }

        let ffmpeg = try requireTool("ffmpeg")
        let input = url.path(percentEncoded: false)
        let filters = videoFilters(for: job.dimension)

        switch job.format {
        case .mp4H264, .mov:
            try await runner.run(executable: ffmpeg, arguments: h264Arguments(input: input, filters: filters, stripMetadata: job.stripMetadata, crf: job.crf, output: output.path(percentEncoded: false)))
        case .mp4H265:
            try await runner.run(executable: ffmpeg, arguments: h265Arguments(input: input, filters: filters, stripMetadata: job.stripMetadata, crf: job.crf, output: output.path(percentEncoded: false)))
        case .webmVP9:
            let passDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("opta-vp9-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: passDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: passDirectory) }
            let passLog = passDirectory.appendingPathComponent("pass").path(percentEncoded: false)
            try await runner.run(executable: ffmpeg, arguments: vp9Pass1Arguments(input: input, filters: filters, crf: job.crf, passLog: passLog))
            try await runner.run(executable: ffmpeg, arguments: vp9Pass2Arguments(input: input, filters: filters, stripMetadata: job.stripMetadata, crf: job.crf, passLog: passLog, output: output.path(percentEncoded: false)))
        case .gif:
            try await runner.run(executable: ffmpeg, arguments: gifArguments(input: input, filters: filters, stripMetadata: job.stripMetadata, output: output.path(percentEncoded: false)))
        }

        try Self.persistOutput(from: output, to: finalOutput)
        return finalOutput
    }

    private func processAudio(url: URL, job: AudioJob, audioStreamIndex: Int?) async throws -> URL {
        let finalOutput = Self.outputURL(for: url, suffix: job.suffix, ext: job.format.ext)
        let output = Self.temporaryOutputURL(nextTo: finalOutput)
        defer { try? FileManager.default.removeItem(at: output) }

        let ffmpeg = try requireTool("ffmpeg")
        try await runner.run(
            executable: ffmpeg,
            arguments: audioArguments(
                input: url.path(percentEncoded: false),
                format: job.format,
                stripMetadata: job.stripMetadata,
                bitrate: job.bitrate,
                audioStreamIndex: audioStreamIndex,
                output: output.path(percentEncoded: false)
            )
        )

        try Self.persistOutput(from: output, to: finalOutput)
        return finalOutput
    }

    private func requireTool(_ name: String) throws -> String {
        guard let path = tools.path(for: name) else {
            throw OptaError.toolNotFound(name)
        }
        return path
    }

    private func writeJPEG(from inputPath: String, to outputPath: String, quality: Int, stripMetadata: Bool) throws {
        let srcURL = URL(fileURLWithPath: inputPath) as CFURL
        guard let source = CGImageSourceCreateWithURL(srcURL, nil) else {
            throw OptaError.toolFailed("image", "Failed to read image")
        }
        let destURL = URL(fileURLWithPath: outputPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(destURL, "public.jpeg" as CFString, 1, nil) else {
            throw OptaError.toolFailed("image", "Failed to create JPEG writer")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0]
        if stripMetadata {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OptaError.toolFailed("image", "Failed to decode image")
            }
            CGImageDestinationAddImage(dest, image, options as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw OptaError.toolFailed("image", "Failed to write JPEG")
        }
    }

    nonisolated private static func parseAudioTracks(ffprobe: String, url: URL) -> [AudioTrack] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-select_streams", "a",
            url.path(percentEncoded: false),
        ]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return []
        }

        return streams.enumerated().map { index, stream in
            var parts: [String] = []
            if let codec = stream["codec_name"] as? String {
                parts.append(codec.uppercased())
            }
            if let tags = stream["tags"] as? [String: String], let language = tags["language"] {
                parts.append(language)
            }
            if let channels = stream["channels"] as? Int {
                switch channels {
                case 1:
                    parts.append("mono")
                case 2:
                    parts.append("stereo")
                case 6:
                    parts.append("5.1")
                case 8:
                    parts.append("7.1")
                default:
                    parts.append("\(channels)ch")
                }
            }
            let suffix = parts.isEmpty ? "" : " — \(parts.joined(separator: ", "))"
            return AudioTrack(id: index, label: "Track \(index + 1)\(suffix)")
        }
    }

    private static func outputURL(for url: URL, suffix: String, ext: String) -> URL {
        url.deletingPathExtension().deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix)
            .appendingPathExtension(ext)
    }

    private static func temporaryOutputURL(nextTo destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".opta-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
    }

    private static func persistOutput(from temporaryURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fm.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func pngquantArguments(colors: Int, stripMetadata: Bool, output: String, input: String) -> [String] {
        var arguments = ["\(colors)", "--force"]
        if stripMetadata {
            arguments.append("--strip")
        }
        arguments += ["--output", output, input]
        return arguments
    }

    private func oxipngArguments(stripMetadata: Bool, level: Int, output: String, input: String) -> [String] {
        var arguments: [String] = []
        if stripMetadata {
            arguments += ["--strip", "all"]
        }
        arguments += ["-o", "\(level)", "--out", output, input]
        return arguments
    }

    private func cwebpArguments(stripMetadata: Bool, quality: Int, output: String, input: String) -> [String] {
        var arguments: [String] = []
        if stripMetadata {
            arguments += ["-metadata", "none"]
        }
        arguments += ["-q", "\(quality)", "-o", output, input]
        return arguments
    }

    private func videoFilters(for dimension: DimensionPreset) -> [String] {
        guard dimension != .original else {
            return []
        }
        return ["scale=-2:\(dimension.rawValue)"]
    }

    private func h264Arguments(input: String, filters: [String], stripMetadata: Bool, crf: Int, output: String) -> [String] {
        var arguments = ["-nostdin", "-i", input, "-c:v", "libx264", "-preset", "veryslow", "-tune", "film", "-crf", "\(crf)", "-refs", "4"]
        if !filters.isEmpty {
            arguments += ["-vf", filters.joined(separator: ",")]
        }
        arguments += ["-c:a", "aac", "-b:a", "256k"]
        if stripMetadata {
            arguments += ["-map_metadata", "-1"]
        }
        arguments += ["-movflags", "+faststart", "-y", output]
        return arguments
    }

    private func h265Arguments(input: String, filters: [String], stripMetadata: Bool, crf: Int, output: String) -> [String] {
        var arguments = ["-nostdin", "-i", input, "-c:v", "libx265", "-preset", "veryslow", "-crf", "\(crf)"]
        if !filters.isEmpty {
            arguments += ["-vf", filters.joined(separator: ",")]
        }
        arguments += ["-c:a", "aac", "-b:a", "256k"]
        if stripMetadata {
            arguments += ["-map_metadata", "-1"]
        }
        arguments += ["-movflags", "+faststart", "-tag:v", "hvc1", "-y", output]
        return arguments
    }

    private func vp9Pass1Arguments(input: String, filters: [String], crf: Int, passLog: String) -> [String] {
        var arguments = ["-nostdin", "-i", input, "-c:v", "libvpx-vp9", "-crf", "\(crf)", "-b:v", "0", "-cpu-used", "0", "-row-mt", "1"]
        if !filters.isEmpty {
            arguments += ["-vf", filters.joined(separator: ",")]
        }
        arguments += ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "/dev/null"]
        return arguments
    }

    private func vp9Pass2Arguments(input: String, filters: [String], stripMetadata: Bool, crf: Int, passLog: String, output: String) -> [String] {
        var arguments = ["-nostdin", "-i", input, "-c:v", "libvpx-vp9", "-crf", "\(crf)", "-b:v", "0", "-cpu-used", "0", "-row-mt", "1"]
        if !filters.isEmpty {
            arguments += ["-vf", filters.joined(separator: ",")]
        }
        arguments += ["-pass", "2", "-passlogfile", passLog, "-c:a", "libopus", "-b:a", "192k"]
        if stripMetadata {
            arguments += ["-map_metadata", "-1"]
        }
        arguments += ["-y", output]
        return arguments
    }

    private func gifArguments(input: String, filters: [String], stripMetadata: Bool, output: String) -> [String] {
        let filterPrefix = filters.isEmpty ? "" : filters.joined(separator: ",") + ","
        let paletteFilter = "\(filterPrefix)split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=floyd_steinberg"
        var arguments = ["-nostdin", "-i", input, "-lavfi", paletteFilter]
        if stripMetadata {
            arguments += ["-map_metadata", "-1"]
        }
        arguments += ["-y", output]
        return arguments
    }

    private func audioArguments(input: String, format: AudioOutputFormat, stripMetadata: Bool, bitrate: Int, audioStreamIndex: Int?, output: String) -> [String] {
        var arguments = ["-nostdin", "-i", input]
        if let audioStreamIndex {
            arguments += ["-map", "0:a:\(audioStreamIndex)"]
        }

        switch format {
        case .mp3:
            arguments += ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .aac, .m4a:
            arguments += ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .oggVorbis:
            arguments += ["-c:a", "libvorbis", "-b:a", "\(bitrate)k"]
        case .opus:
            arguments += ["-c:a", "libopus", "-b:a", "\(bitrate)k", "-vbr", "on", "-compression_level", "10"]
        case .flac:
            arguments += ["-c:a", "flac", "-compression_level", "12"]
        case .wav:
            arguments += ["-c:a", "pcm_s24le"]
        }

        if stripMetadata {
            arguments += ["-map_metadata", "-1"]
        }
        arguments += ["-vn", "-y", output]
        return arguments
    }
}
