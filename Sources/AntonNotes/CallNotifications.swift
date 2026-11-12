import AppKit
import UserNotifications

final class CallNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpenMeeting: ((UUID) -> Void)?
    var onTakeNotes: (() -> Void)?
    var onError: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    func configure() {
        center.delegate = self
        let action = UNNotificationAction(identifier: "take-notes", title: "Take notes", options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "call", actions: [action], intentIdentifiers: [])])
    }
    func show() async {
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                onError?("Разрешите уведомления A-notes в настройках macOS → Уведомления")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Call detected"
            content.body = "Начать заметку и запись звонка?"
            content.categoryIdentifier = "call"
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "detected-call", content: content, trigger: nil))
        } catch { onError?("Уведомление: \(error.localizedDescription)") }
    }
    func recordingEnded(id: UUID, hasAudio: Bool, interrupted: Bool) async {
        await deliver(id: id, event: "recording-ended",
                      title: interrupted ? "Запись прервана" : "Запись завершена",
                      body: hasAudio ? "Аудио сохранено. Расшифровка поставлена в обработку." : "Аудио не записалось; расшифровка недоступна.")
    }
    func notesReady(id: UUID) async {
        await deliver(id: id, event: "notes-ready", title: "Транскрипт и саммари готовы",
                      body: "Нажмите, чтобы открыть заметки встречи.")
    }
    private func deliver(id: UUID, event: String, title: String, body: String) async {
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                onError?("Разрешите уведомления A-notes в настройках macOS → Уведомления")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["meetingID": id.uuidString]
            try await center.add(UNNotificationRequest(identifier: "\(event)-\(id)", content: content, trigger: nil))
        } catch { onError?("Уведомление: \(error.localizedDescription)") }
    }
    func clear() {
        center.removeDeliveredNotifications(withIdentifiers: ["detected-call"])
        center.removePendingNotificationRequests(withIdentifiers: ["detected-call"])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["meetingID"] as? String,
           let id = UUID(uuidString: value), response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onOpenMeeting?(id) }
        } else if response.notification.request.content.categoryIdentifier == "call",
                  response.actionIdentifier == "take-notes" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onTakeNotes?() }
        }
        completionHandler()
    }
}
