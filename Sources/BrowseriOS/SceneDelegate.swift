// SceneDelegate.swift

import UIKit

final class BrowserSceneDelegate: UIResponder, UIWindowSceneDelegate {
    // MARK: Internal

    var window: UIWindow?

    // MARK: Private

    private var connection: BrowserMobileSceneSessions.Connection?
    private var connectionTask: Task<Void, Never>?
    private weak var connectionScene: UIWindowScene?
    /// Links handed over while the scene's workspace is still connecting.
    private var pendingLinks = [URL]()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        pendingLinks = options.urlContexts.map(\.url)
        if let action = options.shortcutItem.flatMap({ BrowserMobileAppLink(rawValue: $0.type) }) {
            pendingLinks.append(action.url)
        }
        connectionTask?.cancel()
        if let connection {
            BrowserMobileSceneSessions.shared.disconnect(connection)
        }
        connection = nil
        window = nil
        connectionScene = windowScene
        connectionTask = Task { [weak self] in
            guard let connection = try? await BrowserMobileSceneSessions.shared.connect(
                sessionID: session.persistentIdentifier,
            ) else { return }
            guard let self, !Task.isCancelled, connectionScene === windowScene else {
                BrowserMobileSceneSessions.shared.disconnect(connection)
                return
            }
            self.connection = connection
            let window = UIWindow(windowScene: windowScene)
            // A phone gets the bottom-bar browser; iPad keeps the sidebar.
            window.rootViewController = windowScene.traitCollection.userInterfaceIdiom == .phone
                ? BrowserMobilePhoneViewController(
                    workspace: connection.workspace, contentView: connection.contentView,
                )
                : BrowserMobileViewController(
                    workspace: connection.workspace, contentView: connection.contentView,
                )
            self.window = window
            window.makeKeyAndVisible()
            BrowserMobileSceneSessions.shared.setActive(
                windowScene.activationState == .foregroundActive,
                for: connection,
            )
            connectionTask = nil
            let links = pendingLinks
            pendingLinks = []
            open(links, in: connection)
            if links.isEmpty, let root = window.rootViewController {
                DispatchQueue.main.async {
                    BrowserMobileOnboardingViewController.presentIfNeeded(over: root)
                }
            }
        }
    }

    /// As the default browser, OpenArc receives the http and https links other apps open.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard connectionScene === scene else { return }
        let links = URLContexts.map(\.url)
        guard let connection else {
            pendingLinks += links
            return
        }
        open(links, in: connection)
    }

    /// The app icon's quick actions: Search, Voice Search and Change App Icon.
    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void,
    ) {
        guard connectionScene === windowScene, let link = BrowserMobileAppLink(rawValue: shortcutItem.type) else {
            return completionHandler(false)
        }
        if let connection {
            open([link.url], in: connection)
        } else {
            pendingLinks.append(link.url)
        }
        completionHandler(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard connectionScene === scene, let connection else { return }
        BrowserMobileSceneSessions.shared.setActive(true, for: connection)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard connectionScene === scene, let connection else { return }
        BrowserMobileSceneSessions.shared.setActive(false, for: connection)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard connectionScene === scene, let connection else { return }
        BrowserMobileSceneSessions.shared.setActive(false, for: connection)
        BrowserMobileSceneSessions.shared.flush(connection)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard connectionScene === scene else { return }
        connectionTask?.cancel()
        connectionTask = nil
        if let connection {
            BrowserMobileSceneSessions.shared.disconnect(connection)
        }
        connection = nil
        connectionScene = nil
        pendingLinks = []
        window = nil
    }

    /// Web links open as pages; the widget's `openarc://` links go to the browser's controller.
    private func open(_ links: [URL], in connection: BrowserMobileSceneSessions.Connection) {
        for url in links {
            if let link = BrowserMobileAppLink(url: url) {
                switch window?.rootViewController {
                case let phone as BrowserMobilePhoneViewController: phone.open(link)
                case let pad as BrowserMobileViewController: pad.open(link)
                default: break
                }
            } else {
                connection.workspace.openLinkFromAnotherApp(url)
            }
        }
    }
}
