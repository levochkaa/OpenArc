import UIKit

@main final class BrowserMobileAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        BrowserMobileSceneSessions.shared.discard(sessionIDs: Set(sceneSessions.map(\.persistentIdentifier)))
    }
}
