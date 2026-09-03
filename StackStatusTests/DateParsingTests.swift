import XCTest
@testable import StackStatus

final class DateParsingTests: XCTestCase {
    func testISO8601WithFractionalSeconds() {
        let d = DateParsing.parse("2026-09-03T19:28:46.884Z")
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1_788_463_726.884, accuracy: 0.001)
    }

    func testISO8601WithoutFractionalSeconds() {
        XCTAssertEqual(DateParsing.parse("2026-07-09T19:25:56Z")?.timeIntervalSince1970, 1_783_625_156)
    }

    func testISO8601WithOffset() {
        XCTAssertEqual(DateParsing.parse("2026-09-03T20:12:42+00:00")?.timeIntervalSince1970, 1_788_466_362)
    }

    func testRFC822() {
        XCTAssertEqual(DateParsing.parse("Thu, 03 Sep 2026 20:53:00 GMT")?.timeIntervalSince1970, 1_788_468_780)
        XCTAssertEqual(DateParsing.parse("Thu, 03 Sep 2026 20:53:00 +0000")?.timeIntervalSince1970, 1_788_468_780)
    }

    func testMicrosoftTrailingZ() {
        XCTAssertEqual(DateParsing.parse("Thu, 03 Sep 2026 20:53:00 Z")?.timeIntervalSince1970, 1_788_468_780)
    }

    func testGarbage() {
        XCTAssertNil(DateParsing.parse(nil))
        XCTAssertNil(DateParsing.parse(""))
        XCTAssertNil(DateParsing.parse("yesterday"))
    }
}
