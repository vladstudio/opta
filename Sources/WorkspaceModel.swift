import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var selectedTab: MediaTab = .images
    @Published var queues = MediaQueues()

    @Published var imageFormat: ImageOutputFormat = .png
    @Published var imageSuffix = ""
    @Published var imageStripMetadata = true
    @Published var imageColorIndex = 0.0
    @Published var imageQuality = 80.0

    @Published var videoFormat: VideoOutputFormat = .mp4H264
    @Published var videoSuffix = ""
    @Published var videoStripMetadata = true
    @Published var videoDimension: DimensionPreset = .original
    @Published var videoCRF = 30.0

    @Published var audioFormat: AudioOutputFormat = .mp3
    @Published var audioSuffix = ""
    @Published var audioStripMetadata = true
    @Published var audioBitrateIndex = AudioOutputFormat.mp3.bitrateSteps.firstIndex(of: AudioOutputFormat.mp3.bitrateDefault) ?? 0

    @Published var selection: Set<FileItem.ID> = []
    @Published var showAlert = false
    @Published var alertMessage = ""

    func files(for tab: MediaTab) -> [FileItem] {
        queues[tab]
    }

    var currentFiles: [FileItem] {
        queues[selectedTab]
    }

    func ingestPendingURLs(_ urls: [URL], probeAudioTracks: (FileItem) -> Void) {
        guard !urls.isEmpty else { return }
        let wasEmpty = queues.isEmpty
        for url in urls {
            addFile(url, preferredTab: .auto, probeAudioTracks: probeAudioTracks)
        }
        guard wasEmpty else { return }
        if !queues.images.isEmpty { selectedTab = .images }
        else if !queues.video.isEmpty { selectedTab = .video }
        else if !queues.audio.isEmpty { selectedTab = .audio }
    }

    func handleCommand(_ command: AppCommand, isProcessing: Bool, preview: ([URL]) -> Void) {
        switch command {
        case .selectTab(let tab):
            guard !isProcessing else { return }
            selectedTab = tab
        case .previewSelection:
            preview(previewURLs())
        case .trashSelection:
            guard !isProcessing, !selection.isEmpty else { return }
            trashSelected()
        }
    }

    func syncFormatDefaults() {
        videoCRF = videoFormat.crfDefault

        let steps = audioFormat.bitrateSteps
        if let idx = steps.firstIndex(of: audioFormat.bitrateDefault) {
            audioBitrateIndex = idx
        } else {
            audioBitrateIndex = max(0, steps.count - 1)
        }
    }

    func hasUnprocessedFiles(for tab: MediaTab) -> Bool {
        queues[tab].contains { $0.status == nil }
    }

    func tabLabel(for tab: MediaTab) -> String {
        hasUnprocessedFiles(for: tab) ? "\(tab.rawValue) \u{2022}" : tab.rawValue
    }

    func clearSelectionForTabChange() {
        selection.removeAll()
    }

    func removeFile(_ file: FileItem, from tab: MediaTab, isProcessing: Bool) {
        guard !isProcessing else { return }
        updateFiles(for: tab) { files in
            files.removeAll { $0.id == file.id }
        }
        selection.remove(file.id)
    }

    func removeSelected(from tab: MediaTab, isProcessing: Bool) {
        guard !isProcessing else { return }
        let ids = selection
        updateFiles(for: tab) { files in
            files.removeAll { ids.contains($0.id) }
        }
        selection.removeAll()
    }

    func trashFile(_ file: FileItem, from tab: MediaTab, isProcessing: Bool) {
        guard !isProcessing else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            removeFile(file, from: tab, isProcessing: false)
        } catch {
            presentError("Failed to move \(file.filename) to Trash: \(error.localizedDescription)")
        }
    }

    func trashSelected() {
        let selectedFiles = currentFiles.filter { selection.contains($0.id) }
        var failedFiles: [String] = []
        var trashedIDs = Set<FileItem.ID>()
        for file in selectedFiles {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                trashedIDs.insert(file.id)
            } catch {
                failedFiles.append(file.filename)
            }
        }

        if !failedFiles.isEmpty {
            presentError("Failed to move to Trash: \(failedFiles.joined(separator: ", "))")
        }

        updateFiles(for: selectedTab) { files in
            files.removeAll { trashedIDs.contains($0.id) }
        }
        selection.subtract(trashedIDs)
    }

    func previewURLs() -> [URL] {
        currentFiles.filter { selection.contains($0.id) }.map(\.url)
    }

    func addFile(_ url: URL, preferredTab: FileDestination, probeAudioTracks: (FileItem) -> Void) {
        let normalized = url.standardizedFileURL
        guard let targetTab = destinationTab(for: normalized, destination: preferredTab) else { return }
        guard !queues[targetTab].contains(where: { $0.url.standardizedFileURL == normalized }) else { return }

        let item = FileItem(url: normalized)
        updateFiles(for: targetTab) { files in
            files.append(item)
        }
        if targetTab == .audio && item.isVideoSource {
            probeAudioTracks(item)
        }
    }

    func destinationForCurrentTab() -> FileDestination {
        selectedTab == .audio ? .audioExtraction : .tab(selectedTab)
    }

    func handleDroppedURLs(_ urls: [URL], destination: FileDestination, probeAudioTracks: (FileItem) -> Void) {
        if let firstTab = urls.compactMap({ destinationTab(for: $0.standardizedFileURL, destination: destination) }).first {
            selectedTab = firstTab
        }
        for url in urls {
            addFile(url, preferredTab: destination, probeAudioTracks: probeAudioTracks)
        }
    }

    func optimizationRequest() -> (job: ProcessingJob, files: [FileItem])? {
        switch selectedTab {
        case .images:
            let pending = queues.images.filter { $0.status == nil }
            guard !pending.isEmpty else { return nil }
            return (
                .images(ImageJob(
                    format: imageFormat,
                    suffix: imageSuffix,
                    stripMetadata: imageStripMetadata,
                    colorIndex: Int(imageColorIndex),
                    quality: Int(imageQuality),
                    oxipngLevel: 6
                )),
                pending
            )
        case .video:
            let pending = queues.video.filter { $0.status == nil }
            guard !pending.isEmpty else { return nil }
            return (
                .video(VideoJob(
                    format: videoFormat,
                    suffix: videoSuffix,
                    stripMetadata: videoStripMetadata,
                    dimension: videoDimension,
                    crf: Int(videoCRF)
                )),
                pending
            )
        case .audio:
            let pending = queues.audio.filter { $0.status == nil }
            guard !pending.isEmpty else { return nil }
            let steps = audioFormat.bitrateSteps
            let bitrate = steps.isEmpty ? 0 : steps[min(audioBitrateIndex, steps.count - 1)]
            return (
                .audio(AudioJob(
                    format: audioFormat,
                    suffix: audioSuffix,
                    stripMetadata: audioStripMetadata,
                    bitrate: bitrate
                )),
                pending
            )
        }
    }

    func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func updateFiles(for tab: MediaTab, _ update: (inout [FileItem]) -> Void) {
        var files = queues[tab]
        update(&files)
        queues[tab] = files
    }

    private func destinationTab(for url: URL, destination: FileDestination) -> MediaTab? {
        guard let classifiedTab = classifyFile(url) else { return nil }
        switch destination {
        case .auto:
            return classifiedTab
        case .tab(let tab):
            return tab == classifiedTab ? classifiedTab : nil
        case .audioExtraction:
            return classifiedTab == .video ? .audio : (classifiedTab == .audio ? .audio : nil)
        }
    }
}

enum FileDestination {
    case auto
    case tab(MediaTab)
    case audioExtraction
}
