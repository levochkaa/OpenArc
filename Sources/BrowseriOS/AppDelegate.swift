// AppDelegate.swift

import UIKit

@main final class BrowserMobileAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        BrowserMobileContentBlocking.start()
        return true
    }

    func application(_: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        BrowserMobileSceneSessions.shared.discard(sessionIDs: Set(sceneSessions.map(\.persistentIdentifier)))
    }
}
