import Foundation

public enum NotificationAvailabilityPolicy {
    public static func isAvailable(
        processBundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        guard processBundleURL.pathExtension.lowercased() == "app",
              let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}
