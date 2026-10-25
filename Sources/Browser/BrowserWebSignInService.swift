// BrowserWebSignInService.swift

import AppKit
import AuthenticationServices
import Foundation

// MARK: - BrowserWebSignInService

/// Runs a provider's sign-in page in an ASWebAuthenticationSession, which
/// Developer ID apps can use where native Sign in with Apple is unavailable.
@MainActor final class BrowserWebSignInService: NSObject, BrowserWebSignInPresenting {
    // MARK: Private

    private var session: ASWebAuthenticationSession?

    // MARK: Internal

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme),
            ) { callbackURL, error in
                Task { @MainActor in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: BrowserWebSignInError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? BrowserWebSignInError.cancelled)
                    }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: BrowserAccountSignInError.providerFailed)
            }
        }
    }

    /// Ends a running session, which completes it as cancelled.
    func cancel() {
        session?.cancel()
        session = nil
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension BrowserWebSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
