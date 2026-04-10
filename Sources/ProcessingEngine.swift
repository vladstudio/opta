import Foundation
import ImageIO
import UserNotifications

enum OptaError: LocalizedError {
    case toolNotFound(String)
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let t): return "\(t) not found"
        case .toolFailed(let t, let m): return "\(t): \(m)"
        }
    }
}

class ProcessingEngine: ObservableObject {
    @Published var isProcessing = false
    private var _cancelled = false
    private var _currentProcess: Process?
    private let lock = NSLock()
    private var toolPaths: [String: String] = [:]

    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); defer { lock.unlock() }; _cancelled = newValue }
    }

    // MARK: - Tool Discovery

    func checkTools(for tab: MediaTab) -> String? {
        let required: [String]
        switch tab {
        case .images: required = ["pngquant", "oxipng", "cwebp"]
        case .video, .audio: required = ["ffmpeg"]
        }

        var missing: [String] = []
        for name in required {
            if let path = findTool(name) {
                lock.lock(); toolPaths[name] = path; lock.unlock()
            } else {
                missing.append(name)
            }
        }
        if missing.isEmpty { return nil }

        switch tab {
        case .images:
            let brew = missing.map { $0 == "cwebp" ? "webp" : $0 }
            return "Missing tools: \(missing.joined(separator: ", "))\n\nInstall with:\nbrew install \(brew.joined(separator: " "))"
        case .video, .audio:
            return "Missing tools: ffmpeg\n\nInstall with:\nbrew install ffmpeg"
        }
    }

    private func findTool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let p = _currentProcess
        lock.unlock()
        p?.terminate()
    }

    // MARK: - Image Processing

    func startImages(files: [FileItem], format: ImageOutputFormat, suffix: String,
                     stripMetadata: Bool, colorIndex: Int, quality: Int, oxipngLevel: Int) {
        runBatch(files: files) { [self] paths, file in
            try self.processImage(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata,
                colorIndex: colorIndex, quality: quality, oxipngLevel: oxipngLevel
            )
        }
    }

    // MARK: - Video Processing

    func startVideo(files: [FileItem], format: VideoOutputFormat, suffix: String,
                    stripMetadata: Bool, dimension: DimensionPreset, crf: Int) {
        runBatch(files: files) { [self] paths, file in
            try self.processVideo(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata,
                dimension: dimension, crf: crf
            )
        }
    }

    // MARK: - Audio Processing

    func startAudio(files: [FileItem], format: AudioOutputFormat, suffix: String,
                    stripMetadata: Bool, bitrate: Int) {
        runBatch(files: files) { [self] paths, file in
            let trackIndex = file.audioTracks.count > 1 ? file.selectedAudioTrack : nil
            return try self.processAudio(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata, bitrate: bitrate,
                audioStreamIndex: trackIndex
            )
        }
    }

    // MARK: - Audio Track Probing

    func probeAudioTracks(file: FileItem) {
        let paths = toolPaths
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ffprobe = paths["ffprobe"] ?? self.findToolSync("ffprobe") else { return }
            let tracks = Self.parseAudioTracks(ffprobe: ffprobe, url: file.url)
            DispatchQueue.main.async {
                file.audioTracks = tracks
            }
        }
    }

    func findToolSync(_ name: String) -> String? {
        lock.lock()
        if let cached = toolPaths[name] { lock.unlock(); return cached }
        lock.unlock()
        if let path = findTool(name) {
            lock.lock(); toolPaths[name] = path; lock.unlock()
            return path
        }
        return nil
    }

    private static func parseAudioTracks(ffprobe: String, url: URL) -> [AudioTrack] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", "-select_streams", "a",
                       url.path(percentEncoded: false)]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else { return [] }

        return streams.enumerated().map { index, stream in
            var parts: [String] = []
            if let codec = stream["codec_name"] as? String { parts.append(codec.uppercased()) }
            if let tags = stream["tags"] as? [String: String], let lang = tags["language"] { parts.append(lang) }
            if let channels = stream["channels"] as? Int {
                switch channels {
                case 1: parts.append("mono")
                case 2: parts.append("stereo")
                case 6: parts.append("5.1")
                case 8: parts.append("7.1")
                default: parts.append("\(channels)ch")
                }
            }
            let label = "Track \(index + 1)" + (parts.isEmpty ? "" : " — \(parts.joined(separator: ", "))")
            return AudioTrack(id: index, label: label)
        }
    }

    // MARK: - Batch Runner

    private func runBatch(files: [FileItem], process: @escaping ([String: String], FileItem) throws -> String) {
        isProcessing = true
        cancelled = false
        for file in files { file.status = .waiting }

        lock.lock(); let paths = toolPaths; lock.unlock()
        let startTime = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for file in files {
                guard let self, !self.cancelled else { break }

                DispatchQueue.main.async { file.status = .working }

                do {
                    let outputPath = try process(paths, file)
                    let beforeKB = file.originalSize / 1024
                    let afterSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
                    let afterKB = afterSize / 1024
                    DispatchQueue.main.async { file.status = .done(beforeKB: beforeKB, afterKB: afterKB) }
                } catch {
                    if self.cancelled {
                        DispatchQueue.main.async { file.status = nil }
                    } else {
                        let msg = error.localizedDescription
                        DispatchQueue.main.async { file.status = .error(msg) }
                    }
                }
            }

            let wasCancelled = self?.cancelled == true
            let elapsed = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self?.isProcessing = false
                if wasCancelled {
                    for file in files {
                        if case .waiting = file.status { file.status = nil }
                    }
                } else if elapsed > 10 {
                    self?.sendCompletionNotification(fileCount: files.count)
                }
            }
        }
    }

    // MARK: - Notification

    private func sendCompletionNotification(fileCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Opta"
        content.body = fileCount == 1
            ? "1 file optimized."
            : "\(fileCount) files optimized."
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Image Pipeline

    private func processImage(
        paths: [String: String], url: URL, format: ImageOutputFormat,
        suffix: String, stripMetadata: Bool, colorIndex: Int, quality: Int,
        oxipngLevel: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let finalOutput = Self.outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
        defer { try? FileManager.default.removeItem(atPath: output) }
        let colors = colorSteps.indices.contains(colorIndex) ? colorSteps[colorIndex] : 0

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var current = input

        // Step 0: Convert non-PNG to PNG via sips
        let isPNG = url.pathExtension.lowercased() == "png"
        let sipsTmp = isPNG ? nil : FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png").path
        if let sipsTmp {
            try runDirect("/usr/bin/sips", ["-s", "format", "png", current, "--out", sipsTmp])
            current = sipsTmp
        }
        defer { if let sipsTmp { try? FileManager.default.removeItem(atPath: sipsTmp) } }

        // Step 1: Quantize colors if needed
        if colors > 0 {
            var args = ["\(colors)", "--force"]
            if stripMetadata { args.append("--strip") }
            args += ["--output", tmp, current]
            try run(paths, "pngquant", args)
            current = tmp
        }

        // Step 2: Output in target format
        switch format {
        case .png:
            var args: [String] = []
            if stripMetadata { args += ["--strip", "all"] }
            args += ["-o", "\(oxipngLevel)", "--out", output, current]
            try run(paths, "oxipng", args)
        case .jpg:
            try writeJPEG(from: current, to: output, quality: quality, stripMetadata: stripMetadata)
        case .webp:
            var args: [String] = []
            if stripMetadata { args += ["-metadata", "none"] }
            args += ["-q", "\(quality)", "-o", output, current]
            try run(paths, "cwebp", args)
        }

        try? FileManager.default.removeItem(atPath: finalOutput)
        try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        return finalOutput
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
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0]
        if stripMetadata {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OptaError.toolFailed("image", "Failed to decode image")
            }
            CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, source, 0, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw OptaError.toolFailed("image", "Failed to write JPEG")
        }
    }

    // MARK: - Video Pipeline

    private func processVideo(
        paths: [String: String], url: URL, format: VideoOutputFormat,
        suffix: String, stripMetadata: Bool, dimension: DimensionPreset, crf: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let finalOutput = Self.outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
        defer { try? FileManager.default.removeItem(atPath: output) }
        guard let ffmpeg = paths["ffmpeg"] else { throw OptaError.toolNotFound("ffmpeg") }

        var filters: [String] = []
        if dimension != .original {
            filters.append("scale=-2:\(dimension.rawValue)")
        }

        switch format {
        case .mp4H264, .mov:
            var args = ["-i", input, "-c:v", "libx264", "-preset", "veryslow", "-tune", "film", "-crf", "\(crf)", "-refs", "4"]
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            args += ["-c:a", "aac", "-b:a", "256k"]
            if stripMetadata { args += ["-map_metadata", "-1"] }
            args += ["-movflags", "+faststart"]
            args += ["-y", output]
            try runDirect(ffmpeg, args)

        case .mp4H265:
            var args = ["-i", input, "-c:v", "libx265", "-preset", "veryslow", "-crf", "\(crf)"]
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            args += ["-c:a", "aac", "-b:a", "256k"]
            if stripMetadata { args += ["-map_metadata", "-1"] }
            args += ["-movflags", "+faststart", "-tag:v", "hvc1"]
            args += ["-y", output]
            try runDirect(ffmpeg, args)

        case .webmVP9:
            let passDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("opta-vp9-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: passDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: passDir) }
            let passLogFile = passDir.appendingPathComponent("pass").path
            var base = ["-i", input, "-c:v", "libvpx-vp9", "-crf", "\(crf)", "-b:v", "0",
                        "-cpu-used", "0", "-row-mt", "1"]
            if !filters.isEmpty { base += ["-vf", filters.joined(separator: ",")] }
            try runDirect(ffmpeg, base + ["-pass", "1", "-passlogfile", passLogFile, "-an", "-f", "null", "/dev/null"])
            var pass2 = base + ["-pass", "2", "-passlogfile", passLogFile, "-c:a", "libopus", "-b:a", "192k"]
            if stripMetadata { pass2 += ["-map_metadata", "-1"] }
            try runDirect(ffmpeg, pass2 + ["-y", output])

        case .gif:
            // Two-pass palette generation for best quality
            let filterStr = filters.isEmpty ? "" : filters.joined(separator: ",") + ","
            let paletteFilter = "\(filterStr)split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=floyd_steinberg"
            var args = ["-i", input, "-lavfi", paletteFilter]
            if stripMetadata { args += ["-map_metadata", "-1"] }
            args += ["-y", output]
            try runDirect(ffmpeg, args)
        }

        try? FileManager.default.removeItem(atPath: finalOutput)
        try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        return finalOutput
    }

    // MARK: - Audio Pipeline

    private func processAudio(
        paths: [String: String], url: URL, format: AudioOutputFormat,
        suffix: String, stripMetadata: Bool, bitrate: Int,
        audioStreamIndex: Int? = nil
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let finalOutput = Self.outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
        defer { try? FileManager.default.removeItem(atPath: output) }
        guard let ffmpeg = paths["ffmpeg"] else { throw OptaError.toolNotFound("ffmpeg") }

        var args = ["-i", input]
        if let idx = audioStreamIndex {
            args += ["-map", "0:a:\(idx)"]
        }

        switch format {
        case .mp3:
            args += ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .aac, .m4a:
            args += ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .oggVorbis:
            args += ["-c:a", "libvorbis", "-b:a", "\(bitrate)k"]
        case .opus:
            args += ["-c:a", "libopus", "-b:a", "\(bitrate)k", "-vbr", "on", "-compression_level", "10"]
        case .flac:
            args += ["-c:a", "flac", "-compression_level", "12"]
        case .wav:
            args += ["-c:a", "pcm_s24le"]
        }

        if stripMetadata { args += ["-map_metadata", "-1"] }
        args += ["-vn", "-y", output]

        try runDirect(ffmpeg, args)

        try? FileManager.default.removeItem(atPath: finalOutput)
        try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        return finalOutput
    }

    // MARK: - Output Path

    private static func outputPath(for url: URL, suffix: String, ext: String) -> String {
        let dir = url.deletingLastPathComponent().path(percentEncoded: false)
        let base = url.deletingPathExtension().lastPathComponent
        return "\(dir)/\(base)\(suffix).\(ext)"
    }

    // MARK: - Shell Execution

    private func runDirect(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        lock.lock(); _currentProcess = p; lock.unlock()
        do { try p.run() } catch {
            lock.lock(); _currentProcess = nil; lock.unlock()
            throw error
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); _currentProcess = nil; let wasCancelled = _cancelled; lock.unlock()
        guard !wasCancelled && p.terminationStatus == 0 else {
            if wasCancelled { throw CancellationError() }
            let tail = errData.count > 64_000 ? errData.suffix(64_000) : errData
            let errString = String(data: tail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = errString.isEmpty ? "exit \(p.terminationStatus)"
                : String(errString.suffix(500))
            throw OptaError.toolFailed(exe, msg)
        }
    }

    private func run(_ paths: [String: String], _ tool: String, _ args: [String]) throws {
        guard let exe = paths[tool] else { throw OptaError.toolNotFound(tool) }
        try runDirect(exe, args)
    }
}
