// BrowserAppleSignInService.swift

import AppKit
import AuthenticationServices
import Foundation

// MARK: - BrowserAppleSignInService

@MainActor final class BrowserAppleSignInService: NSObject, BrowserAppleIdentityProviding {
    // MARK: Private

    private var continuation: CheckedContinuation<String, Error>?

    // MARK: Internal

    func requestIdentityToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

// MARK: ASAuthorizationControllerDelegate

extension BrowserAppleSignInService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization,
    ) {
        Task { @MainActor in
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                continuation?.resume(throwing: BrowserAppleSignInError.missingIdentityToken)
                continuation = nil
                return
            }

            continuation?.resume(returning: identityToken)
            continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithError error: Error,
    ) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: ASAuthorizationControllerPresentationContextProviding

extension BrowserAppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
