import AppKit
import Foundation
import ImageIO

enum PreviewImageDecoder {
    static let cardPreviewMaxPixelSize = 560

    static func previewImage(from data: Data, maxPixelSize: Int = cardPreviewMaxPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return previewImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func previewImage(fromFileAt path: String, maxPixelSize: Int = cardPreviewMaxPixelSize) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return previewImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func previewImage(from source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
