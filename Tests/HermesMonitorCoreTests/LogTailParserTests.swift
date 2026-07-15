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

    func testDownloadedTailIsCappedToFinal64KiB() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = directory.appendingPathComponent("transfer")
        let installed = directory.appendingPathComponent("installed")
        let payload = Data(repeating: 0x61, count: 80 * 1_024)
        try payload.write(to: transfer)
        let byteLimit = 64 * 1_024
        let offset = UInt64(payload.count - byteLimit)

        try OpenSSHTransport.installDownloadedTail(
            from: transfer,
            offset: offset,
            byteLimit: byteLimit,
            to: installed
        )

        let result = try Data(contentsOf: installed)
        XCTAssertEqual(result.count, byteLimit)
        XCTAssertEqual(result, payload.suffix(byteLimit))
    }

    func testDownloadedTailReplacesCacheAfterRotationOrTruncation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = directory.appendingPathComponent("transfer")
        let installed = directory.appendingPathComponent("installed")
        try Data("old worker output\n".utf8).write(to: installed)
        let rotated = Data("new process\n".utf8)
        try rotated.write(to: transfer)

        try OpenSSHTransport.installDownloadedTail(
            from: transfer,
            offset: 0,
            byteLimit: 64 * 1_024,
            to: installed
        )

        XCTAssertEqual(try Data(contentsOf: installed), rotated)
    }
}
