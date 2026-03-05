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
    private var toolPaths: [String: String] = [:]
    private var queue: [Job] = []
    private let queueLock = NSLock()
    private var loopRunning = false

    private struct Job {
        let file: FileItem
        let format: OutputFormat
        let suffix: String
        let stripMetadata: Bool
        let colorIndex: Int
        let quality: Int
        let oxipngLevel: Int
    }

    func checkTools() -> String? {
        let required = ["pngquant", "oxipng", "cwebp"]
        var missing: [String] = []
        for name in required {
            if let path = findTool(name) {
                toolPaths[name] = path
            } else {
                missing.append(name)
            }
        }
        guard !missing.isEmpty else { return nil }
        let brew = missing.map { $0 == "cwebp" ? "webp" : $0 }
        return "Missing tools: \(missing.joined(separator: ", "))\n\nInstall with:\nbrew install \(brew.joined(separator: " "))"
    }

    private func findTool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func enqueue(files: [FileItem], format: OutputFormat, suffix: String,
                 stripMetadata: Bool, colorIndex: Int, quality: Int, oxipngLevel: Int) {
        let pending = files.filter { $0.status == nil }
        guard !pending.isEmpty else { return }

        for file in pending { file.status = .waiting }

        let jobs = pending.map { Job(file: $0, format: format, suffix: suffix,
                                     stripMetadata: stripMetadata, colorIndex: colorIndex,
                                     quality: quality, oxipngLevel: oxipngLevel) }

        queueLock.lock()
        queue.append(contentsOf: jobs)
        let shouldStart = !loopRunning
        if shouldStart { loopRunning = true }
        queueLock.unlock()

        if shouldStart {
            let paths = toolPaths
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.processLoop(paths: paths)
            }
        }
    }

    private func processLoop(paths: [String: String]) {
        while true {
            queueLock.lock()
            let job = queue.isEmpty ? nil : queue.removeFirst()
            if job == nil { loopRunning = false }
            queueLock.unlock()

            guard let job else { break }

            DispatchQueue.main.async { job.file.status = .working }

            do {
                let outputPath = try Self.processFile(
                    paths: paths, url: job.file.url, format: job.format,
                    suffix: job.suffix, stripMetadata: job.stripMetadata,
                    colorIndex: job.colorIndex, quality: job.quality,
                    oxipngLevel: job.oxipngLevel
                )
                let beforeKB = job.file.originalSize / 1024
                let afterSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
                let afterKB = afterSize / 1024
                DispatchQueue.main.async { job.file.status = .done(beforeKB: beforeKB, afterKB: afterKB) }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { job.file.status = .error(msg) }
            }
        }
    }

    // MARK: - Processing

    private static func processFile(
        paths: [String: String], url: URL, format: OutputFormat,
        suffix: String, stripMetadata: Bool, colorIndex: Int, quality: Int,
        oxipngLevel: Int
    ) throws -> String {
        let input = url.path(percentEncoded: false)
        let dir = url.deletingLastPathComponent().path(percentEncoded: false)
        let base = url.deletingPathExtension().lastPathComponent
        let output = "\(dir)/\(base)\(suffix).\(format.ext)"
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
        return output
    }

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
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(p.terminationStatus)"
            throw OptaError.toolFailed(exe, msg)
        }
    }

    private static func run(_ paths: [String: String], _ tool: String, _ args: [String]) throws {
        guard let exe = paths[tool] else { throw OptaError.toolNotFound(tool) }
        try runDirect(exe, args)
    }
}
