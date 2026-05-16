import Foundation
import UserNotifications

final class NotificationService {
    func notifyStarIncrease(delta: Int, stars: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "GitHub stars increased"
            content.body = "+\(delta) stars. Total: \(stars)."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

