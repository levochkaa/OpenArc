// BrowserUpdateToast.swift

import Foundation

// MARK: - BrowserUpdateToast

struct BrowserUpdateToast: Identifiable, Equatable {
    enum Action: Equatable {
        case restart
        /// The update couldn't be installed in place, so it is downloaded to install by hand.
        case download(URL)
    }

    static let ready = BrowserUpdateToast(
        title: BrowserStrings.updateReadyTitle,
        actionTitle: BrowserStrings.updateRestartAction,
        action: .restart,
    )

    let id = UUID()
    let title: String
    let actionTitle: String
    let action: Action

    static func failed(download url: URL) -> BrowserUpdateToast {
        BrowserUpdateToast(
            title: BrowserStrings.updateFailedTitle,
            actionTitle: BrowserStrings.updateDownloadAction,
            action: .download(url),
        )
    }
}

// MARK: - BrowserUpdateToastState

/// Sparkle reports a failed install only to its log while updates run in the background,
/// so the toast that offered the restart offers the update's download instead.
struct BrowserUpdateToastState {
    /// Offered when the full archive of the failed update is unknown.
    static let downloadPageURL = URL(string: "https://openarc.su")!

    private(set) var toast: BrowserUpdateToast?

    private var fullArchiveURL: URL?

    /// Codes from Sparkle's SUErrors.h: extraction errors run from 3000 and installation errors
    /// to 4999. Cancelling the authorization prompt (4007) or postponing it (4008) is no failure.
    static func isInstallationFailure(sparkleErrorCode code: Int) -> Bool {
        (3000..<5000).contains(code) && code != 4007 && code != 4008
    }

    /// A delta has no archive to install by hand, so it keeps the full archive already known.
    mutating func updateDownloaded(fullArchiveURL: URL?) {
        if let fullArchiveURL {
            self.fullArchiveURL = fullArchiveURL
        }
        toast = .ready
    }

    /// Returns whether the failure was one of installing a downloaded update.
    @discardableResult mutating func updateFailed(sparkleErrorCode code: Int) -> Bool {
        guard Self.isInstallationFailure(sparkleErrorCode: code) else { return false }
        toast = .failed(download: fullArchiveURL ?? Self.downloadPageURL)
        fullArchiveURL = nil
        return true
    }

    mutating func dismiss() {
        toast = nil
    }

    mutating func reset() {
        toast = nil
        fullArchiveURL = nil
    }
}
