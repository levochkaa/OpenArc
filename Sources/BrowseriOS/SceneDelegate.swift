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
            links.forEach(connection.workspace.openLinkFromAnotherApp)
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
        links.forEach(connection.workspace.openLinkFromAnotherApp)
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
}
