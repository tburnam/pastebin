import AppKit
import CoreGraphics

enum StatusBarIconRenderer {
    private static let analysisSize = 256
    private static let rasterSize = 72
    private static let brightnessCutoff = 24
    private static let alphaCutoff = 8

    static func makeMenuBarImage(sideLength: CGFloat) -> NSImage? {
        guard let sourceImage = sourceImage(),
              let cgImage = cgImage(from: sourceImage),
              let processed = makeTemplateGlyph(from: cgImage) else {
            return nil
        }

        let image = NSImage(cgImage: processed, size: NSSize(width: sideLength, height: sideLength))
        image.isTemplate = true
        return image
    }

    private static func sourceImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            return image
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            image.size = NSSize(width: analysisSize, height: analysisSize)
            return image
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let workspaceIconURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pastebinicon.png")
        if let image = NSImage(contentsOf: workspaceIconURL) {
            return image
        }

        return nil
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: NSSize(width: analysisSize, height: analysisSize))
        if let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) {
            return cgImage
        }

        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.cgImage
    }

    private static func makeTemplateGlyph(from source: CGImage) -> CGImage? {
        guard let analysisContext = rgbaContext(width: analysisSize, height: analysisSize) else {
            return nil
        }

        analysisContext.interpolationQuality = .high
        analysisContext.draw(
            source,
            in: CGRect(x: 0, y: 0, width: analysisSize, height: analysisSize)
        )

        guard let bounds = brightPixelBounds(in: analysisContext, width: analysisSize, height: analysisSize) else {
            return nil
        }

        let expandedBounds = bounds.insetBy(dx: -10, dy: -10)
            .intersection(CGRect(x: 0, y: 0, width: analysisSize, height: analysisSize))
            .integral
        guard expandedBounds.width > 0, expandedBounds.height > 0 else {
            return nil
        }

        let cropWidth = Int(expandedBounds.width)
        let cropHeight = Int(expandedBounds.height)
        guard let cropContext = rgbaContext(width: cropWidth, height: cropHeight),
              let analysisData = analysisContext.data,
              let cropData = cropContext.data else {
            return nil
        }

        let sourceBytes = analysisData.bindMemory(to: UInt8.self, capacity: analysisSize * analysisSize * 4)
        let outputBytes = cropData.bindMemory(to: UInt8.self, capacity: cropWidth * cropHeight * 4)

        for y in 0..<cropHeight {
            for x in 0..<cropWidth {
                let sourceX = Int(expandedBounds.minX) + x
                let sourceY = Int(expandedBounds.minY) + y
                let sourceOffset = ((sourceY * analysisSize) + sourceX) * 4
                let outputOffset = ((y * cropWidth) + x) * 4

                let red = Int(sourceBytes[sourceOffset])
                let green = Int(sourceBytes[sourceOffset + 1])
                let blue = Int(sourceBytes[sourceOffset + 2])
                let alpha = Int(sourceBytes[sourceOffset + 3])

                let brightness = luminance(red: red, green: green, blue: blue)
                let normalizedBrightness = max(0, brightness - brightnessCutoff)
                let normalizedAlpha = max(0, alpha - alphaCutoff)
                let combinedAlpha = min(
                    255,
                    Int(Double(normalizedBrightness) / Double(255 - brightnessCutoff) * 255.0)
                        * normalizedAlpha / 255
                )

                outputBytes[outputOffset] = 255
                outputBytes[outputOffset + 1] = 255
                outputBytes[outputOffset + 2] = 255
                outputBytes[outputOffset + 3] = UInt8(max(0, min(255, combinedAlpha)))
            }
        }

        guard let croppedGlyph = cropContext.makeImage(),
              let outputContext = rgbaContext(width: rasterSize, height: rasterSize) else {
            return nil
        }

        outputContext.clear(CGRect(x: 0, y: 0, width: rasterSize, height: rasterSize))
        outputContext.interpolationQuality = .high

        let padding = CGFloat(rasterSize) * 0.10
        let availableRect = CGRect(
            x: padding,
            y: padding,
            width: CGFloat(rasterSize) - (padding * 2),
            height: CGFloat(rasterSize) - (padding * 2)
        )
        let drawRect = aspectFitRect(
            sourceSize: CGSize(width: cropWidth, height: cropHeight),
            inside: availableRect
        )
        outputContext.draw(croppedGlyph, in: drawRect)

        return outputContext.makeImage()
    }

    private static func brightPixelBounds(in context: CGContext, width: Int, height: Int) -> CGRect? {
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let offset = ((y * width) + x) * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                let alpha = Int(bytes[offset + 3])

                guard alpha > alphaCutoff else { continue }
                guard luminance(red: red, green: green, blue: blue) > brightnessCutoff else { continue }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )
    }

    private static func aspectFitRect(sourceSize: CGSize, inside bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }

        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        return CGRect(
            x: bounds.midX - (fittedSize.width / 2),
            y: bounds.midY - (fittedSize.height / 2),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        )
    }

    private static func luminance(red: Int, green: Int, blue: Int) -> Int {
        (red * 2126 + green * 7152 + blue * 722) / 10_000
    }
}
