// BrowserMobileWebSignInService.swift

import AuthenticationServices
import UIKit

// MARK: - BrowserMobileSignInWindowAnchoring

/// A sign-in service that presents over the window the user started from.
@MainActor protocol BrowserMobileSignInWindowAnchoring: AnyObject {
    func setPresentationWindow(_ window: UIWindow?)
}

// MARK: - BrowserMobileAppleSignInService + BrowserMobileSignInWindowAnchoring

extension BrowserMobileAppleSignInService: BrowserMobileSignInWindowAnchoring {}

// MARK: - BrowserMobileWebAuthenticationRequest

@MainActor protocol BrowserMobileWebAuthenticationRequest: AnyObject {
    /// Calls `completion` with the callback URL, or fails when it could not start.
    func start(completion: @escaping @MainActor (Result<URL, Error>) -> Void)
    func cancel()
}

// MARK: - BrowserMobileWebSignInService

/// Runs a provider's sign-in page in an ASWebAuthenticationSession anchored to
/// the caller's window. A custom-scheme callback is caught by the session
/// itself, so the scheme needs no URL type in Info.plist.
@MainActor final class BrowserMobileWebSignInService: NSObject, BrowserWebSignInPresenting,
    BrowserMobileSignInWindowAnchoring
{
    // MARK: Private

    private struct Pending {
        let id: UUID
        let window: UIWindow
        let request: any BrowserMobileWebAuthenticationRequest
        let continuation: CheckedContinuation<URL, Error>
    }

    private typealias RequestFactory = @MainActor (URL, String, UIWindow) -> any BrowserMobileWebAuthenticationRequest

    private weak var presentationWindow: UIWindow?
    private let requestFactory: RequestFactory
    private var pending: Pending?

    init(
        requestFactory: (@MainActor (URL, String, UIWindow) -> any BrowserMobileWebAuthenticationRequest)? = nil,
    ) {
        self.requestFactory = requestFactory ?? {
            BrowserMobileNativeWebAuthenticationRequest(url: $0, callbackScheme: $1, window: $2)
        }
        super.init()
        // A system sign-in sheet makes the scene inactive, so only leaving the
        // foreground or closing the scene ends the attempt.
        for name in [UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneLeftForeground(_:)),
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

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        guard let window = presentationWindow, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive
        else { throw BrowserMobileAppleSignInError.inactiveWindow }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = requestFactory(url, callbackScheme, window)
                pending = Pending(id: id, window: window, request: request, continuation: continuation)
                request.start { [weak self] result in self?.finish(id: id, result: result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// Closes a running sign-in page, which ends the sign-in as cancelled.
    func cancel() {
        guard let id = pending?.id else { return }
        cancel(id: id)
    }

    private func cancel(id: UUID) {
        guard let attempt = pending, attempt.id == id else { return }
        pending = nil
        attempt.request.cancel()
        attempt.continuation.resume(throwing: BrowserWebSignInError.cancelled)
    }

    private func finish(id: UUID, result: Result<URL, Error>) {
        guard let attempt = pending, attempt.id == id else { return }
        pending = nil
        attempt.continuation.resume(with: result)
    }

    @objc private func sceneLeftForeground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === pending?.window.windowScene else { return }
        cancel()
    }
}

// MARK: - BrowserMobileNativeWebAuthenticationRequest

@MainActor private final class BrowserMobileNativeWebAuthenticationRequest: NSObject,
    BrowserMobileWebAuthenticationRequest, ASWebAuthenticationPresentationContextProviding
{
    // MARK: Private

    private let url: URL
    private let callbackScheme: String
    private let window: UIWindow
    private var session: ASWebAuthenticationSession?

    init(url: URL, callbackScheme: String, window: UIWindow) {
        self.url = url
        self.callbackScheme = callbackScheme
        self.window = window
        super.init()
    }

    // MARK: Internal

    func start(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(callbackScheme),
            // AuthenticationServices calls back on its own queue, never the main
            // one: the handler must not inherit the main actor, or Swift traps.
        ) { @Sendable callbackURL, error in
            Task { @MainActor in
                if let callbackURL {
                    completion(.success(callbackURL))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    completion(.failure(BrowserWebSignInError.cancelled))
                } else {
                    completion(.failure(error ?? BrowserWebSignInError.cancelled))
                }
            }
        }
        session.presentationContextProvider = self
        self.session = session
        if !session.start() {
            self.session = nil
            completion(.failure(BrowserAccountSignInError.providerFailed))
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
