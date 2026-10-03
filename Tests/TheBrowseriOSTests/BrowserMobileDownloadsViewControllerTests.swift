import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func releasedDownloadsControllerRemovesObservationWithoutExplicitInvalidation() async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        source.holdsExports = true
        var presentations = 0
        weak var releasedController: BrowserMobileDownloadsViewController?

        @MainActor func releaseOwner() async throws {
            let controller = BrowserMobileDownloadsViewController(downloads: source) { _, _ in presentations += 1 }
            releasedController = controller
            let host = try DownloadUIHost(controller)
            defer {
                // A scene can release its window without a controller dismissal
                // or the explicit invalidate() used by the other fixture tests.
                host.window.isHidden = true
                host.window.rootViewController = nil
            }
            try await downloadUIWait { source.loads == 1 }
            try host.press(entry.id)
            try await downloadUIWait { source.exports == [entry.id] }
            #expect(source.observerCount == 1)
        }

        try await releaseOwner()
        try await downloadUIWait { releasedController == nil }
        #expect(source.observerCount == 0)
        source.finishExport(at: 0)
        await downloadUIDrain()
        #expect(presentations == 0)
        #expect(source.observerCount == 0)
    }

    @Test func downloadsRemainObservedAndExportAgainAfterFullScreenChildReturns() async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        var pickers = [UIDocumentPickerViewController]()
        var covers = [UIViewController]()
        let controller = BrowserMobileDownloadsViewController(downloads: source) { owner, picker in
            pickers.append(picker)
            // Exercise UIKit's real removal/restoration of the presenting view
            // without opening or operating the system Files service.
            let cover = UIViewController()
            cover.modalPresentationStyle = .fullScreen
            cover.view.backgroundColor = .systemBackground
            covers.append(cover)
            owner.present(cover, animated: false)
        }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try await downloadUIWait { source.loads == 1 }
        try host.press(entry.id)
        try await downloadUIWait { covers.count == 1 && controller.view.window == nil }
        let firstCover = try #require(covers.first)
        try #require(firstCover.presentingViewController != nil)
        #expect(source.observerCount == 1)
        #expect(try !(host.button(entry.id).isEnabled))
        source.entries[0].filename = "Updated while the picker covers the list.txt"
        source.notify()

        try controller.documentPickerWasCancelled(#require(pickers.first))
        firstCover.dismiss(animated: false)
        try await downloadUIWait {
            firstCover.presentingViewController == nil && controller.view.window === host.window
        }
        let filename = try #require(host.view(entry.id, suffix: "filename") as? UILabel)
        #expect(filename.text == source.entries[0].filename)
        #expect(source.observerCount == 1)
        try host.press(entry.id)
        try await downloadUIWait { covers.count == 2 && controller.view.window == nil }
        #expect(source.exports == [entry.id, entry.id])
        #expect(source.observerCount == 1)
        let secondCover = covers[1]
        controller.documentPickerWasCancelled(pickers[1])
        secondCover.dismiss(animated: false)
        try await downloadUIWait { controller.view.window === host.window }
        #expect(try host.button(entry.id).isEnabled)
    }

    @Test func downloadsListExportsRealPersistedFileUsingItsOwnNativePicker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadUI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = BrowserMobileDownloadDisk(directory: directory)
        let entry = downloadUIEntry(status: .downloading)
        let url = try await disk.prepare(id: entry.id, filename: entry.filename)
        let bytes = Data("An actual completed download".utf8)
        try bytes.write(to: url)
        let completed = try await disk.complete(entry)
        let downloads = BrowserMobileDownloads(directory: directory)
        var presented = [(UIViewController, UIDocumentPickerViewController)]()
        let controller = BrowserMobileDownloadsViewController(downloads: downloads) { presented.append(($0, $1)) }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try await downloadUIWait { downloads.entries == [completed] && !downloads.isLoading }
        try host.press(completed.id)
        try await downloadUIWait { presented.count == 1 }
        let (owner, picker) = try #require(presented.first)
        #expect(owner === controller)
        #expect(picker.delegate === controller)
        #expect(picker.modalPresentationStyle == .formSheet && picker.shouldShowFileExtensions)
        #expect(picker.view.accessibilityIdentifier == "browser.downloads.export")
        #expect(try Data(contentsOf: url) == bytes)
        // UIKit configuration and the production export path are exercised;
        // the system Files UI is not operated by this hosted test.
        controller.documentPickerWasCancelled(picker)
        try host.press(completed.id)
        try await downloadUIWait { presented.count == 2 }
        controller.documentPicker(presented[1].1, didPickDocumentsAt: [directory.appendingPathComponent("export")])
        let reopened = BrowserMobileDownloads(directory: directory)
        await reopened.load()
        #expect(reopened.entries == [completed])
        let reopenedURL = try await reopened.exportURL(id: entry.id)
        #expect(try Data(contentsOf: reopenedURL) == bytes)
    }

    @Test func downloadRowsObserveProgressCancelAndManifestRetryWithAccessibleActions() async throws {
        let active = downloadUIEntry(status: .downloading)
        let source = try DownloadUIModel(entries: [active])
        let controller = BrowserMobileDownloadsViewController(downloads: source)
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try await downloadUIWait { source.loads == 1 }
        var entry = active
        entry.receivedBytes = 25
        entry.totalBytes = 100
        source.entries = [entry]
        source.notify()
        let progress = try #require(host.view(active.id, suffix: "progress") as? UIProgressView)
        #expect(!progress.isHidden && progress.progress == 0.25)
        let label = try #require(host.view(active.id, suffix: "filename") as? UILabel)
        #expect(label.adjustsFontForContentSizeCategory && label.numberOfLines == 0)
        for width in [CGFloat(320), 700] {
            host.window.frame.size = CGSize(width: width, height: 900)
            host.navigation.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            host.layout()
            let button = try host.button(active.id)
            let currentLabel = try #require(host.view(active.id, suffix: "filename") as? UILabel)
            #expect(button.bounds.height >= 44)
            #expect(button.bounds.width > 0)
            #expect(
                !button.hasAmbiguousLayout,
                "Button \(button.frame), vertical constraints \(button.constraintsAffectingLayout(for: .vertical))"
            )
            #expect(currentLabel.bounds.width > 0 && !currentLabel.hasAmbiguousLayout)
        }
        try host.press(active.id)
        #expect(source.cancelled == [active.id])
        #expect(source.entries[0].status == .cancelled)
        #expect(try host.button(active.id).isHidden)
        let cancelledProgress = try #require(host.view(active.id, suffix: "progress") as? UIProgressView)
        #expect(cancelledProgress.isHidden)

        entry.status = .saving
        source.entries = [entry]
        source.notify()
        #expect(try host.button(active.id).isHidden)
        let savingStatus = try #require(host.view(active.id, suffix: "status") as? UILabel)
        #expect(savingStatus.text == String(localized: "Saving…", table: "Mobile"))

        entry.status = .failed
        entry.error = "The connection was interrupted."
        source.entries = [entry]
        source.error = "The completed file could not be saved."
        source.canRetryPersistence = true
        source.notify()
        let status = try #require(host.view(active.id, suffix: "status") as? UILabel)
        #expect(try status.text?.contains(#require(entry.error)) == true)
        #expect(try host.button(active.id).isHidden)
        host.layout()
        let retry = try #require(downloadUIView("browser.downloads.retry", in: controller.view) as? UIButton)
        #expect(!retry.isHidden && retry.isEnabled && retry.bounds.height >= 44)
        retry.sendActions(for: .touchUpInside)
        try await downloadUIWait { source.retries == 1 && retry.isHidden }
        #expect(source.cancelled == [active.id] && source.exports.isEmpty)
    }

    @Test func exportKeepsCapturedIdentityAcrossReorderAndRejectsRemovedOrChangedEntry() async throws {
        let first = downloadUIEntry(status: .completed)
        var second = downloadUIEntry(status: .completed)
        second.filename = first.filename
        let source = try DownloadUIModel(entries: [first, second])
        source.holdsExports = true
        var pickers = [UIDocumentPickerViewController]()
        let controller = BrowserMobileDownloadsViewController(downloads: source) { _, picker in pickers.append(picker) }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try host.press(first.id)
        try await downloadUIWait { source.exports == [first.id] }
        source.entries = [second, first]
        source.notify()
        source.finishExport(at: 0)
        try await downloadUIWait { pickers.count == 1 }
        #expect(source.exports == [first.id])
        controller.documentPickerWasCancelled(pickers[0])

        try host.press(first.id)
        try await downloadUIWait { source.exports.count == 2 }
        source.entries.removeAll { $0.id == first.id }
        source.notify()
        source.finishExport(at: 1)
        await downloadUIDrain()
        #expect(pickers.count == 1)
        try host.press(second.id)
        try await downloadUIWait { source.exports.count == 3 }
        source.entries[0].status = .failed
        source.entries[0].error = "File no longer exists."
        source.notify()
        source.finishExport(at: 2)
        await downloadUIDrain()
        #expect(pickers.count == 1)
        #expect(source.exports == [first.id, first.id, second.id])
    }

    @Test func exportSceneLeaseRejectsOldCompletionWithoutCancellingNewAttempt() async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        source.holdsExports = true
        var presentations = [(UIViewController, UIDocumentPickerViewController)]()
        let controller = BrowserMobileDownloadsViewController(downloads: source) { presentations.append(($0, $1)) }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        let other = try DownloadUIHost(BrowserMobileDownloadsViewController(downloads: DownloadUIModel(entries: [])))
        defer { other.close() }
        // Two windows use the host's one real scene. Notification delivery here
        // tests the production lifecycle callback, not an OS scene transition.
        try host.press(entry.id)
        try await downloadUIWait { source.exports.count == 1 }
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
        #expect(try !(host.button(entry.id).isEnabled))
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: host.window.windowScene)
        try host.press(entry.id)
        await downloadUIDrain()
        #expect(source.exports.count == 1)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: host.window.windowScene)
        try host.press(entry.id)
        try await downloadUIWait { source.exports.count == 2 }
        source.finishExport(at: 0)
        await downloadUIDrain()
        #expect(try presentations.isEmpty && !(host.button(entry.id).isEnabled))
        source.finishExport(at: 1)
        try await downloadUIWait { presentations.count == 1 }
        #expect(presentations[0].0 === controller && presentations[0].0.view.window === host.window)
        controller.documentPickerWasCancelled(presentations[0].1)
        #expect(other.controller.presentedViewController == nil)
    }

    @Test(arguments: DownloadUIInvalidation.allCases)
    func pendingExportCannotPresentAfterOwnerBecomesUnavailable(reason: DownloadUIInvalidation) async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        source.holdsExports = true
        var presentations = 0
        let controller = BrowserMobileDownloadsViewController(downloads: source) { _, _ in presentations += 1 }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try host.press(entry.id)
        try await downloadUIWait { source.exports.count == 1 }
        switch reason {
        case .hidden:
            host.window.isHidden = true
        case .done:
            let done = try #require(controller.navigationItem.rightBarButtonItem)
            let action = try #require(done.action)
            #expect(UIApplication.shared.sendAction(action, to: done.target, from: done, for: nil))
        case .disconnected:
            NotificationCenter.default.post(name: UIScene.didDisconnectNotification, object: host.window.windowScene)
        }
        source.finishExport(at: 0)
        await downloadUIDrain()
        #expect(presentations == 0)
        if reason == .done {
            #expect(source.observerCount == 0)
        }
    }

    @Test func exportFailureLeavesActionAvailableAndObservationsEndOnDismissal() async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        source.holdsExports = true
        var presentations = 0
        let controller = BrowserMobileDownloadsViewController(downloads: source) { _, _ in presentations += 1 }
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try host.press(entry.id)
        try await downloadUIWait { source.exports.count == 1 }
        source.failExport(at: 0)
        try await downloadUIWait {
            (downloadUIView("browser.downloads.status", in: controller.view) as? UILabel)?.text ==
                String(localized: "This file could not be prepared. Try Save to Files again.", table: "Mobile")
        }
        #expect(try host.button(entry.id).isEnabled)
        #expect(presentations == 0)
        controller.invalidate()
        #expect(source.observerCount == 0)
        source.entries = []
        source.notify()
        #expect(controller.tableView.numberOfRows(inSection: 0) == 1)
    }
}

