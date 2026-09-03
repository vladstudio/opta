import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = ProcessingEngine()
    @StateObject private var recorder = ScreenRecorder()
    @StateObject private var screenshotter = ScreenshotCapturer()
    @StateObject private var previewer = QuickLookPreviewer()
    @StateObject private var model = WorkspaceModel()
    @EnvironmentObject private var appState: AppState

    @State private var pendingOverwrite: (job: ProcessingJob, safe: [FileItem], conflicting: [FileItem])?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            fileList
            Divider()
            if engine.isProcessing {
                HStack {
                    Spacer()
                    Button("Cancel") { engine.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                .padding()
            } else {
                controls
            }
        }
        .frame(minWidth: 528, maxWidth: 528, minHeight: 450)
        .onAppear {
            model.dependenciesModel.refresh()
            if !model.dependenciesModel.allInstalled {
                model.showDependenciesSheet = true
            }
        }
        .onChange(of: appState.pendingURLs) {
            guard !appState.pendingURLs.isEmpty else { return }
            model.ingestPendingURLs(appState.pendingURLs, probeAudioTracks: engine.probeAudioTracks)
            appState.pendingURLs.removeAll()
        }
        .onChange(of: appState.commandSerial) {
            guard let command = appState.consumeCommand() else { return }
            model.handleCommand(command, isProcessing: engine.isProcessing, preview: previewer.preview)
        }
        .onChange(of: model.settings.videoFormat) {
            model.settings.videoCRF = model.settings.videoFormat.crfDefault
            model.settings.videoAudioBitrate = model.settings.videoFormat.audioBitrateDefault
        }
        .onChange(of: model.settings.audioFormat) {
            model.settings.audioBitrate = model.settings.audioFormat.bitrateDefault
        }
        .alert("Error", isPresented: $model.showAlert) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage)
        }
        .sheet(isPresented: $model.showDependenciesSheet) {
            DependenciesView(model: model.dependenciesModel)
        }
        .alert("Replace original files?", isPresented: $model.showOverwriteAlert) {
            Button("Replace Originals", role: .destructive) {
                let p = pendingOverwrite
                pendingOverwrite = nil
                guard let p else { return }
                engine.start(job: p.job, files: p.safe + p.conflicting)
            }
            Button("Add Suffix") {
                let p = pendingOverwrite
                pendingOverwrite = nil
                guard let p else { return }
                for file in p.conflicting {
                    file.status = .error("skipped — add a suffix")
                }
                if !p.safe.isEmpty {
                    engine.start(job: p.job, files: p.safe)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingOverwrite = nil
            }
        } message: {
            Text(model.overwriteAlertMessage)
        }
    }

    private var tabBar: some View {
        Picker("", selection: $model.settings.selectedTab) {
            ForEach(MediaTab.allCases, id: \.self) { tab in
                Text(model.tabLabel(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .disabled(engine.isProcessing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.settings.selectedTab) {
            model.clearSelectionForTabChange()
        }
    }

    private var fileList: some View {
        List(selection: $model.selection) {
            ForEach(model.currentFiles) { file in
                FileRowView(file: file)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    })
                    .contextMenu {
                        Section("Original") {
                            Button("Optimize") {
                                optimize(files: [file])
                            }
                            .disabled(engine.isProcessing)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            .disabled(!FileManager.default.fileExists(atPath: file.url.path))
                            Button("Move to Trash") {
                                if model.selection.contains(file.id) {
                                    model.trashSelected()
                                } else {
                                    model.trashFile(file, from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                                }
                            }
                            .keyboardShortcut(.delete, modifiers: .command)
                            .disabled(engine.isProcessing || !FileManager.default.fileExists(atPath: file.url.path))
                            Button("Remove from List") {
                                if model.selection.contains(file.id) {
                                    model.removeSelected(from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                                } else {
                                    model.removeFile(file, from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                                }
                            }
                            .keyboardShortcut(.delete, modifiers: [])
                            .disabled(engine.isProcessing)
                        }
                        Section("Optimized") {
                            Button("Reveal in Finder") {
                                revealOptimized(for: file)
                            }
                            .keyboardShortcut("f", modifiers: [.command, .shift])
                            .disabled(!anyOptimizedExists(for: file))
                            Button("Copy to Clipboard") {
                                copyOptimizedToClipboard(for: file)
                            }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            .disabled(!anyOptimizedExists(for: file))
                            Button("Move to Trash") {
                                for f in optimizedTargets(for: file) where optimizedFileExists(f) {
                                    try? FileManager.default.trashItem(at: f.outputURL!, resultingItemURL: nil)
                                    f.outputURL = nil
                                }
                            }
                            .keyboardShortcut(.delete, modifiers: [.command, .shift])
                            .disabled(engine.isProcessing || !anyOptimizedExists(for: file))
                        }
                    }
            }
        }
        .onDeleteCommand {
            model.removeSelected(from: model.settings.selectedTab, isProcessing: engine.isProcessing)
        }
        .onKeyPress(.space) {
            previewer.preview(model.previewURLs())
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .overlay {
            if model.currentFiles.isEmpty && !engine.isProcessing {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.largeTitle)
                    Text(emptyStateHint)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
        }
    }

    private var emptyStateHint: String {
        switch model.settings.selectedTab {
        case .images:
            "Drop image files here"
        case .video:
            "Drop video files here"
        case .audio:
            "Drop audio/video files here"
        }
    }

    private var controls: some View {
        Group {
            switch model.settings.selectedTab {
            case .images:
                imageControls
            case .video:
                videoControls
            case .audio:
                audioControls
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("+") { addFiles() }
                Button("Screenshot...") { takeScreenshot() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(screenshotter.isCapturing || recorder.isActive)
                captureFolderButton(current: model.settings.screenshotFolder) {
                    model.settings.screenshotFolder = $0
                }
                Spacer()
                Picker("Format", selection: $model.settings.imageFormat) {
                    ForEach(ImageOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                TextField("suffix", text: $model.settings.imageSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                if model.queues.images.contains(where: { $0.isSVG }) {
                    Picker("Scale", selection: $model.settings.imageSVGScale) {
                        ForEach([1, 2, 3, 4], id: \.self) { Text("\($0)x") }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("SVG raster size multiplier")
                }
            }

            Toggle("Strip metadata", isOn: $model.settings.imageStripMetadata)

            VStack(alignment: .leading, spacing: 4) {
                Text("Colors: \(colorLabel(Int(model.settings.imageColorIndex)))")
                Slider(value: $model.settings.imageColorIndex, in: 0...Double(colorSteps.count - 1), step: 1)
            }

            if model.settings.imageFormat != .png {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(model.settings.imageQuality))")
                    Slider(value: $model.settings.imageQuality, in: 20...100, step: 2)
                }
            }

            optimizeButton(disabled: model.queues.images.isEmpty)
        }
        .padding()
    }

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("+") { addFiles() }
                Button(recorder.isRecording ? "Stop Recording" : "Record Screen...") { recordScreen() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(screenshotter.isCapturing)
                captureFolderButton(current: model.settings.recordingFolder) {
                    model.settings.recordingFolder = $0
                }
                Spacer()
                Picker("Format", selection: $model.settings.videoFormat) {
                    ForEach(VideoOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("suffix", text: $model.settings.videoSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Toggle("Strip metadata", isOn: $model.settings.videoStripMetadata)

            HStack {
                Text("Dimensions:")
                Picker("Dimensions", selection: $model.settings.videoDimension) {
                    ForEach(DimensionPreset.allCases, id: \.self) { Text($0.label) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if model.settings.videoFormat.hasCRF {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality (CRF): \(Int(model.settings.videoCRF))  —  \(crfHint(Int(model.settings.videoCRF)))")
                    Slider(value: $model.settings.videoCRF, in: model.settings.videoFormat.crfRange, step: 1)
                }
            }

            if model.settings.videoFormat.hasAudio {
                let steps = model.settings.videoFormat.audioBitrateSteps
                let index = steps.firstIndex(of: model.settings.videoAudioBitrate) ?? 2

                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Bitrate: \(steps[index]) kbps")
                    Slider(value: Binding(
                        get: { Double(index) },
                        set: { model.settings.videoAudioBitrate = steps[Int($0)] }
                    ), in: 0...Double(max(0, steps.count - 1)), step: 1)
                }
            }

            optimizeButton(disabled: model.queues.video.isEmpty)
        }
        .padding()
    }

    private func optimizedFileExists(_ file: FileItem) -> Bool {
        guard let out = file.outputURL else { return false }
        return FileManager.default.fileExists(atPath: out.path)
    }

    private func optimizedTargets(for file: FileItem) -> [FileItem] {
        if model.selection.contains(file.id) && !model.selection.isEmpty {
            return model.currentFiles.filter { model.selection.contains($0.id) }
        }
        return [file]
    }

    private func anyOptimizedExists(for file: FileItem) -> Bool {
        optimizedTargets(for: file).contains { optimizedFileExists($0) }
    }

    private func revealOptimized(for file: FileItem) {
        let urls = optimizedTargets(for: file).compactMap { $0.outputURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func copyOptimizedToClipboard(for file: FileItem) {
        let urls = optimizedTargets(for: file).compactMap { $0.outputURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSPasteboardWriting])
    }

    private func crfHint(_ crf: Int) -> String {
        switch model.settings.videoFormat {
        case .mp4H264, .mov:
            if crf <= 18 { return "visually lossless" }
            if crf <= 22 { return "high quality" }
            if crf <= 26 { return "good quality" }
            return "smaller file"
        case .mp4H265:
            if crf <= 22 { return "visually lossless" }
            if crf <= 26 { return "high quality" }
            if crf <= 30 { return "good quality" }
            return "smaller file"
        case .webmVP9:
            if crf <= 20 { return "visually lossless" }
            if crf <= 28 { return "high quality" }
            if crf <= 36 { return "good quality" }
            return "smaller file"
        case .gif:
            return ""
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("+") { addFiles() }
                Spacer()
                Picker("Format", selection: $model.settings.audioFormat) {
                    ForEach(AudioOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("suffix", text: $model.settings.audioSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Toggle("Strip metadata", isOn: $model.settings.audioStripMetadata)

            if !model.settings.audioFormat.isLossless {
                let steps = model.settings.audioFormat.bitrateSteps
                let index = steps.firstIndex(of: model.settings.audioBitrate) ?? 0

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bitrate: \(steps[index]) kbps")
                    Slider(value: Binding(
                        get: { Double(index) },
                        set: { model.settings.audioBitrate = steps[Int($0)] }
                    ), in: 0...Double(max(0, steps.count - 1)), step: 1)
                }
            }

            optimizeButton(disabled: model.queues.audio.isEmpty)
        }
        .padding()
    }

    private func optimizeButton(disabled: Bool) -> some View {
        HStack {
            Spacer()
            Button("Optimize") { optimize() }
                .disabled(disabled)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    private func captureDestinationURL(_ folder: String?) -> URL {
        if let path = folder, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func captureFolderButton(current: String?, onSelect: @escaping (String?) -> Void) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Save Here"
            panel.directoryURL = captureDestinationURL(current)
            if panel.runModal() == .OK, let url = panel.url {
                onSelect(url.path)
            }
        } label: {
            Image(systemName: "folder")
        }
        .help(current.map { "Capture to: \($0)" } ?? "Capture to: Desktop")
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true

        switch model.settings.selectedTab {
        case .images:
            panel.allowedContentTypes = acceptedImageTypes
        case .video:
            panel.allowedContentTypes = acceptedVideoTypes
        case .audio:
            panel.allowedContentTypes = acceptedAudioTypes + acceptedVideoTypes
        }

        guard panel.runModal() == .OK else { return }
        let destination = model.destinationForCurrentTab()
        model.addAndSelect(panel.urls, preferredTab: destination, probeAudioTracks: engine.probeAudioTracks)
    }

    private func recordScreen() {
        if recorder.isRecording {
            recorder.stop()
            return
        }

        recorder.start(
            folder: model.settings.recordingFolder,
            onFinish: { url in
                model.settings.selectedTab = .video
                model.addAndSelect([url], preferredTab: .auto, probeAudioTracks: engine.probeAudioTracks)
            },
            onError: { message in
                model.presentError(message)
            }
        )
    }

    private func takeScreenshot() {
        screenshotter.start(
            folder: model.settings.screenshotFolder,
            onFinish: { url in
                model.settings.selectedTab = .images
                model.addAndSelect([url], preferredTab: .auto, probeAudioTracks: engine.probeAudioTracks)
            },
            onError: { message in
                model.presentError(message)
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let urlLock = NSLock()
        let destination = model.destinationForCurrentTab()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urlLock.lock()
                urls.append(url)
                urlLock.unlock()
            }
        }

        group.notify(queue: .main) {
            model.handleDroppedURLs(urls, destination: destination, probeAudioTracks: engine.probeAudioTracks)
        }
        return true
    }

    private func optimize() {
        guard let request = model.optimizationRequest() else { return }
        optimize(files: request.files)
    }

    private func optimize(files: [FileItem]) {
        guard let request = model.optimizationRequest() else { return }
        if !engine.missingTools(for: request.job).isEmpty {
            model.showDependenciesSheet = true
            return
        }
        let (safe, conflicting) = splitConflicts(files: files, job: request.job)
        guard conflicting.isEmpty else {
            pendingOverwrite = (job: request.job, safe: safe, conflicting: conflicting)
            let n = conflicting.count
            let total = files.count
            let noun = n == 1 ? "file" : "files"
            model.overwriteAlertMessage = "\(n) of \(total) \(noun) would overwrite its original.\n\n• Add Suffix — optimize the safe files now; skip the rest.\n• Replace Originals — optimize all, overwriting the conflicting originals."
            model.showOverwriteAlert = true
            return
        }
        engine.start(job: request.job, files: files)
    }

    private func splitConflicts(files: [FileItem], job: ProcessingJob) -> (safe: [FileItem], conflicting: [FileItem]) {
        var safe: [FileItem] = []
        var conflicting: [FileItem] = []
        for file in files {
            let source = file.url.standardizedFileURL.path.lowercased()
            let target = ProcessingEngine.outputURL(for: file.url, suffix: job.outputSuffix, ext: job.outputExtension)
                .standardizedFileURL.path.lowercased()
            if target == source {
                conflicting.append(file)
            } else {
                safe.append(file)
            }
        }
        return (safe, conflicting)
    }
}

struct FileRowView: View {
    @ObservedObject var file: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .allowsHitTesting(false)
            Text(file.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsHitTesting(false)
            Spacer()
            if file.audioTracks.count > 1 {
                Picker("", selection: $file.selectedAudioTrack) {
                    ForEach(file.audioTracks) { track in
                        Text(track.label).tag(track.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch file.status {
        case .none:
            Text("\(file.originalSize / 1024) KB")
                .foregroundStyle(.secondary)
                .font(.caption)
                .allowsHitTesting(false)
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
                .allowsHitTesting(false)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .done(let before, let after):
            let pct = before > 0 ? Int(after * 100 / before) : 0
            Text(before > 0 ? "\(pct)%" : "done")
                .foregroundStyle(pct > 100 ? .orange : .green)
                .font(.caption)
                .allowsHitTesting(false)
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }
}
