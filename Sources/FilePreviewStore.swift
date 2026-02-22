import AppKit
import Foundation
import QuickLookThumbnailing

@MainActor
final class FilePreviewStore: ObservableObject {
    private let cachedImages: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 320
        return cache
    }()
    private var inFlightPaths: Set<String> = []
    private var hasScheduledChangeNotification = false

    func preview(for path: String) -> NSImage? {
        cachedImages.object(forKey: path as NSString)
    }

    func loadPreview(for path: String) {
        guard !path.isEmpty else { return }
        guard cachedImages.object(forKey: path as NSString) == nil else { return }
        guard !inFlightPaths.contains(path) else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        inFlightPaths.insert(path)

        // Decode images off the main thread to avoid frame drops on large files.
        let pathCopy = path
        Task.detached(priority: .userInitiated) { [weak self] in
            if let directImage = NSImage(contentsOfFile: pathCopy) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.cacheImage(directImage, for: pathCopy)
                    self.inFlightPaths.remove(pathCopy)
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.generateThumbnail(for: pathCopy)
            }
        }
    }

    private func generateThumbnail(for path: String) {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 320, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: [.thumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.inFlightPaths.remove(path) }

                guard let representation else { return }
                self.cacheImage(representation.nsImage, for: path)
            }
        }
    }

    private func cacheImage(_ image: NSImage, for path: String) {
        cachedImages.setObject(image, forKey: path as NSString)
        scheduleChangeNotification()
    }

    private func scheduleChangeNotification() {
        guard !hasScheduledChangeNotification else { return }
        hasScheduledChangeNotification = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledChangeNotification = false
            self.objectWillChange.send()
        }
    }
}
