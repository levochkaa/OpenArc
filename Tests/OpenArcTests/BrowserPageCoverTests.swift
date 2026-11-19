// BrowserPageCoverTests.swift

import QuartzCore
import Testing

// MARK: - RemoteContextLayer

/// Stands in for Core Animation's `CALayerHost`, which shows a remote layer context.
private final class RemoteContextLayer: CALayer {
    @objc var contextId: UInt32 = 0
}

/// The layers of a Chromium page view: a backing layer, a background layer and the host of the
/// compositor's context.
private func pageLayer(contextID: UInt32?, hostHidden: Bool = false) -> CALayer {
    let root = CALayer()
    let background = CALayer()
    let flipped = CALayer()
    if let contextID {
        let host = RemoteContextLayer()
        host.contextId = contextID
        host.isHidden = hostHidden
        flipped.addSublayer(host)
    }
    background.addSublayer(flipped)
    root.addSublayer(background)
    return root
}

@Test func pageCoverFindsTheRemoteContextOfAPage() {
    #expect(BrowserPageCover.contextIDs(in: pageLayer(contextID: 42)) == [42])
    #expect(BrowserPageCover.contextIDs(in: pageLayer(contextID: nil)).isEmpty)
    #expect(BrowserPageCover.contextIDs(in: pageLayer(contextID: 0)).isEmpty)
    #expect(BrowserPageCover.contextIDs(in: pageLayer(contextID: 42, hostHidden: true)).isEmpty)
}

@Test func pageCoverSeesANewFrameOnlyInANewContext() {
    // The page shown again still holds the host of its destroyed compositor.
    #expect(!BrowserPageCover.hasNewFrame([7], since: [7]))
    #expect(BrowserPageCover.hasNewFrame([8], since: [7]))
    #expect(BrowserPageCover.hasNewFrame([7, 8], since: [7]))
    // A page that never drew.
    #expect(BrowserPageCover.hasNewFrame([8], since: []))
    #expect(!BrowserPageCover.hasNewFrame([], since: [7]))
}

@Test func pageCoverKeepsTheShownPageOverAChromiumPageComingOutOfHiding() {
    #expect(BrowserPageCover.coverKey(
        incoming: "b", incomingWaitsForFrame: true, pendingCover: nil, pendingIncoming: nil, shownPage: "a",
    ) == "a")
    // WebKit pages, warm pages and the same page need no cover.
    #expect(BrowserPageCover.coverKey(
        incoming: "b", incomingWaitsForFrame: false, pendingCover: nil, pendingIncoming: nil, shownPage: "a",
    ) == nil)
    #expect(BrowserPageCover.coverKey(
        incoming: "a", incomingWaitsForFrame: true, pendingCover: nil, pendingIncoming: nil, shownPage: "a",
    ) == nil)
    #expect(BrowserPageCover.coverKey(
        incoming: "b", incomingWaitsForFrame: true, pendingCover: "", pendingIncoming: "", shownPage: "",
    ) == nil)
}

@Test func pageCoverStaysUntilTheCoveredPageDraws() {
    // The covered page is no longer hidden but has not drawn yet.
    #expect(BrowserPageCover.coverKey(
        incoming: "b", incomingWaitsForFrame: false, pendingCover: "a", pendingIncoming: "b", shownPage: "a",
    ) == "a")
    // Another switch before it drew: the page on screen is still the cover.
    #expect(BrowserPageCover.coverKey(
        incoming: "c", incomingWaitsForFrame: true, pendingCover: "a", pendingIncoming: "b", shownPage: "a",
    ) == "a")
    // Back to the cover itself: it is on screen already.
    #expect(BrowserPageCover.coverKey(
        incoming: "a", incomingWaitsForFrame: false, pendingCover: "a", pendingIncoming: "b", shownPage: "a",
    ) == nil)
}
