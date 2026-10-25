// BrowserMobileJavaScriptDialogPresenter.swift

import UIKit

/// Owns only this window's page alert. WebKit owns the response token.
@MainActor final class BrowserMobileJavaScriptDialogPresenter {
    // MARK: Internal

    private(set) var presentedAlert: UIAlertController?
    private(set) var presentedID: UUID?
    private(set) var isTransitioning = false

    // MARK: Private

    private weak var host: UIViewController?
    private let respond: (UUID, BrowserMobileJavaScriptDialogResponse) -> Void
    private var desiredRequest: BrowserMobileJavaScriptDialog?

    init(
        host: UIViewController,
        respond: @escaping (UUID, BrowserMobileJavaScriptDialogResponse) -> Void,
    ) {
        self.host = host
        self.respond = respond
    }

    private static func hasPresentedController(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: hasPresentedController)
    }

    func update(_ request: BrowserMobileJavaScriptDialog?) {
        desiredRequest = request
        reconcile()
    }

    /// The native actions and tests use the same response paths.
    func accept(id: UUID) {
        guard presentedID == id, !isTransitioning, let alert = presentedAlert else { return }
        finish(id: id, response: .accept(text: alert.textFields?.first?.text))
    }

    func cancel(id: UUID) {
        guard presentedID == id, !isTransitioning else { return }
        finish(id: id, response: .cancel)
    }

    private func reconcile() {
        guard !isTransitioning else { return }
        if let presentedID {
            if desiredRequest?.id != presentedID {
                // The engine already completed this token on navigation,
                // selection or scene deactivation. Only dismiss our own UI.
                finish(id: presentedID, response: nil)
            }
            return
        }
        guard let request = desiredRequest else { return }
        guard let host, let window = host.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              !window.isHidden, !host.isBeingDismissed, !Self.hasPresentedController(host)
        else {
            desiredRequest = nil
            respond(request.id, .cancel)
            return
        }

        // The origin is supplied by WKFrameInfo, not page-controlled title text.
        let alert = UIAlertController(title: request.origin, message: request.message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "browser.javascriptDialog"
        if case .prompt(let defaultText) = request.kind {
            alert.addTextField { field in
                field.text = defaultText
                field.accessibilityLabel = String(localized: "Response", table: "Mobile")
                field.accessibilityIdentifier = "browser.javascriptDialog.response"
                field.autocorrectionType = .no
                field.autocapitalizationType = .none
            }
        }
        if request.kind != .alert {
            alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel) {
                [weak self] _ in self?.cancel(id: request.id)
            })
        }
        let accept = UIAlertAction(title: String(localized: "OK", table: "Mobile"), style: .default) {
            [weak self] _ in self?.accept(id: request.id)
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        presentedAlert = alert
        presentedID = request.id
        isTransitioning = true
        host.present(alert, animated: true) { [weak self, weak alert] in
            guard let self, presentedID == request.id else { return }
            isTransitioning = false
            if alert?.presentingViewController == nil {
                finish(id: request.id, response: .cancel)
            } else {
                reconcile()
            }
        }
    }

    private func finish(id: UUID, response: BrowserMobileJavaScriptDialogResponse?) {
        guard presentedID == id, let alert = presentedAlert else { return }
        if desiredRequest?.id == id {
            desiredRequest = nil
        }
        presentedID = nil
        presentedAlert = nil
        isTransitioning = true
        var didComplete = false
        let completed = { [weak self] in
            guard let self, !didComplete else { return }
            didComplete = true
            isTransitioning = false
            // Finish the native dismissal before resuming page JavaScript:
            // a sequential alert can now present without colliding with it.
            if let response {
                respond(id, response)
            }
            reconcile()
        }
        if alert.isBeingDismissed, let transition = alert.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in completed() })
        {
            return
        }
        if alert.presentingViewController != nil {
            let animated = host?.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            alert.dismiss(animated: animated, completion: completed)
        } else {
            completed()
        }
    }
}
