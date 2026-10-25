// BrowserNativeSessionRecoveryTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeSessionRecoveryTests {
    // MARK: Internal

    @Test func recoveryControlsRemainVisibleAndOnlyOfferValidActions() throws {
        let view = BrowserSessionPersistenceStatusView()
        var retries = 0
        var exports = 0
        view.onRetry = { retries += 1 }
        view.onSaveCopy = { exports += 1 }
        let retry = try #require(descendants(view)
            .first { $0.accessibilityIdentifier() == "browser.session.retry" } as? NSButton)
        let save = try #require(descendants(view)
            .first { $0.accessibilityIdentifier() == "browser.session.save-copy" } as? NSButton)
        #expect(view.isHidden)
        view.update(.init(reason: .writeFailed))
        #expect(!view.isHidden)
        #expect(retry.isEnabled)
        retry.performClick(nil)
        save.performClick(nil)
        #expect(retries == 1)
        #expect(exports == 1)
        for reason: BrowserSessionPersistenceFailure.Reason in [
            .mutationTooLarge, .invalidMoveIntent, .bufferLimitExceeded, .snapshotEncodingFailed,
        ] {
            view.update(.init(reason: reason))
            #expect(!view.isHidden)
            #expect(!retry.isEnabled)
            #expect(save.isEnabled)
            retry.performClick(nil)
            #expect(retries == 1)
        }
        view.update(nil)
        #expect(view.isHidden)
    }

    @Test(arguments: [320.0, 640.0]) func recoveryTextAndButtonsFitWithoutOverlap(width: Double) {
        let view = BrowserSessionPersistenceStatusView()
        view.update(.init(reason: .writeFailed))
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.height(for: width))
        view.layoutSubtreeIfNeeded()
        let controls = descendants(view).compactMap { $0 as? NSControl }
        #expect(controls.count == 4)
        for control in controls {
            let frame = control.convert(control.bounds, to: view)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(view.bounds.contains(frame))
        }
        let frames = controls.map { $0.convert($0.bounds, to: view) }
        for i in frames.indices {
            for j in frames.indices where i < j {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
    }

    // MARK: Private

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
