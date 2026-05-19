import Foundation
import ImageIO
import ScreenCaptureKit

@MainActor
final class ScreenshotCapturer: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published private var state: State = .idle

    var isCapturing: Bool {
        if case .idle = state { return false }
        return true
    }

    private var onFinish: ((URL) -> Void)?
    private var onError: ((String) -> Void)?

    private enum State { case idle, picking, capturing }
    private enum WriteError: LocalizedError {
        case create, finalize
        var errorDescription: String? { "Failed to write screenshot to Desktop" }
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

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancel() }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.capture(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.fail(error.localizedDescription) }
    }

    private func capture(_ filter: SCContentFilter) {
        state = .capturing
        teardownPicker()

        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = true

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            Task { @MainActor in
                do {
                    guard let image else { throw error ?? WriteError.create }
                    self.succeed(try self.write(image))
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func cancel() {
        cleanup()
    }

    private func fail(_ message: String) {
        let callback = onError
        cleanup()
        callback?(message)
    }

    private func succeed(_ url: URL) {
        let callback = onFinish
        cleanup()
        callback?(url)
    }

    private func cleanup() {
        teardownPicker()
        state = .idle
        onFinish = nil
        onError = nil
    }

    private func write(_ image: CGImage) throws -> URL {
        let url = desktopCaptureURL(prefix: "Screenshot", ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw WriteError.create }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.finalize }
        return url
    }

    private func teardownPicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }
}
