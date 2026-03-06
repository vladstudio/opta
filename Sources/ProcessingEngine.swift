import Foundation

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
    private let cancelLock = NSLock()
    private var toolPaths: [String: String] = [:]

    private var cancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled }
        set { cancelLock.lock(); defer { cancelLock.unlock() }; _cancelled = newValue }
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
                toolPaths[name] = path
            } else {
                missing.append(name)
            }
        }
        guard !missing.isEmpty else { return nil }

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

    func cancel() { cancelled = true }

    // MARK: - Image Processing

    func startImages(files: [FileItem], format: ImageOutputFormat, suffix: String,
                     stripMetadata: Bool, colorIndex: Int, quality: Int, oxipngLevel: Int) {
        runBatch(files: files) { paths, file in
            try Self.processImage(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata,
                colorIndex: colorIndex, quality: quality, oxipngLevel: oxipngLevel
            )
        }
    }

    // MARK: - Video Processing

    func startVideo(files: [FileItem], format: VideoOutputFormat, suffix: String,
                    stripMetadata: Bool, dimension: DimensionPreset, crf: Int) {
        runBatch(files: files) { paths, file in
            try Self.processVideo(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata,
                dimension: dimension, crf: crf
            )
        }
    }

    // MARK: - Audio Processing

    func startAudio(files: [FileItem], format: AudioOutputFormat, suffix: String,
                    stripMetadata: Bool, bitrate: Int) {
        runBatch(files: files) { paths, file in
            try Self.processAudio(
                paths: paths, url: file.url, format: format,
                suffix: suffix, stripMetadata: stripMetadata, bitrate: bitrate
            )
        }
    }

    // MARK: - Batch Runner

    private func runBatch(files: [FileItem], process: @escaping ([String: String], FileItem) throws -> String) {
        isProcessing = true
        cancelled = false
        for file in files { file.status = .waiting }

        let paths = toolPaths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for file in files {
                if self?.cancelled == true { break }

                DispatchQueue.main.async { file.status = .working }

                do {
                    let outputPath = try process(paths, file)
                    let beforeKB = file.originalSize / 1024
                    let afterSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
                    let afterKB = afterSize / 1024
                    DispatchQueue.main.async { file.status = .done(beforeKB: beforeKB, afterKB: afterKB) }
                } catch {
                    let msg = error.localizedDescription
                    DispatchQueue.main.async { file.status = .error(msg) }
                }
            }

            let wasCancelled = self?.cancelled == true
            DispatchQueue.main.async {
                self?.isProcessing = false
                if wasCancelled {
                    for file in files {
                        if case .waiting = file.status { file.status = nil }
                    }
                }
            }
        }
    }

    // MARK: - Image Pipeline

    private static func processImage(
        paths: [String: String], url: URL, format: ImageOutputFormat,
        suffix: String, stripMetadata: Bool, colorIndex: Int, quality: Int,
        oxipngLevel: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let (finalOutput, sameFile) = outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = sameFile
            ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
            : finalOutput
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
            var args = ["-s", "format", "jpeg", "-s", "formatOptions", "\(quality)"]
            args += [current, "--out", output]
            try runDirect("/usr/bin/sips", args)
        case .webp:
            var args: [String] = []
            if stripMetadata { args += ["-metadata", "none"] }
            args += ["-q", "\(quality)", "-o", output, current]
            try run(paths, "cwebp", args)
        }

        if sameFile {
            try? FileManager.default.removeItem(atPath: finalOutput)
            try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        }
        return finalOutput
    }

    // MARK: - Video Pipeline

    private static func processVideo(
        paths: [String: String], url: URL, format: VideoOutputFormat,
        suffix: String, stripMetadata: Bool, dimension: DimensionPreset, crf: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let (finalOutput, sameFile) = outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = sameFile
            ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
            : finalOutput
        guard let ffmpeg = paths["ffmpeg"] else { throw OptaError.toolNotFound("ffmpeg") }

        var filters: [String] = []
        if dimension != .original {
            filters.append("scale=-2:\(dimension.rawValue)")
        }

        switch format {
        case .mp4H264, .mov:
            var args = ["-i", input, "-c:v", "libx264", "-preset", "veryslow", "-tune", "film", "-crf", "\(crf)"]
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
            // Two-pass for best quality
            let passLogFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).path

            // Pass 1
            var pass1 = ["-i", input, "-c:v", "libvpx-vp9", "-crf", "\(crf)", "-b:v", "0",
                         "-cpu-used", "0", "-row-mt", "1"]
            if !filters.isEmpty { pass1 += ["-vf", filters.joined(separator: ",")] }
            pass1 += ["-pass", "1", "-passlogfile", passLogFile, "-an", "-f", "null", "/dev/null"]
            try runDirect(ffmpeg, pass1)

            // Pass 2
            var pass2 = ["-i", input, "-c:v", "libvpx-vp9", "-crf", "\(crf)", "-b:v", "0",
                         "-cpu-used", "0", "-row-mt", "1"]
            if !filters.isEmpty { pass2 += ["-vf", filters.joined(separator: ",")] }
            pass2 += ["-pass", "2", "-passlogfile", passLogFile,
                      "-c:a", "libopus", "-b:a", "192k"]
            if stripMetadata { pass2 += ["-map_metadata", "-1"] }
            pass2 += ["-y", output]
            try runDirect(ffmpeg, pass2)

            // Clean up pass log
            try? FileManager.default.removeItem(atPath: passLogFile + "-0.log")

        case .gif:
            // Two-pass palette generation for best quality
            let filterStr = filters.isEmpty ? "" : filters.joined(separator: ",") + ","
            let paletteFilter = "\(filterStr)split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=floyd_steinberg"
            var args = ["-i", input, "-lavfi", paletteFilter]
            if stripMetadata { args += ["-map_metadata", "-1"] }
            args += ["-y", output]
            try runDirect(ffmpeg, args)
        }

        if sameFile {
            try? FileManager.default.removeItem(atPath: finalOutput)
            try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        }
        return finalOutput
    }

    // MARK: - Audio Pipeline

    private static func processAudio(
        paths: [String: String], url: URL, format: AudioOutputFormat,
        suffix: String, stripMetadata: Bool, bitrate: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let (finalOutput, sameFile) = outputPath(for: url, suffix: suffix, ext: format.ext)
        let output = sameFile
            ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(format.ext)").path
            : finalOutput
        guard let ffmpeg = paths["ffmpeg"] else { throw OptaError.toolNotFound("ffmpeg") }

        var args = ["-i", input]

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

        if sameFile {
            try? FileManager.default.removeItem(atPath: finalOutput)
            try FileManager.default.moveItem(atPath: output, toPath: finalOutput)
        }
        return finalOutput
    }

    // MARK: - Output Path

    private static func outputPath(for url: URL, suffix: String, ext: String) -> (path: String, isSameAsInput: Bool) {
        let dir = url.deletingLastPathComponent().path(percentEncoded: false)
        let base = url.deletingPathExtension().lastPathComponent
        let output = "\(dir)/\(base)\(suffix).\(ext)"
        let input = url.path(percentEncoded: false)
        return (output, output == input)
    }

    // MARK: - Shell Execution

    private static func runDirect(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let errString = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = errString.isEmpty ? "exit \(p.terminationStatus)"
                : String(errString.suffix(500))
            throw OptaError.toolFailed(exe, msg)
        }
    }

    private static func run(_ paths: [String: String], _ tool: String, _ args: [String]) throws {
        guard let exe = paths[tool] else { throw OptaError.toolNotFound(tool) }
        try runDirect(exe, args)
    }
}