// MARK: - DownloadUIInvalidation

enum DownloadUIInvalidation: CaseIterable { case hidden, done, disconnected }

// MARK: - DownloadUIModel

@MainActor private final class DownloadUIModel: BrowserMobileDownloadsPresenting {
    // MARK: Lifecycle

    init(entries: [BrowserMobileDownload]) throws {
        self.entries = entries
        self.exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadUI-\(UUID()).txt")
        try Data("A file ready for export".utf8).write(to: exportURL)
    }

    deinit { try? FileManager.default.removeItem(at: exportURL) }

    // MARK: Internal

    var entries: [BrowserMobileDownload]
    var isLoading = false
    var error: String?
    var canRetryPersistence = false
    var loads = 0
    var retries = 0
    var cancelled = [UUID]()
    var exports = [UUID]()
    var holdsExports = false

    var observerCount: Int { observers.count }

    func load() { loads += 1
        notify()
    }

    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func notify() { for observer in Array(observers.values) {
        observer()
    } }
    func cancel(id: UUID) {
        cancelled.append(id)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = .cancelled
        }
        notify()
    }

    func retryPersistence() {
        retries += 1
        canRetryPersistence = false
        error = nil
        notify()
    }

    func exportURL(id: UUID) async throws -> URL {
        exports.append(id)
        if holdsExports {
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        return exportURL
    }

    func finishExport(at index: Int) { continuations[index].resume(returning: exportURL) }
    func failExport(at index: Int) { continuations[index].resume(throwing: DownloadUITestError.exportFailed) }

    // MARK: Private

    private let exportURL: URL
    private var observers = [UUID: @MainActor () -> Void]()
    private var continuations = [CheckedContinuation<URL, Error>]()
}

