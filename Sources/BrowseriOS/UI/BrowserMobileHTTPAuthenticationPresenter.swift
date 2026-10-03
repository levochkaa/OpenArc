import UIKit

/// Owns this window's transient prompt. The engine owns the challenge completion.
@MainActor final class BrowserMobileHTTPAuthenticationPresenter {
    // MARK: Lifecycle

    init(
        host: UIViewController,
        respond: @escaping (UUID, BrowserMobileHTTPAuthenticationResponse) -> Void
    ) {
        self.host = host
        self.respond = respond
    }

    // MARK: Internal

    private(set) var isTransitioning = false

    var presentedAlert: UIAlertController? { current?.alert }
    var presentedID: UUID? { current?.request.id }

    func update(_ request: BrowserMobileHTTPAuthentication?) {
        desiredRequest = request
        reconcile()
    }

    /// Shared by the installed native actions and hosted tests.
    func accept(id: UUID) {
        guard let current, current.request.id == id, !isTransitioning else { return }
        let username = current.alert.textFields?.first?.text ?? ""
        let password = current.alert.textFields?.last?.text ?? ""
        finish(current, response: .credentials(username: username, password: password))
    }

    func cancel(id: UUID) {
        guard let current, current.request.id == id, !isTransitioning else { return }
        finish(current, response: .cancel)
    }

    // MARK: Private

    private final class Presentation {
        // MARK: Lifecycle

        init(request: BrowserMobileHTTPAuthentication, alert: UIAlertController, window: UIWindow) {
            self.request = request
            self.alert = alert
            self.window = window
        }

        // MARK: Internal

        let request: BrowserMobileHTTPAuthentication
        let alert: UIAlertController
        weak var window: UIWindow?
    }

    private weak var host: UIViewController?
    private let respond: (UUID, BrowserMobileHTTPAuthenticationResponse) -> Void
    private var desiredRequest: BrowserMobileHTTPAuthentication?
    private var current: Presentation?
    private var dismissing: Presentation?

    private static func hasPresentedController(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: hasPresentedController)
    }

    private func attachedWindow() -> UIWindow? {
        guard let host, let window = host.viewIfLoaded?.window, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive else { return nil }
        var ancestor: UIViewController? = host
        while let controller = ancestor {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return nil }
            ancestor = controller.parent
        }
        return window
    }

    private func reconcile() {
        guard !isTransitioning else { return }
        if let current {
            if desiredRequest?.id != current.request.id {
                finish(current, response: nil)
            } else if attachedWindow() !== current.window {
                finish(current, response: .cancel)
            }
            return
        }
        guard let request = desiredRequest else { return }
        guard let host, let window = attachedWindow(),
              !Self.hasPresentedController(window.rootViewController ?? host)
        else {
            desiredRequest = nil
            respond(request.id, .cancel)
            return
        }

        var lines = [String(localized: "Authentication required", table: "Mobile")]
        if let realm = request.realm, !realm.isEmpty {
            // A realm is server-supplied text, never the trusted origin/title.
            let plain = realm.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && ![
                    0x061C,
                    0x200E,
                    0x200F,
                    0x202A,
                    0x202B,
                    0x202C,
                    0x202D,
                    0x202E,
                    0x2066,
                    0x2067,
                    0x2068,
                    0x2069,
                ].contains($0.value)
            }
            let bounded = String(String.UnicodeScalarView(plain)).prefix(200)
            if !bounded.isEmpty {
                lines.append(String(format: String(localized: "Realm: %@", table: "Mobile"), String(bounded)))
            }
        }
        if request.previousFailureCount > 0 {
            lines.append(String(localized: "The username or password was not accepted. Try again.", table: "Mobile"))
        }
        let alert = UIAlertController(
            title: request.origin,
            message: lines.joined(separator: "\n\n"),
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "browser.httpAuthentication"
        alert.addTextField { field in
            field.placeholder = String(localized: "Username", table: "Mobile")
            field.accessibilityLabel = field.placeholder
            field.accessibilityIdentifier = "browser.httpAuthentication.username"
            field.textContentType = .username
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
        }
        alert.addTextField { field in
            field.placeholder = String(localized: "Password", table: "Mobile")
            field.accessibilityLabel = field.placeholder
            field.accessibilityIdentifier = "browser.httpAuthentication.password"
            field.textContentType = .password
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel) {
            [weak self] _ in self?.cancel(id: request.id)
        })
        let accept = UIAlertAction(title: String(localized: "Sign In", table: "Mobile"), style: .default) {
            [weak self] _ in self?.accept(id: request.id)
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        let presentation = Presentation(request: request, alert: alert, window: window)
        current = presentation
        isTransitioning = true
        host.present(alert, animated: true) { [weak self] in
            guard let self, current === presentation else { return }
            isTransitioning = false
            if alert.presentingViewController == nil {
                finish(presentation, response: .cancel)
            } else {
                reconcile()
            }
        }
    }

    private func finish(_ presentation: Presentation, response: BrowserMobileHTTPAuthenticationResponse?) {
        guard current === presentation else { return }
        current = nil
        dismissing = presentation
        isTransitioning = true
        let alert = presentation.alert
        alert.textFields?.forEach { $0.text = nil }
        let completed = { [weak self] in
            guard let self, dismissing === presentation else { return }
            dismissing = nil
            isTransitioning = false
            let isCurrent = desiredRequest?.id == presentation.request.id
            if isCurrent {
                desiredRequest = nil
            }
            if let response {
                // Credentials leave this window only while the same prompt is
                // still wanted and its window is still active and uncovered.
                let valid = isCurrent && presentation.window != nil && attachedWindow() === presentation.window
                    && !Self.hasPresentedController(presentation.window?.rootViewController ?? alert)
                respond(presentation.request.id, valid ? response : .cancel)
            }
            reconcile()
        }
        if alert.isBeingDismissed, let transition = alert.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in completed() })
        {
            return
        }
        if alert.presentingViewController != nil {
            let animated = presentation.window?.windowScene?.activationState == .foregroundActive
            alert.dismiss(animated: animated, completion: completed)
        } else {
            completed()
        }
    }
}
