import XCTest
@testable import PasteBin

final class ClipboardContentLimitsTests: XCTestCase {
    func testTruncateUTF8PreservingScalarBoundariesDoesNotSplitEmoji() {
        let value = "A🙂B"

        XCTAssertEqual(
            ClipboardContentLimits.truncateUTF8PreservingScalarBoundaries(value, to: 4),
            "A"
        )
        XCTAssertEqual(
            ClipboardContentLimits.truncateUTF8PreservingScalarBoundaries(value, to: 5),
            "A🙂"
        )
    }

    func testSearchProjectionKeepsPrefixAndSuffixForLongValues() {
        let prefix = String(repeating: "a", count: 80)
        let suffix = String(repeating: "z", count: 80)
        let value = prefix + String(repeating: "m", count: 400) + suffix

        let projected = ClipboardContentLimits.searchProjection(value, to: 120)

        XCTAssertTrue(projected.contains("\n...\n"))
        XCTAssertTrue(projected.hasPrefix(String(prefix.prefix(20))))
        XCTAssertTrue(projected.hasSuffix(String(suffix.suffix(20))))
        XCTAssertLessThanOrEqual(projected.utf8.count, 120)
    }

    func testCappedTextStaysWithinStorageLimitAndAddsNotice() {
        let oversized = String(repeating: "x", count: ClipboardContentLimits.maxStoredTextUTF8Bytes + 256)

        let capped = ClipboardContentLimits.cappedText(oversized)

        XCTAssertLessThanOrEqual(capped.utf8.count, ClipboardContentLimits.maxStoredTextUTF8Bytes)
        XCTAssertTrue(capped.contains("PasteBin truncated this item"))
    }

    func testUnlimitedRetentionDoesNotPrune() {
        XCTAssertNil(HistoryRetentionPeriod.unlimited.cutoffDate(referenceDate: Date(timeIntervalSince1970: 0)))
    }

    func testLegacyCodeRowsResolveAsPlainText() {
        let item = ClipItem(
            id: 1,
            content: "let value = 42",
            copiedAt: Date(timeIntervalSince1970: 0),
            sourceBundleID: nil,
            sourceAppName: nil,
            contentTypeRaw: "code",
            codeLanguage: "swift"
        )

        XCTAssertEqual(item.contentType, .text)
        XCTAssertEqual(item.typeLabel, "Text")
        XCTAssertEqual(item.previewText, "let value = 42")
    }
}
