import Foundation
import XCTest
@testable import Holoscape

final class ScrollbackMaintenanceFormattingTests: XCTestCase {

    // MARK: - byteSize

    func testByteSizeZeroAndBytes() {
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(0), "0 B")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(1), "1 B")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(512), "512 B")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(1023), "1023 B")
    }

    func testByteSizeKilobytes() {
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(1024), "1 KB")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(1536), "1.5 KB")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(2048), "2 KB")
    }

    func testByteSizeMegabytesAndGigabytes() {
        let kb = 1024
        let mb = 1024 * kb
        let gb = 1024 * mb
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(mb), "1 MB")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(3 * mb + 200 * kb), "3.2 MB")
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(gb), "1 GB")
    }

    func testByteSizeNegativeClampsToZero() {
        XCTAssertEqual(ScrollbackMaintenanceFormatting.byteSize(-5), "0 B")
    }

    // MARK: - modifiedAt

    func testModifiedAtNilIsEmDash() {
        XCTAssertEqual(ScrollbackMaintenanceFormatting.modifiedAt(nil), "—")
    }

    func testModifiedAtUsesFixedFormatAndInjectedTimeZone() throws {
        // 2024-03-09 14:05:00 UTC.
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 9
        components.hour = 14
        components.minute = 5
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else {
            return XCTFail("Failed to construct test date")
        }

        XCTAssertEqual(
            ScrollbackMaintenanceFormatting.modifiedAt(date, timeZone: TimeZone(secondsFromGMT: 0)!),
            "2024-03-09 14:05"
        )
    }

    func testModifiedAtHonorsInjectedTimeZoneOffset() throws {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 30
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else {
            return XCTFail("Failed to construct test date")
        }

        // +02:00 should render 02:30.
        XCTAssertEqual(
            ScrollbackMaintenanceFormatting.modifiedAt(date, timeZone: TimeZone(secondsFromGMT: 2 * 3600)!),
            "2024-01-01 02:30"
        )
    }
}
