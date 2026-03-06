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
    @State private var videoCRF = 20.0

    // Audio controls
    @State private var audioFormat: AudioOutputFormat = .mp3
    @State private var audioSuffix = ""
    @State private var audioStripMetadata = true
    @State private var audioBitrateIndex = AudioOutputFormat.mp3.bitrateSteps.firstIndex(of: AudioOutputFormat.mp3.bitrateDefault) ?? 0

    @State private var selection: Set<FileItem.ID> = []
    @EnvironmentObject private var appState: AppState
    @State private var showAlert = false
    @State private var alertMessage = ""

    private var currentFiles: [FileItem] {
        switch selectedTab {
        case .images: return imageFiles
        case .video: return videoFiles
        case .audio: return audioFiles
        }
    }

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
        .onChange(of: appState.pendingURLs) { newValue in
            guard !newValue.isEmpty else { return }
            for url in newValue { addFile(url) }
            appState.pendingURLs.removeAll()
        }
        .onChange(of: videoFormat) { newFormat in
            videoCRF = newFormat.crfDefault
        }
        .onChange(of: audioFormat) { newFormat in
            let steps = newFormat.bitrateSteps
            if let idx = steps.firstIndex(of: newFormat.bitrateDefault) {
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
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MediaTab.allCases, id: \.self) { tab in
                let count: Int = {
                    switch tab {
                    case .images: return imageFiles.count
                    case .video: return videoFiles.count
                    case .audio: return audioFiles.count
                    }
                }()

                Button {
                    if !engine.isProcessing { selectedTab = tab; selection.removeAll() }
                } label: {
                    Text("\(tab.rawValue) (\(count))")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if tab != MediaTab.allCases.last {
                    Divider().frame(height: 24)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
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
                    case .audio: return "Drop audio files here"
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

            optimizeButton(disabled: imageFiles.isEmpty)
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

            optimizeButton(disabled: videoFiles.isEmpty)
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

            optimizeButton(disabled: audioFiles.isEmpty)
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
            panel.allowedContentTypes = acceptedAudioTypes
        }

        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func addFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard let tab = classifyFile(normalized) else { return }

        switch tab {
        case .images:
            guard !imageFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            imageFiles.append(FileItem(url: normalized))
        case .video:
            guard !videoFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            videoFiles.append(FileItem(url: normalized))
        case .audio:
            guard !audioFiles.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
            audioFiles.append(FileItem(url: normalized))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { addFile(url) }
            }
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
            engine.startImages(
                files: imageFiles, format: imageFormat, suffix: imageSuffix,
                stripMetadata: imageStripMetadata, colorIndex: Int(imageColorIndex),
                quality: Int(imageQuality), oxipngLevel: 6
            )
        case .video:
            engine.startVideo(
                files: videoFiles, format: videoFormat, suffix: videoSuffix,
                stripMetadata: videoStripMetadata, dimension: videoDimension,
                crf: Int(videoCRF)
            )
        case .audio:
            let steps = audioFormat.bitrateSteps
            let bitrate = steps.isEmpty ? 0 : steps[min(audioBitrateIndex, steps.count - 1)]
            engine.startAudio(
                files: audioFiles, format: audioFormat, suffix: audioSuffix,
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
            Text(before > 0 ? "\(after * 100 / before)%" : "done")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let msg):
            Text(msg)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
