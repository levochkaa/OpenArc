// BrowserUpdateFailureTests.swift

import Foundation
import Testing

struct BrowserUpdateFailureTests {
    private static let archive = URL(string: "https://api.openarc.su/downloads/OpenArc-0.3.1-4.zip")!

    @Test func onlyErrorsInstallingADownloadedUpdateCount() {
        // Extraction, signature, validation, installation and installer-connection errors.
        for code in [3000, 3001, 3002, 4000, 4005, 4010, 4012] {
            #expect(BrowserUpdateToastState.isInstallationFailure(sparkleErrorCode: code))
        }
        // No update, appcast and download errors, a cancelled or postponed authorization, API misuse.
        for code in [1001, 1002, 2001, 4007, 4008, 5000] {
            #expect(!BrowserUpdateToastState.isInstallationFailure(sparkleErrorCode: code))
        }
    }

    @Test func aFailedInstallOffersTheFullArchiveForDownload() {
        var state = BrowserUpdateToastState()
        state.updateDownloaded(fullArchiveURL: Self.archive)
        #expect(state.toast?.action == .restart)

        let reported = state.updateFailed(sparkleErrorCode: 4005)
        #expect(reported)
        #expect(state.toast?.title == BrowserStrings.updateFailedTitle)
        #expect(state.toast?.action == .download(Self.archive))
    }

    @Test func aDeltaKeepsTheFullArchiveAndAnUnknownArchiveFallsBackToTheWebsite() {
        var state = BrowserUpdateToastState()
        state.updateDownloaded(fullArchiveURL: Self.archive)
        state.updateDownloaded(fullArchiveURL: nil)
        state.updateFailed(sparkleErrorCode: 3000)
        #expect(state.toast?.action == .download(Self.archive))

        var fresh = BrowserUpdateToastState()
        fresh.updateFailed(sparkleErrorCode: 4005)
        #expect(fresh.toast?.action == .download(BrowserUpdateToastState.downloadPageURL))
    }

    @Test func aCheckThatFindsNothingLeavesTheToastAlone() {
        var state = BrowserUpdateToastState()
        let noUpdate = state.updateFailed(sparkleErrorCode: 1001)
        #expect(!noUpdate)
        #expect(state.toast == nil)

        state.updateDownloaded(fullArchiveURL: Self.archive)
        let cancelled = state.updateFailed(sparkleErrorCode: 4007)
        #expect(!cancelled)
        #expect(state.toast?.action == .restart)
    }
}
