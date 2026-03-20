import AppKit
import XCTest
@testable import PasteBin

final class StatusBarIconRendererTests: XCTestCase {
    func testMenuBarIconUsesTransparentCanvas() {
        guard let image = StatusBarIconRenderer.makeMenuBarImage(sideLength: 16) else {
            XCTFail("Expected a status bar image")
            return
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data else {
            XCTFail("Expected a bitmap-backed status bar image")
            return
        }

        let bytes = CFDataGetBytePtr(pixelData)!
        let bytesPerRow = cgImage.bytesPerRow

        func alphaAt(x: Int, y: Int) -> UInt8 {
            let offset = (y * bytesPerRow) + (x * 4) + 3
            return bytes[offset]
        }

        let width = cgImage.width
        let height = cgImage.height

        XCTAssertEqual(alphaAt(x: 0, y: 0), 0)
        XCTAssertEqual(alphaAt(x: width - 1, y: 0), 0)
        XCTAssertEqual(alphaAt(x: 0, y: height - 1), 0)
        XCTAssertEqual(alphaAt(x: width - 1, y: height - 1), 0)

        var opaquePixelCount = 0
        for y in 0..<height {
            for x in 0..<width {
                if alphaAt(x: x, y: y) > 0 {
                    opaquePixelCount += 1
                }
            }
        }

        XCTAssertGreaterThan(opaquePixelCount, (width * height) / 8)
    }
}
