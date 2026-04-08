import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = ProcessingEngine()
    @State private var selectedTab: MediaTab = .images

    // Per-tab file lists
    @State private var imageFiles: [FileItem] = []
    @State private var videoFiles: [FileItem] = []
    @State private var audioFiles: [FileItem] = []

    // Image controls
    @State private var imageFormat: ImageOutputFormat = .png
    @State private var imageSuffix = ""
    @State private var imageStripMetadata = true
    @State private var imageColorIndex = 0.0
    @State private var imageQuality = 80.0

    // Video controls
    @State private var videoFormat: VideoOutputFormat = .mp4H264
    @State private var videoSuffix = ""
    @State private var videoStripMetadata = true
    @State private var videoDimension: DimensionPreset = .original
    @State private var videoCRF = 30.0

    // Audio controls
    @State private var audioFormat: AudioOutputFormat = .mp3
    @State private var audioSuffix = ""
    @State private var audioStripMetadata = true
    @State private var audioBitrateIndex = AudioOutputFormat.mp3.bitrateSteps.firstIndex(of: AudioOutputFormat.mp3.bitrateDefault) ?? 0

    @State private var selection: Set<FileItem.ID> = []
    @EnvironmentObject private var appState: AppState
    @State private var showAlert = false
    @State private var alertMessage = ""

    private func files(for tab: MediaTab) -> [FileItem] {
        switch tab {
        case .images: return imageFiles
        case .video: return videoFiles
        case .audio: return audioFiles
        }
    }

    private var currentFiles: [FileItem] { files(for: selectedTab) }

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
            let wasEmpty = imageFiles.isEmpty && videoFiles.isEmpty && audioFiles.isEmpty
            for url in appState.pendingURLs { addFile(url) }
            appState.pendingURLs.removeAll()
            if wasEmpty {
                if !imageFiles.isEmpty { selectedTab = .images }
                else if !videoFiles.isEmpty { selectedTab = .video }
                else if !audioFiles.isEmpty { selectedTab = .audio }
            }
        }
        .onChange(of: videoFormat) {
            videoCRF = videoFormat.crfDefault
        }
        .onChange(of: audioFormat) {
            let steps = audioFormat.bitrateSteps
            if let idx = steps.firstIndex(of: audioFormat.bitrateDefault) {
                audioBitrateIndex = idx
            } else {
                audioBitrateIndex = max(0, steps.count - 1)
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .background {
            Group {
                Button("") { selectedTab = .images }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .video }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .audio }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { if !engine.isProcessing { addFiles() } }
                    .keyboardShortcut(.space, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    // MARK: - Tab Bar

    private func hasUnprocessedFiles(for tab: MediaTab) -> Bool {
        files(for: tab).contains { $0.status == nil }
    }

    private func tabLabel(for tab: MediaTab) -> String {
        hasUnprocessedFiles(for: tab) ? "\(tab.rawValue) \u{2022}" : tab.rawValue
    }

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(MediaTab.allCases, id: \.self) { tab in
                Text(tabLabel(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .disabled(engine.isProcessing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: selectedTab) { selection.removeAll() }
    }

    // MARK: - File List

    private func removeSelected() {
        guard !engine.isProcessing else { return }
        let ids = selection
        switch selectedTab {
        case .images: imageFiles.removeAll { ids.contains($0.id) }
        case .video: videoFiles.removeAll { ids.contains($0.id) }
        case .audio: audioFiles.removeAll { ids.contains($0.id) }
        }
        selection.removeAll()
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(currentFiles) { file in
                FileRowView(file: file)
                    .onTapGesture(count: 2) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
            }
        }
        .onDeleteCommand { removeSelected() }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .overlay {
            if currentFiles.isEmpty && !engine.isProcessing {
                let hint: String = {
                    switch selectedTab {
                    case .images: return "Drop image files here"
                    case .video: return "Drop video files here"
                    case .audio: return "Drop audio/video files here"
                    }
                }()
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.largeTitle)
                    Text(hint)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        Group {
            switch selectedTab {
            case .images: imageControls
            case .video: videoControls
            case .audio: audioControls
            }
        }
    }

    // MARK: Image Controls

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Files...") { addFiles() }
                Spacer()
                Text("Save as")
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $imageFormat) {
                    ForEach(ImageOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                TextField("optional suffix", text: $imageSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Toggle("Strip metadata", isOn: $imageStripMetadata)

            VStack(alignment: .leading, spacing: 4) {
                Text("Colors: \(colorLabel(Int(imageColorIndex)))")
                Slider(value: $imageColorIndex, in: 0...Double(colorSteps.count - 1), step: 1)
            }

            if imageFormat != .png {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(imageQuality))")
                    Slider(value: $imageQuality, in: 20...100, step: 2)
                }
            }

            optimizeButton(disabled: !imageFiles.contains { $0.status == nil })
        }
        .padding()
    }

    // MARK: Video Controls

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Files...") { addFiles() }
                Spacer()
                Text("Save as")
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $videoFormat) {
                    ForEach(VideoOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("optional suffix", text: $videoSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Toggle("Strip metadata", isOn: $videoStripMetadata)

            HStack {
                Text("Dimensions:")
                Picker("Dimensions", selection: $videoDimension) {
                    ForEach(DimensionPreset.allCases, id: \.self) { Text($0.label) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if videoFormat.hasCRF {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality (CRF): \(Int(videoCRF))  —  \(crfHint(Int(videoCRF)))")
                    Slider(value: $videoCRF,
                           in: videoFormat.crfRange,
                           step: 1)
                }
            }

            optimizeButton(disabled: !videoFiles.contains { $0.status == nil })
        }
        .padding()
    }

    private func crfHint(_ crf: Int) -> String {
        switch videoFormat {
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

    // MARK: Audio Controls

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Files...") { addFiles() }
                Spacer()
                Text("Save as")
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $audioFormat) {
                    ForEach(AudioOutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("optional suffix", text: $audioSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Toggle("Strip metadata", isOn: $audioStripMetadata)

            if !audioFormat.isLossless {
                let steps = audioFormat.bitrateSteps
                let clampedIndex = min(audioBitrateIndex, steps.count - 1)
                let currentBitrate = steps.isEmpty ? 0 : steps[max(0, clampedIndex)]

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bitrate: \(currentBitrate) kbps")
                    Slider(value: Binding(
                        get: { Double(clampedIndex) },
                        set: { audioBitrateIndex = Int($0) }
                    ), in: 0...Double(max(0, steps.count - 1)), step: 1)
                }
            }

            optimizeButton(disabled: !audioFiles.contains { $0.status == nil })
        }
        .padding()
    }

    // MARK: - Shared Controls

    private func optimizeButton(disabled: Bool) -> some View {
        HStack {
            Spacer()
            Button("Optimize") { optimize() }
                .disabled(disabled)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true

        switch selectedTab {
        case .images:
            panel.allowedContentTypes = acceptedImageTypes
        case .video:
            panel.allowedContentTypes = acceptedVideoTypes
        case .audio:
            panel.allowedContentTypes = acceptedAudioTypes + acceptedVideoTypes
        }

        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func addFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard let tab = classifyFile(normalized) else { return }

        // Video files on the audio tab → add as audio source
        let targetTab = (tab == .video && selectedTab == .audio) ? .audio : tab

        switch targetTab {
        case .images:
            guard !imageFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            imageFiles.append(FileItem(url: normalized))
        case .video:
            guard !videoFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            videoFiles.append(FileItem(url: normalized))
        case .audio:
            guard !audioFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            let item = FileItem(url: normalized)
            audioFiles.append(item)
            if item.isVideoSource {
                engine.probeAudioTracks(file: item)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let urlLock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urlLock.lock(); urls.append(url); urlLock.unlock()
            }
        }
        group.notify(queue: .main) {
            if let first = urls.first, let tab = classifyFile(first.standardizedFileURL) {
                selectedTab = tab
            }
            for url in urls { addFile(url) }
        }
        return true
    }

    private func optimize() {
        if let msg = engine.checkTools(for: selectedTab) {
            alertMessage = msg
            showAlert = true
            return
        }

        switch selectedTab {
        case .images:
            let pending = imageFiles.filter { $0.status == nil }
            guard !pending.isEmpty else { return }
            engine.startImages(
                files: pending, format: imageFormat, suffix: imageSuffix,
                stripMetadata: imageStripMetadata, colorIndex: Int(imageColorIndex),
                quality: Int(imageQuality), oxipngLevel: 6
            )
        case .video:
            let pending = videoFiles.filter { $0.status == nil }
            guard !pending.isEmpty else { return }
            engine.startVideo(
                files: pending, format: videoFormat, suffix: videoSuffix,
                stripMetadata: videoStripMetadata, dimension: videoDimension,
                crf: Int(videoCRF)
            )
        case .audio:
            let pending = audioFiles.filter { $0.status == nil }
            guard !pending.isEmpty else { return }
            let steps = audioFormat.bitrateSteps
            let bitrate = steps.isEmpty ? 0 : steps[min(audioBitrateIndex, steps.count - 1)]
            engine.startAudio(
                files: pending, format: audioFormat, suffix: audioSuffix,
                stripMetadata: audioStripMetadata, bitrate: bitrate
            )
        }
    }
}

// MARK: - File Row

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
        case .error(let msg):
            Text(msg)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
