import Foundation
import HermesMonitorCore
import UserNotifications

@MainActor
final class TaskNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let soundPlayer: any DeathSoundPlaying
    private let onTaskSelected: (String) -> Void
    private var detector = TaskNotificationDetector(deduplicationWindow: 60)

    init(
        center: UNUserNotificationCenter = .current(),
        soundPlayer: (any DeathSoundPlaying)? = nil,
        onTaskSelected: @escaping (String) -> Void
    ) {
        self.center = center
        self.soundPlayer = soundPlayer ?? DeathSoundPlayer()
        self.onTaskSelected = onTaskSelected
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func process(
        snapshot: HermesMonitorSnapshot,
        preferences: TaskNotificationPreferences
    ) {
        let events = detector.events(
            for: snapshot,
            at: snapshot.refreshedAt,
            preferences: preferences
        )
        for event in events {
            if preferences.shouldPlayDeathSound(for: event.kind) {
                soundPlayer.playDeathSound()
            }
            deliver(event)
        }
    }

    private func deliver(_ event: TaskNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.taskTitle
        content.body = body(for: event.kind)
        content.sound = event.kind.playsDeathSound ? nil : .default
        content.userInfo = ["taskID": event.taskID]

        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let identifier = "hermes.\(event.deduplicationKey).\(timestamp)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func body(for kind: TaskNotificationKind) -> String {
        switch kind {
        case .blocked:
            return "Status changed from running to blocked."
        case .completed:
            return "Status changed from running to done."
        case .failed:
            return "The running task failed or crashed."
        case .heartbeatStale:
            return "The running task heartbeat is at least 180 seconds old."
        case .created:
            return "A new Hermes task was created."
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            self?.onTaskSelected(taskID)
        }
        completionHandler()
    }
}
