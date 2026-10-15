import UserNotifications

/// Banners for what happens to an upload while no window watches it: a pause,
/// or a resume at launch. A refusal changes nothing else — the window and the
/// menu still show where every upload stands.
final class UploadNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asked at the first upload rather than at launch: by then the user knows
    /// what the banners will be about. The system only ever asks once.
    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A menu bar app counts as frontmost often enough that, without this, its
    /// banners would be swallowed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
