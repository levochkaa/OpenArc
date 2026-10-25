// BrowserMobileAppleSignInService.swift

import AuthenticationServices
import UIKit

// MARK: - BrowserMobileAppleAuthorizationRequest

@MainActor protocol BrowserMobileAppleAuthorizationRequest: AnyObject {
    func start(completion: @escaping @MainActor (Result<String, Error>) -> Void)
    func cancel()
}

// MARK: - BrowserMobileAppleSignInService

@MainActor final class BrowserMobileAppleSignInService: NSObject, BrowserAppleIdentityProviding {
    // MARK: Private

    private struct Pending {
        let id: UUID
        let window: UIWindow
        let request: any BrowserMobileAppleAuthorizationRequest
        let continuation: CheckedContinuation<String, Error>
    }

    private weak var presentationWindow: UIWindow?
    private let requestFactory: @MainActor (UIWindow) -> any BrowserMobileAppleAuthorizationRequest
    private var pending: Pending?

    init(requestFactory: (@MainActor (UIWindow) -> any BrowserMobileAppleAuthorizationRequest)? = nil) {
        self.requestFactory = requestFactory ?? { BrowserMobileNativeAppleAuthorizationRequest(window: $0) }
        super.init()
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: name,
                object: nil,
            )
        }
    }

    // MARK: Internal

    func setPresentationWindow(_ window: UIWindow?) {
        if presentationWindow !== window {
            cancel()
        }
        presentationWindow = window
    }

    func requestIdentityToken() async throws -> String {
        guard pending == nil else { throw BrowserMobileAppleSignInError.requestInProgress }
        guard let window = presentationWindow, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive
        else { throw BrowserMobileAppleSignInError.inactiveWindow }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = requestFactory(window)
                pending = Pending(id: id, window: window, request: request, continuation: continuation)
                request.start { [weak self] result in self?.finish(id: id, result: result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func cancel() {
        guard let id = pending?.id else { return }
        cancel(id: id)
    }

    private func cancel(id: UUID) {
        guard let attempt = pending, attempt.id == id else { return }
        pending = nil
        attempt.request.cancel()
        attempt.continuation.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard let attempt = pending, attempt.id == id else { return }
        pending = nil
        attempt.continuation.resume(with: result)
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === pending?.window.windowScene else { return }
        cancel()
    }
}

// MARK: - BrowserMobileAppleSignInError

enum BrowserMobileAppleSignInError: LocalizedError {
    case inactiveWindow
    case requestInProgress

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .inactiveWindow:
            NSLocalizedString("Open this window to sign in.", tableName: "Mobile", comment: "Inactive sign-in window")
        case .requestInProgress:
            NSLocalizedString("Sign-in is already in progress.", tableName: "Mobile", comment: "Duplicate sign-in")
        }
    }
}

// MARK: - BrowserMobileNativeAppleAuthorizationRequest

@MainActor private final class BrowserMobileNativeAppleAuthorizationRequest: NSObject,
    BrowserMobileAppleAuthorizationRequest, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    // MARK: Private

    private let window: UIWindow
    private var controller: ASAuthorizationController?
    private var completion: (@MainActor (Result<String, Error>) -> Void)?

    init(window: UIWindow) {
        self.window = window
        super.init()
    }

    // MARK: Internal

    func start(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        self.completion = completion
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email, .fullName]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func cancel() {
        completion = nil
        controller?.cancel()
        controller = nil
    }

    func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor { window }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization,
    ) {
        guard controller === self.controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else {
            finish(.failure(BrowserAppleSignInError.missingIdentityToken))
            return
        }
        finish(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        let callback = completion
        completion = nil
        controller = nil
        callback?(result)
    }
}
