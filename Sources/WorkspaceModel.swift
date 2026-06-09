import Foundation

struct Settings: Codable {
    var selectedTab: MediaTab = .images
    var imageFormat: ImageOutputFormat = .png
    var imageSuffix = ""
    var imageStripMetadata = true
    var imageColorIndex = 0.0
    var imageQuality = 80.0
    var videoFormat: VideoOutputFormat = .mp4H264
    var videoSuffix = ""
    var videoStripMetadata = true
    var videoDimension: DimensionPreset = .original
    var videoCRF = 30.0
    var videoAudioBitrate = VideoOutputFormat.mp4H264.audioBitrateDefault
    var audioFormat: AudioOutputFormat = .mp3
    var audioSuffix = ""
    var audioStripMetadata = true
    var audioBitrate = AudioOutputFormat.mp3.bitrateDefault

    // Bump the suffix on any schema-breaking change; prior values reset to defaults.
    private static let storageKey = "WorkspaceSettings.v2"

    static func load() -> Settings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    func save() {
        let data = try! JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var settings = Settings.load() { didSet { scheduleSave() } }
    @Published var queues = MediaQueues()
    @Published var selection: Set<FileItem.ID> = []
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var showOverwriteAlert = false
    @Published var overwriteAlertMessage = ""

    private var saveWorkItem: DispatchWorkItem?

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = settings
        let work = DispatchWorkItem { snapshot.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    func files(for tab: MediaTab) -> [FileItem] {
        queues[tab]
    }

    var currentFiles: [FileItem] {
        queues[settings.selectedTab]
    }

    func ingestPendingURLs(_ urls: [URL], probeAudioTracks: (FileItem) -> Void) {
        guard !urls.isEmpty else { return }
        let wasEmpty = queues.isEmpty
        for url in urls {
            addFile(url, preferredTab: .auto, probeAudioTracks: probeAudioTracks)
        }
        guard wasEmpty else { return }
        if !queues.images.isEmpty { settings.selectedTab = .images }
        else if !queues.video.isEmpty { settings.selectedTab = .video }
        else if !queues.audio.isEmpty { settings.selectedTab = .audio }
    }

    func handleCommand(_ command: AppCommand, isProcessing: Bool, preview: ([URL]) -> Void) {
        switch command {
        case .selectTab(let tab):
            guard !isProcessing else { return }
            settings.selectedTab = tab
        case .previewSelection:
            preview(previewURLs())
        case .trashSelection:
            guard !isProcessing, !selection.isEmpty else { return }
            trashSelected()
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

        updateFiles(for: settings.selectedTab) { files in
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
        settings.selectedTab == .audio ? .audioExtraction : .tab(settings.selectedTab)
    }

    func handleDroppedURLs(_ urls: [URL], destination: FileDestination, probeAudioTracks: (FileItem) -> Void) {
        if let firstTab = urls.compactMap({ destinationTab(for: $0.standardizedFileURL, destination: destination) }).first {
            settings.selectedTab = firstTab
        }
        for url in urls {
            addFile(url, preferredTab: destination, probeAudioTracks: probeAudioTracks)
        }
    }

    func optimizationRequest() -> (job: ProcessingJob, files: [FileItem])? {
        switch settings.selectedTab {
        case .images:
            guard !queues.images.isEmpty else { return nil }
            return (
                .images(ImageJob(
                    format: settings.imageFormat,
                    suffix: settings.imageSuffix,
                    stripMetadata: settings.imageStripMetadata,
                    colorIndex: Int(settings.imageColorIndex),
                    quality: Int(settings.imageQuality),
                    oxipngLevel: 6
                )),
                queues.images
            )
        case .video:
            guard !queues.video.isEmpty else { return nil }
            return (
                .video(VideoJob(
                    format: settings.videoFormat,
                    suffix: settings.videoSuffix,
                    stripMetadata: settings.videoStripMetadata,
                    dimension: settings.videoDimension,
                    crf: Int(settings.videoCRF),
                    audioBitrate: settings.videoAudioBitrate
                )),
                queues.video
            )
        case .audio:
            guard !queues.audio.isEmpty else { return nil }
            return (
                .audio(AudioJob(
                    format: settings.audioFormat,
                    suffix: settings.audioSuffix,
                    stripMetadata: settings.audioStripMetadata,
                    bitrate: settings.audioBitrate
                )),
                queues.audio
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
