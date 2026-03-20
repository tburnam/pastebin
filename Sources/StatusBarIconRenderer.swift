import AppKit
import CoreGraphics

enum StatusBarIconRenderer {
    private static let analysisSize = 384
    private static let brightnessCutoff = 56
    private static let alphaCutoff = 12
    private static let logicalHeight: CGFloat = 17
    private static let rasterScale: CGFloat = 2

    static func makeMenuBarImage(sideLength: CGFloat) -> NSImage? {
        if let logoImage = makeLogoTemplateImage(sideLength: sideLength) {
            return logoImage
        }

        return makeFallbackMonogramImage(sideLength: sideLength)
    }

    private static func makeLogoTemplateImage(sideLength: CGFloat) -> NSImage? {
        guard let sourceImage = sourceImage(),
              let cgImage = cgImage(from: sourceImage),
              let templateImage = makeTemplateGlyph(from: cgImage) else {
            return nil
        }

        let outputHeight = max(logicalHeight, sideLength.rounded(.up))
        let scale = outputHeight / CGFloat(templateImage.height)
        let outputWidth = CGFloat(templateImage.width) * scale

        let image = NSImage(
            cgImage: templateImage,
            size: NSSize(width: outputWidth, height: outputHeight)
        )
        image.isTemplate = true
        return image
    }

