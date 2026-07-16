import Foundation
import XCTest
@testable import HermesMonitorCore

final class NotificationAvailabilityPolicyTests: XCTestCase {
    func testRejectsUnbundledSwiftPMExecutable() {
        let executableBundleURL = URL(
            fileURLWithPath: "/workspace/.build/arm64-apple-macosx/debug",
            isDirectory: true
        )

        XCTAssertFalse(
            NotificationAvailabilityPolicy.isAvailable(
                processBundleURL: executableBundleURL,
                bundleIdentifier: nil
            )
        )
    }

    func testAllowsIdentifiedApplicationBundle() {
        let applicationBundleURL = URL(
            fileURLWithPath: "/Applications/HermesMonitor.app",
            isDirectory: true
        )

        XCTAssertTrue(
            NotificationAvailabilityPolicy.isAvailable(
                processBundleURL: applicationBundleURL,
                bundleIdentifier: "com.example.HermesMonitor"
            )
        )
    }
}
