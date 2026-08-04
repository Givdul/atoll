import Foundation
import XCTest
@testable import TopsideCore

final class DateParsingTests: XCTestCase {
    func testParsesNumericSecondsMillisecondsAndStrings() {
        XCTAssertEqual(
            DateParsing.date(from: NSNumber(value: 1_700_000_000)),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            DateParsing.date(from: NSNumber(value: 1_700_000_000_000)),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            DateParsing.date(from: "1700000000"),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testParsesFractionalAndPlainISO8601() {
        XCTAssertNotNil(DateParsing.date(from: "2026-08-01T12:34:56.123Z"))
        XCTAssertNotNil(DateParsing.date(from: "2026-08-01T12:34:56Z"))
    }

    func testRejectsNonPositiveAndInvalidValues() {
        XCTAssertNil(DateParsing.date(from: 0 as NSNumber))
        XCTAssertNil(DateParsing.date(from: -1 as NSNumber))
        XCTAssertNil(DateParsing.date(from: "not-a-date"))
        XCTAssertNil(DateParsing.date(from: nil))
    }
}
