import XCTest

@testable import PrimeRadiant

/// The stream carries structured-output JSON; `say` must still render live.
final class SayStreamExtractorTests: XCTestCase {

    func testExtractsSayAcrossDeltas() {
        var extractor = SayStreamExtractor()
        XCTAssertNil(extractor.consume("{\"sa"))
        XCTAssertNil(extractor.consume("y\": \""))
        XCTAssertEqual(extractor.consume("hel"), "hel")
        XCTAssertEqual(extractor.consume("lo"), "lo")
        // Literal closes; trailing JSON is not prose.
        XCTAssertNil(extractor.consume("\", \"patch\": null}"))
    }

    func testDecodesEscapes() {
        var extractor = SayStreamExtractor()
        let fresh = extractor.consume(#"{"say": "a\nb \"q\" é"#)
        XCTAssertEqual(fresh, "a\nb \"q\" é")
    }

    func testDanglingEscapeWaitsForMoreInput() {
        var extractor = SayStreamExtractor()
        XCTAssertEqual(extractor.consume(#"{"say": "ab\"#), "ab")
        XCTAssertEqual(extractor.consume(#"nc"#), "\nc")
    }

    func testNoSayKeyYieldsNothing() {
        var extractor = SayStreamExtractor()
        XCTAssertNil(extractor.consume("{\"patch\": ["))
    }
}
