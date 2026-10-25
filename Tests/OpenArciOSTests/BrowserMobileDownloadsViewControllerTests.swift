// BrowserMobileDownloadsViewControllerTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func downloadDeleteConfirmationKeepsCapturedIdentityAndCancelDoesNotRemove() async throws {
        var first = downloadUIEntry(status: .completed)
        first.filename = "First saved document.txt"
        var second = downloadUIEntry(status: .completed)
        second.filename = "Second saved document.txt"
        let source = try DownloadUIModel(entries: [first, second])
        let controller = BrowserMobileDownloadsViewController(downloads: source)
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        let swipe = try #require(controller.tableView(
            controller.tableView,
            trailingSwipeActionsConfigurationForRowAt: .init(
                row: 0,
                section: 0,
            ),
        ))
        #expect(!swipe.performsFirstActionWithFullSwipe)
        let action = try #require(swipe.actions.first)
        #expect(action.style == .destructive)
        var reportedRemoval: Bool?
        action.handler(action, controller.view) { reportedRemoval = $0 }
        let cancelledAlert = try await downloadUIDeletionAlert(controller, in: host)
        #expect(reportedRemoval == false && source.removalCalls.isEmpty)
        #expect(cancelledAlert.preferredStyle == .alert)
        #expect(cancelledAlert.message?.contains(first.filename) == true)
        #expect(cancelledAlert.actions.contains { $0.style == .cancel })
        controller.cancelDeletion(dismissing: cancelledAlert)
        try await downloadUIWait { cancelledAlert.presentingViewController == nil }
        #expect(source.removalCalls.isEmpty && source.entries == [first, second])

        let label = try #require(host.view(first.id, suffix: "filename"))
        let accessibleDelete = try #require(label.accessibilityCustomActions?.first)
        #expect(accessibleDelete.name == String(localized: "Delete", table: "Mobile"))
        // Reusing the original row must not retarget its captured action.
        source.entries = [second, first]
        source.notify()
        host.layout()
        #expect(accessibleDelete.actionHandler?(accessibleDelete) == true)
        let confirmedAlert = try await downloadUIDeletionAlert(controller, in: host)
        try #require(
            confirmedAlert.message?.contains(first.filename) == true,
            "The retained accessibility action must still confirm the first download after row reuse",
        )
        #expect(confirmedAlert.message?.contains(second.filename) == false)
        #expect(confirmedAlert.actions.contains { $0.style == .destructive })
        source.entries = [first, second]
        source.notify()
        controller.confirmDeletion(id: first.id, dismissing: confirmedAlert)
        try await downloadUIWait { source.entries == [second] }
        #expect(source.removalCalls == [first.id])
        #expect(controller.tableView.numberOfRows(inSection: 0) == 1)
        controller.confirmDeletion(id: first.id, dismissing: confirmedAlert)
        await downloadUIDrain()
        #expect(source.removalCalls == [first.id])
        let context = try #require(controller.tableView(
            controller.tableView,
            contextMenuConfigurationForRowAt: .init(row: 0, section: 0),
            point: .zero,
        ))
        #expect(context.identifier as? UUID == second.id)
    }

    @Test func downloadDeletionShowsBusyStateAndRetryKeepsItsExactID() async throws {
        let first = downloadUIEntry(status: .completed)
        let survivor = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [first])
        source.holdsRemoval = true
        let controller = BrowserMobileDownloadsViewController(downloads: source)
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try downloadUIRequestAccessibleDelete(first.id, in: host)
        let alert = try await downloadUIDeletionAlert(controller, in: host)
        controller.confirmDeletion(id: first.id, dismissing: alert)
        try await downloadUIWait { source.isDeleting(id: first.id) }
        let status = try #require(host.view(first.id, suffix: "status") as? UILabel)
        #expect(status.text == String(localized: "Deleting…", table: "Mobile"))
        #expect(try !(host.button(first.id).isEnabled))
        #expect(host.view(first.id, suffix: "filename")?.accessibilityCustomActions == nil)
        #expect(controller.tableView(
            controller.tableView,
            trailingSwipeActionsConfigurationForRowAt: .init(row: 0, section: 0),
        ) == nil)
        source.finishRemoval(succeeded: false)
        try await downloadUIWait { source.canRetryPersistence && !source.isDeleting(id: first.id) }
        #expect(source.entries == [first])
        try host.press(first.id)
        try await downloadUIWait {
            (downloadUIView("browser.downloads.status", in: controller.view) as? UILabel)?.text ==
                String(localized: "This download cannot be saved while its removal is pending.", table: "Mobile")
        }
        #expect(source.exports.isEmpty && source.activeLeaseCount(id: first.id) == 0)
        source.entries.insert(survivor, at: 0)
        source.durableIDs.insert(survivor.id)
        source.notify()
        let otherController = BrowserMobileDownloadsViewController(downloads: source)
        let otherHost = try DownloadUIHost(otherController)
        defer { otherHost.close() }
        otherHost.layout()
        let retry = try #require(downloadUIView("browser.downloads.retry", in: otherController.view) as? UIButton)
        #expect(!retry.isHidden && retry.isEnabled)
        retry.sendActions(for: .touchUpInside)
        try await downloadUIWait { source.removedOnRetry == [first.id] }
        #expect(source.entries == [survivor] && source.removalCalls == [first.id])
        #expect(controller.tableView.tableHeaderView == nil)
        #expect(otherController.tableView.tableHeaderView == nil)
    }

    @Test(arguments: DownloadUIDeletionInvalidation.allCases)
    func capturedDownloadDeleteRevalidatesAfterConfirmation(reason: DownloadUIDeletionInvalidation) async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        let controller = BrowserMobileDownloadsViewController(downloads: source)
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        try downloadUIRequestAccessibleDelete(entry.id, in: host)
        let alert = try await downloadUIDeletionAlert(controller, in: host)
        var lease: BrowserMobileDownloadExportLease?
        defer { lease?.finish() }
        switch reason {
        case .exporting: lease = try await source.acquireExport(id: entry.id)
        case .removed: source.entries = []
            source.notify()
        case .inactive:
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: host.window.windowScene)
        case .dismissed: controller.invalidate()
        }
        controller.confirmDeletion(id: entry.id, dismissing: alert)
        if reason == .dismissed {
            alert.dismiss(animated: false)
        }
        try await downloadUIWait { alert.presentingViewController == nil }
        await downloadUIDrain()
        #expect(source.removalCalls.isEmpty && !source.canRetryPersistence)
        if reason == .exporting {
            #expect(source.activeLeaseCount(id: entry.id) == 1)
        }
    }

    @Test func missingCompletedDownloadRemainsAccessibleForDeletion() async throws {
        let entry = downloadUIEntry(status: .completed)
        let source = try DownloadUIModel(entries: [entry])
        source.entries[0].status = .failed
        source.entries[0].error = "The downloaded file is missing."
        let controller = BrowserMobileDownloadsViewController(downloads: source)
        let host = try DownloadUIHost(controller)
        defer { host.close() }
        #expect(try host.button(entry.id).isHidden)
        try downloadUIRequestAccessibleDelete(entry.id, in: host)
        let alert = try await downloadUIDeletionAlert(controller, in: host)
        controller.confirmDeletion(id: entry.id, dismissing: alert)
        try await downloadUIWait { source.entries.isEmpty }
        #expect(source.removalCalls == [entry.id])
    }

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
            #expect(source.activeLeaseCount(id: entry.id) == 1)
        }

        try await releaseOwner()
        try await downloadUIWait { releasedController == nil }
        #expect(source.observerCount == 0)
        source.finishExport(at: 0)
        await downloadUIDrain()
        #expect(presentations == 0)
        #expect(source.observerCount == 0)
        #expect(source.activeLeaseCount(id: entry.id) == 0)
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
        #expect(source.activeLeaseCount(id: entry.id) == 1)
        #expect(try !(host.button(entry.id).isEnabled))
        source.entries[0].filename = "Updated while the picker covers the list.txt"
        source.notify()

        try downloadUICancelPicker(#require(pickers.first))
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
        downloadUICancelPicker(pickers[1])
        secondCover.dismiss(animated: false)
        try await downloadUIWait { controller.view.window === host.window }
        #expect(try host.button(entry.id).isEnabled)
        #expect(source.activeLeaseCount(id: entry.id) == 0)
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
        #expect(picker.delegate === picker)
        #expect(picker.modalPresentationStyle == .formSheet && picker.shouldShowFileExtensions)
        #expect(picker.view.accessibilityIdentifier == "browser.downloads.export")
        #expect(try Data(contentsOf: url) == bytes)
        // UIKit configuration and the production export path are exercised;
        // the system Files UI is not operated by this hosted test.
        downloadUICancelPicker(picker)
        try host.press(completed.id)
        try await downloadUIWait { presented.count == 2 }
        presented[1].1.delegate?.documentPicker?(
            presented[1].1,
            didPickDocumentsAt: [directory.appendingPathComponent("export")],
        )
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
                "Button \(button.frame), vertical constraints \(button.constraintsAffectingLayout(for: .vertical))",
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
        downloadUICancelPicker(pickers[0])

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
        #expect(source.activeLeaseCount(id: entry.id) == 1)
        source.finishExport(at: 1)
        try await downloadUIWait { presentations.count == 1 }
        #expect(presentations[0].0 === controller && presentations[0].0.view.window === host.window)
        downloadUICancelPicker(presentations[0].1)
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
        #expect(source.activeLeaseCount(id: entry.id) == 0)
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
    var durableIDs: Set<UUID>
    var removalCalls = [UUID]()
    var holdsRemoval = false
    var removedOnRetry = [UUID]()

    // MARK: Private

    private let exportURL: URL
    private let clearOwnerID = UUID()
    private var leases = [UUID: UUID]()
    private var deletingIDs = Set<UUID>()
    private var pendingRemoval: UUID?
    private var removalContinuation: CheckedContinuation<Bool, Never>?
    private var observers = [UUID: @MainActor () -> Void]()
    private var continuations = [CheckedContinuation<URL, Error>]()

    var observerCount: Int { observers.count }

    var canClearCompleted: Bool { !durableIDs.isEmpty && pendingRemoval == nil }
    var isClearingCompleted: Bool { false }

    init(entries: [BrowserMobileDownload]) throws {
        self.entries = entries
        self.durableIDs = Set(entries.filter { $0.status == .completed }.map(\.id))
        self.exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadUI-\(UUID()).txt")
        try Data("A file ready for export".utf8).write(to: exportURL)
    }

    deinit { try? FileManager.default.removeItem(at: exportURL) }

    func captureCompletedClear() -> BrowserMobileDownloadClearScope? {
        canClearCompleted ? .init(ids: durableIDs, ownerID: clearOwnerID) : nil
    }

    func clearCompleted(_ scope: BrowserMobileDownloadClearScope) -> BrowserMobileDownloadClearResult {
        let survivors = scope.ids.intersection(durableIDs)
        guard survivors.allSatisfy({ canDelete(id: $0) }) else { return .busy }
        entries.removeAll { survivors.contains($0.id) }
        durableIDs.subtract(survivors)
        notify()
        return .removed
    }

    func canDelete(id: UUID) -> Bool {
        durableIDs.contains(id) && entries.contains(where: { $0.id == id }) &&
            !deletingIDs.contains(id) && !leases.values.contains(id)
    }

    func isDeleting(id: UUID) -> Bool { deletingIDs.contains(id) }
    func activeLeaseCount(id: UUID) -> Int { leases.values.count(where: { $0 == id }) }

    func remove(id: UUID) async -> Bool {
        removalCalls.append(id)
        guard canDelete(id: id) else { return false }
        deletingIDs.insert(id)
        notify()
        let succeeded: Bool =
            if holdsRemoval {
                await withCheckedContinuation { removalContinuation = $0 }
            } else {
                true
            }
        deletingIDs.remove(id)
        if succeeded {
            durableIDs.remove(id)
            entries.removeAll { $0.id == id }
        } else {
            pendingRemoval = id
            error = "The download could not be removed. Try again."
            canRetryPersistence = true
        }
        notify()
        return succeeded
    }

    func finishRemoval(succeeded: Bool) {
        removalContinuation?.resume(returning: succeeded)
        removalContinuation = nil
    }

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
        if let id = pendingRemoval {
            pendingRemoval = nil
            removedOnRetry.append(id)
            entries.removeAll { $0.id == id }
            durableIDs.remove(id)
        }
        canRetryPersistence = false
        error = nil
        notify()
    }

    func acquireExport(id: UUID) async throws -> BrowserMobileDownloadExportLease {
        guard !deletingIDs.contains(id), pendingRemoval != id else { throw BrowserMobileDownloadError.busy }
        exports.append(id)
        let token = UUID()
        leases[token] = id
        notify()
        do {
            let url: URL =
                if holdsExports {
                    try await withCheckedThrowingContinuation { continuations.append($0) }
                } else {
                    exportURL
                }
            return BrowserMobileDownloadExportLease(url: url, downloadID: id) { [self] in
                leases.removeValue(forKey: token)
                notify()
            }
        } catch {
            leases.removeValue(forKey: token)
            notify()
            throw error
        }
    }

    func finishExport(at index: Int) { continuations[index].resume(returning: exportURL) }
    func failExport(at index: Int) { continuations[index].resume(throwing: DownloadUITestError.exportFailed) }
}