// MARK: - DownloadUIHost

@MainActor private final class DownloadUIHost {
    // MARK: Lifecycle

    init(_ controller: BrowserMobileDownloadsViewController) throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        try #require(scene.activationState == .foregroundActive)
        self.controller = controller
        self.navigation = UINavigationController(rootViewController: controller)
        self.window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.frame.size = CGSize(width: 390, height: 900)
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        layout()
    }

    // MARK: Internal

    let controller: BrowserMobileDownloadsViewController
    let navigation: UINavigationController
    let window: UIWindow

    func layout() { window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.tableView.layoutIfNeeded()
    }

    func view(_ id: UUID, suffix: String) -> UIView? {
        layout()
        return downloadUIView("browser.downloads." + id.uuidString + "." + suffix, in: controller.view)
    }

    func button(_ id: UUID) throws -> UIButton { try #require(view(id, suffix: "action") as? UIButton) }
    func press(_ id: UUID) throws {
        let button = try button(id)
        try #require(button.isEnabled && !button.isHidden)
        button.sendActions(for: .touchUpInside)
    }

    func close() {
        controller.invalidate()
        window.isHidden = true
        window.rootViewController = nil
    }
}

private func downloadUIEntry(status: BrowserMobileDownload.Status) -> BrowserMobileDownload {
    .init(
        id: UUID(), filename: "A useful downloaded document.txt", sourceURL: URL(string: "https://example.com/file"),
        status: status, receivedBytes: 20, totalBytes: 20, error: nil
    )
}

@MainActor private func downloadUIView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { downloadUIView(id, in: $0) }.first
}

@MainActor private func downloadUIWait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Downloads UI did not reach its expected state")
    throw DownloadUITestError.timeout
}

@MainActor private func downloadUIDrain() async { try? await Task.sleep(for: .milliseconds(30)) }

// MARK: - DownloadUITestError

private enum DownloadUITestError: Error { case exportFailed, timeout }
