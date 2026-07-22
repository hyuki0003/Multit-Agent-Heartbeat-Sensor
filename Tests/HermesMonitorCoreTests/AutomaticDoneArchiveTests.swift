import Foundation
import XCTest
@testable import HermesMonitorCore

final class AutomaticDoneArchiveTests: XCTestCase {
    func testPreferenceDefaultsOffAndReadsPersistedChoice() {
        let suiteName = "AutomaticDoneArchiveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AutomaticDoneArchivePreference.load(defaults: defaults))

        defaults.set(true, forKey: AutomaticDoneArchivePreference.automaticallyRemoveDoneTasks)

        XCTAssertTrue(AutomaticDoneArchivePreference.load(defaults: defaults))
    }
}
