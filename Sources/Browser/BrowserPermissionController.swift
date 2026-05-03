import AppKit
import Foundation
import UserNotifications

@objcMembers public final class BrowserPermissionController: NSObject {
    // MARK: Public

    public static func requestNotificationPermission(for origin: String, completion: @escaping (Bool) -> Void) {
        let handlePromptResponse = {
            let response = presentSitePrompt(for: origin)
            guard response == .alertFirstButtonReturn else {
                completion(false)
                return
            }

            requestSystemNotificationAuthorization(completion: completion)
        }

        if Thread.isMainThread {
            handlePromptResponse()
            return
        }

        DispatchQueue.main.sync(execute: handlePromptResponse)
    }

    // MARK: Private

    private static func presentSitePrompt(for origin: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.notificationPermissionTitle
        alert.informativeText = BrowserStrings.notificationPermissionMessage(origin: origin)
        alert.addButton(withTitle: BrowserStrings.notificationPermissionAllow)
        alert.addButton(withTitle: BrowserStrings.notificationPermissionDontAllow)
        alert.alertStyle = .informational
        return alert.runModal()
    }

    private static func requestSystemNotificationAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(true)
            case .denied:
                completion(false)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    completion(granted)
                }
            @unknown default:
                completion(false)
            }
        }
    }
}
