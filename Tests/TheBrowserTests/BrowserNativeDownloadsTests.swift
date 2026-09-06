import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeDownloadsTests {
    // MARK: Internal

    @Test func downloadRowsTrackProgressAndCompletionWithoutReplacingTheirViews() throws {
        let model = BrowserDownloadsModel()
        model.apply(update("a", state: .inProgress, total: 100, received: 25))
        let controller = BrowserDownloadsViewController(model: model)
        _ = controller.view
        let row = try #require(controller.rows["a"])
        #expect(row.progress.doubleValue == 0.25)
        #expect(!row.progress.isIndeterminate)
        #expect(!row.progress.isHidden)
        #expect(row.openButton.isHidden)
        model.apply(update("a", state: .completed, total: 100, received: 100))
        controller.refresh()
        #expect(controller.rows["a"] === row)
        #expect(row.progress.isHidden)
        #expect(!row.openButton.isHidden)
        #expect(!row.revealButton.isHidden)
        #expect(controller.clearButton.isEnabled)
        var actions = [String]()
        row.onOpen = { actions.append("open") }
        row.onReveal = { actions.append("reveal") }
        row.openButton.performClick(nil)
        row.revealButton.performClick(nil)
        #expect(actions == ["open", "reveal"])
    }

    @Test func clearingFinishedDownloadsKeepsActiveTransfers() {
        let model = BrowserDownloadsModel()
        model.apply(update("active", state: .inProgress, total: 0, received: 10))
        model.apply(update("finished", state: .completed, total: 10, received: 10))
        let controller = BrowserDownloadsViewController(model: model)
        _ = controller.view
        #expect(controller.rows["active"]?.progress.isIndeterminate == true)
        controller.clearButton.performClick(nil)
        controller.refresh()
        #expect(model.items.map(\.id) == ["active"])
        #expect(Set(controller.rows.keys) == ["active"])
        #expect(!controller.clearButton.isEnabled)
    }

    @Test func downloadsPopoverCapsLongListsAndKeepsEmptyStateCompact() {
        let model = BrowserDownloadsModel()
        let controller = BrowserDownloadsViewController(model: model)
        _ = controller.view
        let emptyHeight = controller.preferredContentSize.height
        for index in 0..<20 {
            model.apply(update(String(index), state: .completed, total: 1, received: 1))
        }
        controller.refresh()
        #expect(controller.preferredContentSize.width == 360)
        #expect(controller.preferredContentSize.height <= 380)
        #expect(controller.preferredContentSize.height > emptyHeight)
        #expect(controller.rows.count == 20)
    }

    @Test func updateToastRoutesInstallAndDismissSeparately() throws {
        let view = BrowserNativeUpdateToastView()
        var actions = [String]()
        view.onInstall = { actions.append("install") }
        view.onDismiss = { actions.append("dismiss") }
        view.update(.init(
            title: "Update available",
            message: "A new version is ready to install.",
            actionTitle: "Relaunch"
        ))
        view.frame = NSRect(x: 0, y: 0, width: 240, height: view.height(for: 240))
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let all = descendants(view)
        let install = try #require(all
            .first { $0.accessibilityIdentifier() == "browser.update.install" } as? BrowserNativePressableView)
        let dismiss = try #require(all
            .first { $0.accessibilityIdentifier() == "browser.update.dismiss" } as? BrowserNativeChromeButton)
        #expect(install.accessibilityPerformPress())
        dismiss.performClick(nil)
        #expect(actions == ["install", "dismiss"])
        #expect(view.bounds.contains(install.convert(install.bounds, to: view)))
        #expect(view.bounds.contains(dismiss.convert(dismiss.bounds, to: view)))
    }

    // MARK: Private

    private func update(
        _ id: String,
        state: BrowserDownloadState,
        total: Int64,
        received: Int64
    ) -> BrowserDownloadUpdate {
        .init(
            id: id,
            fileName: "\(id).pdf",
            urlString: "https://example.com/\(id).pdf",
            fullPath: "/tmp/\(id).pdf",
            receivedBytes: received,
            totalBytes: total,
            currentSpeedBytesPerSecond: 5,
            state: state
        )
    }
}