// MARK: - DownloadUIHost

@MainActor private final class DownloadUIHost {
    // MARK: Internal

    let controller: BrowserMobileDownloadsViewController
    let navigation: UINavigationController
    let window: UIWindow

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
        status: status, receivedBytes: 20, totalBytes: 20, error: nil,
    )
}

@MainActor private func downloadUIView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { downloadUIView(id, in: $0) }.first
}

@MainActor private func downloadUIWait(
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool,
) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Downloads UI did not reach its expected state", sourceLocation: sourceLocation)
    throw DownloadUITestError.timeout
}

@MainActor private func downloadUIDrain() async { try? await Task.sleep(for: .milliseconds(30)) }

// MARK: - DownloadUITestError

private enum DownloadUITestError: Error { case exportFailed, timeout }

@MainActor private func downloadUICancelPicker(_ picker: UIDocumentPickerViewController) {
    picker.delegate?.documentPickerWasCancelled?(picker)
}

// MARK: - DownloadUIDeletionInvalidation

enum DownloadUIDeletionInvalidation: CaseIterable { case exporting, removed, inactive, dismissed }

@MainActor private func downloadUIDeletionAlert(
    _ controller: BrowserMobileDownloadsViewController, in host: DownloadUIHost,
    sourceLocation: SourceLocation = #_sourceLocation,
) async throws -> UIAlertController {
    try await downloadUIWait(sourceLocation: sourceLocation) {
        guard let alert = controller.presentedViewController as? UIAlertController else { return false }
        return alert.view.window === host.window && !alert.isBeingPresented
    }
    return try #require(controller.presentedViewController as? UIAlertController)
}

@MainActor private func downloadUIRequestAccessibleDelete(_ id: UUID, in host: DownloadUIHost) throws {
    let label = try #require(host.view(id, suffix: "filename"))
    let action = try #require(label.accessibilityCustomActions?.first)
    try #require(action.actionHandler?(action) == true)
}
