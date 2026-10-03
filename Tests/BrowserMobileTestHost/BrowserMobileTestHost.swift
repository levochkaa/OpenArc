import UIKit

// MARK: - BrowserMobileTestScene

/// The test process supplies a real scene without bootstrapping the browser.
@MainActor public enum BrowserMobileTestScene {
    public fileprivate(set) weak static var windowScene: UIWindowScene?
}

// MARK: - BrowserMobileTestHostAppDelegate

@main final class BrowserMobileTestHostAppDelegate: UIResponder, UIApplicationDelegate {}

// MARK: - BrowserMobileTestHostSceneDelegate

final class BrowserMobileTestHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        BrowserMobileTestScene.windowScene = windowScene
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if BrowserMobileTestScene.windowScene === scene {
            BrowserMobileTestScene.windowScene = nil
        }
        window = nil
    }
}
