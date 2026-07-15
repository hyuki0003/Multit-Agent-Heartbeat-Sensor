import Foundation
import XCTest
@testable import HermesMonitorCore

final class ManualSessionLinkStoreTests: XCTestCase {
    func testDefaultFileUsesRequiredManualLinksName() {
        XCTAssertEqual(
            ManualSessionLinkStore.defaultFileURL().lastPathComponent,
            "manual_links.json"
        )
    }

    func testMissingFileLoadsAsEmptyAndSavedLinksRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManualSessionLinkStore(
            fileURL: directory.appendingPathComponent("manual_links.json")
        )

        XCTAssertEqual(try store.load(), [:])

        let links = ["t_2": "session-b", "t_1": "session-a"]
        try store.save(links)

        XCTAssertEqual(try store.load(), links)
    }
}