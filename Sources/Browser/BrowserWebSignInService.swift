// BrowserWebSignInService.swift

import AppKit
import AuthenticationServices
import Foundation

// MARK: - BrowserSignInEvents

/// What the engine posts when a page reaches `openarc-auth://`, where a web
/// sign-in ends, and when a sign-in small window closes. Posted on the main thread.
@objc final class BrowserSignInEvents: NSObject {
    @objc static let callback = Notification.Name("BrowserSignInCallback")
    @objc static let windowDidClose = Notification.Name("BrowserSignInWindowDidClose")
    /// The callback's address in `callback`'s user info.
    @objc static let urlKey = "url"
}

// MARK: - BrowserWebSignInService

/// Runs a provider's sign-in page in an ASWebAuthenticationSession, which
/// Developer ID apps can use where native Sign in with Apple is unavailable.
///
/// While OpenArc is the default browser, Safari treats every https page as the
/// app's own and ends the session at the first one, so the page opens in a
/// small window of OpenArc instead and its callback comes back from the engine.
@MainActor final class BrowserWebSignInService: NSObject, BrowserWebSignInPresenting {
    // MARK: Private

    private let openInApp: @MainActor (URL) -> Bool
    private let isDefaultBrowser: @MainActor () -> Bool
    private var session: ASWebAuthenticationSession?
    /// A sign-in in OpenArc's small window: its callback scheme and the wait for it.
    private var inAppSignIn: (scheme: String, continuation: CheckedContinuation<URL, Error>)?

    /// `openInApp` opens the page in OpenArc's small window, false when no
    /// window can.
    init(
        openInApp: @escaping @MainActor (URL) -> Bool = { _ in false },
        isDefaultBrowser: @escaping @MainActor () -> Bool = BrowserWebSignInService.appIsDefaultBrowser,
    ) {
        self.openInApp = openInApp
        self.isDefaultBrowser = isDefaultBrowser
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: BrowserSignInEvents.callback, object: nil, queue: .main) { [weak self] note in
            let urlString = note.userInfo?[BrowserSignInEvents.urlKey] as? String
            MainActor.assumeIsolated { self?.receiveCallback(urlString) }
        }
        center.addObserver(forName: BrowserSignInEvents.windowDidClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishInApp(.failure(BrowserWebSignInError.cancelled)) }
        }
    }

    // MARK: Internal

    /// Whether http and https links open in this app.
    static func appIsDefaultBrowser() -> Bool {
        guard let page = URL(string: "https://openarc.su"),
              let browser = NSWorkspace.shared.urlForApplication(toOpen: page).flatMap(Bundle.init(url:)),
              let browserID = browser.bundleIdentifier,
              let appID = Bundle.main.bundleIdentifier
        else { return false }
        return browserID.caseInsensitiveCompare(appID) == .orderedSame
    }

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

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        if isDefaultBrowser() {
            return try await withCheckedThrowingContinuation { continuation in
                inAppSignIn = (callbackScheme, continuation)
                if !openInApp(url) {
                    finishInApp(.failure(BrowserAccountSignInError.providerFailed))
                }
            }
        }
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
        finishInApp(.failure(BrowserWebSignInError.cancelled))
    }

    private func receiveCallback(_ urlString: String?) {
        guard let scheme = inAppSignIn?.scheme,
              let url = urlString.flatMap(URL.init(string:)),
              url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
        else { return }
        finishInApp(.success(url))
    }

    private func finishInApp(_ result: Result<URL, Error>) {
        guard let continuation = inAppSignIn?.continuation else { return }
        inAppSignIn = nil
        continuation.resume(with: result)
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension BrowserWebSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