    private static func sourceImage() -> NSImage? {
        if let bundledPNG = Bundle.main.url(forResource: "StatusBarSource", withExtension: "png"),
           let image = NSImage(contentsOf: bundledPNG) {
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
        guard let analysisRep = scaledBitmapRep(from: source, width: analysisSize, height: analysisSize),
              let extracted = extractMask(from: analysisRep) else {
            return nil
        }
        let canvasHeight = Int((max(logicalHeight, 16) * rasterScale).rounded(.up))
        let availableHeight = CGFloat(canvasHeight) * 0.78
        let scale = availableHeight / CGFloat(extracted.height)
        let canvasWidth = Int((CGFloat(extracted.width) * scale + CGFloat(canvasHeight) * 0.18).rounded(.up))

        guard let outputContext = rgbaContext(width: canvasWidth, height: canvasHeight) else {
            return nil
        }

        outputContext.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        outputContext.interpolationQuality = .high

        let targetSize = CGSize(
            width: CGFloat(extracted.width) * scale,
            height: CGFloat(extracted.height) * scale
        )
        let drawRect = CGRect(
            x: CGFloat(canvasWidth) * 0.09,
            y: (CGFloat(canvasHeight) - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        outputContext.saveGState()
        outputContext.clip(to: drawRect, mask: extracted.mask)
        outputContext.setFillColor(NSColor.white.cgColor)
        outputContext.fill(drawRect)
        outputContext.restoreGState()

        return outputContext.makeImage()
    }

    private static func scaledBitmapRep(from source: CGImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let context = rgbaContext(width: width, height: height) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaledImage = context.makeImage() else {
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: scaledImage)
        rep.size = NSSize(width: width, height: height)
        return rep
    }

    private static func extractMask(from rep: NSBitmapImageRep) -> (mask: CGImage, width: Int, height: Int)? {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        var alphaByPixel = [UInt8](repeating: 0, count: width * height)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = max(color.redComponent, max(color.greenComponent, color.blueComponent)) * 255.0
                let normalizedBrightness = max(0.0, brightness - Double(brightnessCutoff))
                let alphaFactor = pow(
                    normalizedBrightness / Double(255 - brightnessCutoff),
                    1.15
                )
                let alpha = UInt8(max(0, min(255, Int(alphaFactor * 255.0))))
                alphaByPixel[(y * width) + x] = alpha

                guard alpha > alphaCutoff else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let expandedMinX = max(0, minX - 18)
        let expandedMinY = max(0, minY - 18)
        let expandedMaxX = min(width - 1, maxX + 18)
        let expandedMaxY = min(height - 1, maxY + 18)
        let cropWidth = expandedMaxX - expandedMinX + 1
        let cropHeight = expandedMaxY - expandedMinY + 1

        var maskData = Data(count: cropWidth * cropHeight)
        maskData.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<cropHeight {
                for x in 0..<cropWidth {
                    let sourceX = expandedMinX + x
                    let sourceY = expandedMinY + y
                    bytes[(y * cropWidth) + x] = 255 - alphaByPixel[(sourceY * width) + sourceX]
                }
            }
        }

        guard let provider = CGDataProvider(data: maskData as CFData),
              let mask = CGImage(
                maskWidth: cropWidth,
                height: cropHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: cropWidth,
                provider: provider,
                decode: nil,
                shouldInterpolate: true
              ) else {
            return nil
        }

        return (mask, cropWidth, cropHeight)
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

    private static func makeFallbackMonogramImage(sideLength: CGFloat) -> NSImage? {
        let height = max(14, sideLength.rounded(.up))
        let size = NSSize(
            width: (height * 1.18).rounded(.up),
            height: height
        )

        let image = NSImage(size: size, flipped: false) { rect in
            drawFallbackMonogram(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawFallbackMonogram(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.clear(rect)

        let bounds = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.06)
        let strokeWidth = bounds.height * 0.24
        let loopDiameter = bounds.height * 0.48
        let holeDiameter = bounds.height * 0.19

        NSColor.white.setFill()
        NSColor.white.setStroke()

        NSBezierPath(
            roundedRect: CGRect(
                x: bounds.minX + bounds.width * 0.08,
                y: bounds.minY + bounds.height * 0.04,
                width: strokeWidth,
                height: bounds.height * 0.88
            ),
            xRadius: strokeWidth / 2,
            yRadius: strokeWidth / 2
        ).fill()

        NSBezierPath(
            roundedRect: CGRect(
                x: bounds.minX + bounds.width * 0.45,
                y: bounds.minY + bounds.height * 0.42,
                width: strokeWidth,
                height: bounds.height * 0.50
            ),
            xRadius: strokeWidth / 2,
            yRadius: strokeWidth / 2
        ).fill()

        let leftLoopRect = CGRect(
            x: bounds.minX + bounds.width * 0.11,
            y: bounds.minY + bounds.height * 0.39,
            width: loopDiameter,
            height: loopDiameter
        )
        NSBezierPath(ovalIn: leftLoopRect).fill()

        let rightLoopRect = CGRect(
            x: bounds.minX + bounds.width * 0.50,
            y: bounds.minY + bounds.height * 0.23,
            width: loopDiameter,
            height: loopDiameter
        )
        NSBezierPath(ovalIn: rightLoopRect).fill()

        let bridge = NSBezierPath()
        bridge.lineWidth = strokeWidth * 0.98
        bridge.lineCapStyle = .round
        bridge.lineJoinStyle = .round
        bridge.move(
            to: CGPoint(
                x: leftLoopRect.midX + bounds.height * 0.08,
                y: leftLoopRect.midY + bounds.height * 0.03
            )
        )
        bridge.curve(
            to: CGPoint(
                x: rightLoopRect.midX - bounds.height * 0.08,
                y: rightLoopRect.midY + bounds.height * 0.12
            ),
            controlPoint1: CGPoint(
                x: bounds.minX + bounds.width * 0.44,
                y: bounds.minY + bounds.height * 0.60
            ),
            controlPoint2: CGPoint(
                x: bounds.minX + bounds.width * 0.58,
                y: bounds.minY + bounds.height * 0.36
            )
        )
        bridge.stroke()

        context.setBlendMode(.clear)

        NSBezierPath(
            ovalIn: CGRect(
                x: leftLoopRect.midX - holeDiameter / 2,
                y: leftLoopRect.midY - holeDiameter / 2,
                width: holeDiameter,
                height: holeDiameter
            )
        ).fill()

        NSBezierPath(
            ovalIn: CGRect(
                x: rightLoopRect.midX - holeDiameter / 2,
                y: rightLoopRect.midY - holeDiameter / 2,
                width: holeDiameter,
                height: holeDiameter
            )
        ).fill()

        context.restoreGState()
    }
}
