import UIKit

final class BrowserSceneDelegate: UIResponder, UIWindowSceneDelegate {
    // MARK: Internal

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let connection = try? await BrowserMobileSceneSessions.shared.connect(
                sessionID: session.persistentIdentifier
            ) else { return }
            guard let self, !Task.isCancelled else {
                BrowserMobileSceneSessions.shared.disconnect(connection)
                return
            }
            self.connection = connection
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = BrowserMobileViewController(
                workspace: connection.workspace,
                contentView: connection.contentView
            )
            self.window = window
            window.makeKeyAndVisible()
            connectionTask = nil
        }
    }

    func sceneDidEnterBackground(_: UIScene) {
        guard let connection else { return }
        BrowserMobileSceneSessions.shared.flush(connection)
    }

    func sceneDidDisconnect(_: UIScene) {
        connectionTask?.cancel()
        connectionTask = nil
        if let connection {
            BrowserMobileSceneSessions.shared.disconnect(connection)
        }
        connection = nil
        window = nil
    }

    // MARK: Private

    private var connection: BrowserMobileSceneSessions.Connection?
    private var connectionTask: Task<Void, Never>?
}
