import XCTest
@testable import HermesMonitorCore

final class LogTailParserTests: XCTestCase {
    func testReturnsLastNonEmptyLinesWithoutLoadingTextSemanticsIntoTransport() {
        let data = Data("one\ntwo\nthree\nfour\n".utf8)

        XCTAssertEqual(LogTailParser.lines(from: data, limit: 2), ["three", "four"])
        XCTAssertEqual(LogTailParser.lines(from: data, limit: 0), [])
    }

    func testPreservesIntentionalBlankLinesInsideTail() {
        let data = Data("one\n\nthree\n".utf8)

        XCTAssertEqual(LogTailParser.lines(from: data, limit: 3), ["one", "", "three"])
    }
}
