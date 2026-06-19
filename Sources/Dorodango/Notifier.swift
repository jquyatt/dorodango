import Foundation
import UserNotifications

/// Posts user notifications attributed to Dorodango itself (via UserNotifications)
/// instead of through osascript, which would show the generic AppleScript icon.
/// Falls back to osascript only when running outside a real app bundle (e.g.
/// `swift run`), where UNUserNotificationCenter isn't available.
enum Notifier {

    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, subtitle: String, body: String) {
        if hasBundle {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            let script = "display notification \"\(body)\" with title \"\(title)\" subtitle \"\(subtitle)\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}
