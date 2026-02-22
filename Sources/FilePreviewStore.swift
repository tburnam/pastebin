import AppKit
import Foundation
import QuickLookThumbnailing

@MainActor
final class FilePreviewStore: ObservableObject {
    @Published private var cachedImages: [String: NSImage] = [:]
    private var inFlightPaths: Set<String> = []

    func preview(for path: String) -> NSImage? {
        cachedImages[path]
    }

    func loadPreview(for path: String) {
        guard !path.isEmpty else { return }
        guard cachedImages[path] == nil else { return }
        guard !inFlightPaths.contains(path) else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        inFlightPaths.insert(path)

        // Fast path for directly viewable image assets.
        if let directImage = NSImage(contentsOfFile: path) {
            cachedImages[path] = directImage
            inFlightPaths.remove(path)
            return
        }

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
                self.cachedImages[path] = representation.nsImage
            }
        }
    }
}
