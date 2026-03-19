import XCTest
@testable import PasteBin

final class ClipboardStoreTests: XCTestCase {
    func testPreferredSelectionRestoreUsesNextVisibleItem() {
        XCTAssertEqual(
            ClipboardStore.preferredSelectionRestoreItemID(
                afterRemovingItemAt: 1,
                from: [11, 22, 33, 44]
            ),
            33
        )
    }

    func testPreferredSelectionRestoreFallsBackToPreviousVisibleItem() {
        XCTAssertEqual(
            ClipboardStore.preferredSelectionRestoreItemID(
                afterRemovingItemAt: 2,
                from: [11, 22, 33]
            ),
            22
        )
    }

    func testPreferredSelectionRestoreReturnsNilWhenListBecomesEmpty() {
        XCTAssertNil(
            ClipboardStore.preferredSelectionRestoreItemID(
                afterRemovingItemAt: 0,
                from: [11]
            )
        )
    }
}
