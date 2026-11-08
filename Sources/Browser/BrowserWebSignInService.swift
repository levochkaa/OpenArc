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

    /// The session's completion. AuthenticationServices calls it on its own
    /// queue, never the main one, so it must not inherit the main actor, or
    /// Swift traps; the result reaches `finish` on the main actor.
    nonisolated static func completionHandler(
        _ finish: @escaping @MainActor (Result<URL, Error>) -> Void,
    ) -> @Sendable (URL?, Error?) -> Void {
        { callbackURL, error in
            Task { @MainActor in
                if let callbackURL {
                    finish(.success(callbackURL))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.failure(BrowserWebSignInError.cancelled))
                } else {
                    finish(.failure(error ?? BrowserWebSignInError.cancelled))
                }
            }
        }
    }

    // MARK: Internal

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme),
                completionHandler: Self.completionHandler { continuation.resume(with: $0) },
            )
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
