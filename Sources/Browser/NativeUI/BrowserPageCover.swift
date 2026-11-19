// BrowserPageCover.swift

import AppKit
import QuartzCore

// MARK: - BrowserPageCover

/// A Chromium page draws through a `CALayerHost` showing the remote layer context of the page's
/// compositor. A page in OpenArc's window has no parent layer, so hiding it destroys its compositor
/// and that context with it: a page shown again draws nothing until a new compositor delivers its
/// first frame in a new context. The page that was on screen stays on top until then, so a switch
/// goes from one page straight to the other.
@objc(BrowserPageCover) final class BrowserPageCover: NSObject {
    // MARK: Private

    private static let contextIDSelector = NSSelectorFromString("contextId")

    // MARK: Internal

    /// The remote layer contexts a page view shows: the `contextId` of every visible layer that has
    /// one, searched a few levels deep.
    static func contextIDs(in layer: CALayer, depth: Int = 8) -> Set<UInt32> {
        guard !layer.isHidden else { return [] }
        var ids = Set<UInt32>()
        if layer.responds(to: contextIDSelector), let id = (layer.value(forKey: "contextId") as? NSNumber)?.uint32Value,
           id != 0
        {
            ids.insert(id)
        }
        guard depth > 0 else { return ids }
        for sublayer in layer.sublayers ?? [] {
            ids.formUnion(contextIDs(in: sublayer, depth: depth - 1))
        }
        return ids
    }

    /// Whether the page drew since `baseline` was taken: it shows a context it did not show then.
    static func hasNewFrame(_ current: Set<UInt32>, since baseline: Set<UInt32>) -> Bool {
        !current.subtracting(baseline).isEmpty
    }

    /// The page that stays on top of the shown one, or nil for none. `incoming` is the only page
    /// shown; it waits for a frame when it is a Chromium page coming out of hiding, or while it is
    /// still the page an earlier cover waits for. The page on screen covers it: the earlier cover,
    /// else the page shown alone before. The caller checks that this page is still on screen.
    @objc(coverKeyForIncoming:incomingWaitsForFrame:pendingCover:pendingIncoming:shownPage:) static func coverKey(
        incoming: String?,
        incomingWaitsForFrame: Bool,
        pendingCover: String?,
        pendingIncoming: String?,
        shownPage: String?,
    ) -> String? {
        guard let incoming, !incoming.isEmpty else { return nil }
        let waits = incomingWaitsForFrame || (nonEmpty(pendingCover) != nil && pendingIncoming == incoming)
        guard waits, let cover = nonEmpty(pendingCover) ?? nonEmpty(shownPage), cover != incoming else { return nil }
        return cover
    }

    private static func nonEmpty(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return key
    }
}

// MARK: - BrowserPageFrameWatcher

/// Waits, frame by frame, until a page view shows a new remote layer context, or a timeout passes.
@MainActor @objc(BrowserPageFrameWatcher) final class BrowserPageFrameWatcher: NSObject {
    // MARK: Private

    private weak var pageView: NSView?
    private var baseline = Set<UInt32>()
    /// Display frames left to wait for, or nil while waiting for a new context.
    private var framesLeft: Int?
    private var displayLink: CADisplayLink?
    private var timeout: Timer?
    private var completion: (() -> Void)?

    // MARK: Internal

    /// The page view watched, nil when none.
    @objc var watchedPageView: NSView? {
        completion != nil && framesLeft == nil ? pageView : nil
    }

    /// Starts watching `pageView`, which is about to be shown, in place of any earlier watch. Calls
    /// `completion` once, on the first display frame that finds a new context in it, or after
    /// `timeout` seconds.
    @objc(watchPageView:timeout:completion:)
    func watch(pageView: NSView, timeout seconds: TimeInterval, completion: @escaping () -> Void) {
        start(view: pageView, frames: nil, timeout: seconds, completion: completion)
    }

    /// Calls `completion` once `view`'s display has shown two more frames, so a change made now is
    /// on screen, or after `timeout` seconds; in place of any earlier watch.
    @objc(waitForFramesOfView:timeout:completion:)
    func waitForFrames(of view: NSView, timeout seconds: TimeInterval, completion: @escaping () -> Void) {
        start(view: view, frames: 2, timeout: seconds, completion: completion)
    }

    /// Stops the watch without calling its completion.
    @objc func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        timeout?.invalidate()
        timeout = nil
        completion = nil
        pageView = nil
        baseline = []
        framesLeft = nil
    }

    private func start(view: NSView, frames: Int?, timeout seconds: TimeInterval, completion: @escaping () -> Void) {
        cancel()
        pageView = view
        framesLeft = frames
        baseline = frames == nil ? view.layer.map { BrowserPageCover.contextIDs(in: $0) } ?? [] : []
        self.completion = completion
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    private func finish() {
        let completion = completion
        cancel()
        completion?()
    }

    @objc private func tick(_: CADisplayLink) {
        if let framesLeft {
            self.framesLeft = framesLeft - 1
            if framesLeft <= 1 {
                finish()
            }
            return
        }
        guard let layer = pageView?.layer else {
            finish()
            return
        }
        if BrowserPageCover.hasNewFrame(BrowserPageCover.contextIDs(in: layer), since: baseline) {
            finish()
        }
    }
}
