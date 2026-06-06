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
        .frame(minWidth: 480, maxWidth: 480, minHeight: 450)
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
        }
        .onChange(of: model.settings.audioFormat) {
            model.settings.audioBitrate = model.settings.audioFormat.bitrateDefault
        }
        .alert("Error", isPresented: $model.showAlert) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage)
        }
        .alert("Replace original files?", isPresented: $model.showOverwriteAlert) {
            Button("Cancel", role: .cancel) {
                pendingOverwrite = nil
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
            Button("Replace Originals", role: .destructive) {
                let p = pendingOverwrite
                pendingOverwrite = nil
                guard let p else { return }
                engine.start(job: p.job, files: p.safe + p.conflicting)
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
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        }
                        Button("Remove from List  ⌫") {
                            if model.selection.contains(file.id) {
                                model.removeSelected(from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                            } else {
                                model.removeFile(file, from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                            }
                        }
                        .disabled(engine.isProcessing)
                        Button("Move to Trash  ⌘⌫") {
                            if model.selection.contains(file.id) {
                                model.trashSelected()
                            } else {
                                model.trashFile(file, from: model.settings.selectedTab, isProcessing: engine.isProcessing)
                            }
                        }
                        .disabled(engine.isProcessing)
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
                Button("Add Files...") { addFiles() }
                Button("Screenshot...") { takeScreenshot() }
                    .disabled(screenshotter.isCapturing || recorder.isActive)
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
                Button("Add Files...") { addFiles() }
                Button(recorder.isRecording ? "Stop Recording" : "Record Screen...") { recordScreen() }
                    .disabled(screenshotter.isCapturing)
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

            optimizeButton(disabled: model.queues.video.isEmpty)
        }
        .padding()
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
                Button("Add Files...") { addFiles() }
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
        for url in panel.urls {
            model.addFile(url, preferredTab: destination, probeAudioTracks: engine.probeAudioTracks)
        }
    }

    private func recordScreen() {
        if recorder.isRecording {
            recorder.stop()
            return
        }

        recorder.start(
            onFinish: { url in
                model.settings.selectedTab = .video
                model.addFile(url, preferredTab: .auto, probeAudioTracks: engine.probeAudioTracks)
            },
            onError: { message in
                model.presentError(message)
            }
        )
    }

    private func takeScreenshot() {
        screenshotter.start(
            onFinish: { url in
                model.settings.selectedTab = .images
                model.addFile(url, preferredTab: .auto, probeAudioTracks: engine.probeAudioTracks)
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
        if let message = engine.checkTools(for: request.job) {
            model.presentError(message)
            return
        }
        let (safe, conflicting) = splitConflicts(files: request.files, job: request.job)
        guard conflicting.isEmpty else {
            pendingOverwrite = (job: request.job, safe: safe, conflicting: conflicting)
            let n = conflicting.count
            let total = request.files.count
            let noun = n == 1 ? "file" : "files"
            model.overwriteAlertMessage = "\(n) of \(total) \(noun) would overwrite its original.\n\n• Add Suffix — optimize the safe files now; skip the rest.\n• Replace Originals — optimize all, overwriting the conflicting originals."
            model.showOverwriteAlert = true
            return
        }
        engine.start(job: request.job, files: request.files)
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
            Text(file.filename)
                .lineLimit(1)
                .truncationMode(.middle)
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
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .done(let before, let after):
            let pct = before > 0 ? Int(after * 100 / before) : 0
            Text(before > 0 ? "\(pct)%" : "done")
                .foregroundStyle(pct > 100 ? .orange : .green)
                .font(.caption)
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
