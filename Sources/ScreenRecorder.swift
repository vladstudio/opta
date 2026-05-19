import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCContentSharingPickerObserver, SCRecordingOutputDelegate {
    @Published private var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    private var hiddenWindow: NSWindow?
    private var onFinish: ((URL) -> Void)?
    private var onError: ((String) -> Void)?

    private enum State {
        case idle
        case picking
        case recording(ActiveRecording)
    }

    private struct ActiveRecording {
        let stream: SCStream
        let output: SCRecordingOutput
        let url: URL
    }

    func start(onFinish: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
        guard case .idle = state else { return }
        self.onFinish = onFinish
        self.onError = onError
        state = .picking

        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow]
        picker.defaultConfiguration = config
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        guard case let .recording(active) = state else { return }
        Task { try? await active.stream.stopCapture() }
    }

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.teardownPicker()
            self.state = .idle
            self.onFinish = nil
            self.onError = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.teardownPicker()
            await self.beginCapture(filter: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.teardownPicker()
            self.onError?(error.localizedDescription)
            self.state = .idle
            self.onFinish = nil
            self.onError = nil
        }
    }

    // MARK: - SCRecordingOutputDelegate

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(success: true) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            self.onError?(error.localizedDescription)
            self.finish(success: false)
        }
    }

    // MARK: - Private

    private func teardownPicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func beginCapture(filter: SCContentFilter) async {
        let url = desktopCaptureURL(prefix: "Screen Recording", ext: "mov")

        let streamConfig = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        streamConfig.width = Int(filter.contentRect.width * scale)
        streamConfig.height = Int(filter.contentRect.height * scale)
        streamConfig.showsCursor = true
        streamConfig.capturesAudio = true

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)

        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            state = .recording(ActiveRecording(stream: stream, output: output, url: url))
            hideMainWindow()
        } catch {
            onError?(error.localizedDescription)
            state = .idle
            onFinish = nil
            onError = nil
        }
    }

    private func finish(success: Bool) {
        guard case let .recording(active) = state else { return }
        let callback = onFinish
        state = .idle
        onFinish = nil
        onError = nil
        restoreMainWindow()
        if success, FileManager.default.fileExists(atPath: active.url.path(percentEncoded: false)) {
            callback?(active.url)
        }
    }

    private func hideMainWindow() {
        hiddenWindow = NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0.styleMask.contains(.titled) }
        hiddenWindow?.orderOut(nil)
    }

    private func restoreMainWindow() {
        hiddenWindow?.makeKeyAndOrderFront(nil)
        hiddenWindow = nil
        NSApp.activate()
    }

}
