// BrowserPermissionController.swift

import AppKit
import Foundation

@objcMembers public final class BrowserPermissionController: NSObject {
    // MARK: Public

    public static func requestNotificationPermission(
        for origin: String,
        completion: @escaping @Sendable (Bool) -> Void,
    ) {
        let handlePromptResponse: @MainActor () -> Void = {
            let response = presentSitePrompt(for: origin)
            guard response == .alertFirstButtonReturn else {
                completion(false)
                return
            }

            requestSystemNotificationAuthorization(completion: completion)
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handlePromptResponse()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                handlePromptResponse()
            }
        }
    }

    // MARK: Private

    @MainActor private static func presentSitePrompt(for origin: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.notificationPermissionTitle
        alert.informativeText = BrowserStrings.notificationPermissionMessage(origin: origin)
        alert.addButton(withTitle: BrowserStrings.notificationPermissionAllow)
        alert.addButton(withTitle: BrowserStrings.notificationPermissionDontAllow)
        alert.alertStyle = .informational
        return alert.runModal()
    }

    private static func requestSystemNotificationAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        BrowserNotificationAuthorization.request { completion($0 == .allowed) }
    }
}
