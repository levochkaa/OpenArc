// BrowserMobileDownloadRemovalIntegrationTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func nativeClearRejectsAnotherWindowsExportThenPreservesLaterCompletion() async throws {
        try await withDownloadRemovalFixture { f in
            var pickers = [UIDocumentPickerViewController]()
            let first = try DownloadRemovalHost(downloads: f.downloads)
            let second = try DownloadRemovalHost(downloads: f.downloads) { pickers.append($0) }
            defer { first.close()
                second.close()
            }
            try await removalWait { !f.downloads.isLoading }
            let busyAlert = try await first.requestClear()
            #expect(busyAlert.message?.contains("2") == true)
            try second.export(f.first.id)
            try await removalWait { pickers.count == 1 }
            first.controller.confirmClearCompleted(dismissing: busyAlert)
            try await removalWait {
                (removalView("browser.downloads.status", in: first.controller.view) as? UILabel)?.text ==
                    "Finish any Save to Files actions or retry pending deletions, then try Clear Completed again."
            }
            #expect(!f.downloads.canRetryPersistence && f.downloads.entries.count == 2)
            #expect(try Data(contentsOf: f.firstURL) == f.firstBytes)
            #expect(try Data(contentsOf: f.secondURL) == f.secondBytes)
            let picker = try #require(pickers.first)
            picker.delegate?.documentPickerWasCancelled?(picker)
            await f.downloads.retryPersistence()
            #expect(f.downloads.entries.count == 2)

            let alert = try await first.requestClear()
            #expect(alert.message?.contains("2") == true)
            let laterBytes = Data("Completed while confirmation was open".utf8)
            let later = try await f.completeLater(bytes: laterBytes)
            #expect(f.downloads.entries.count == 3)
            // An old alert callback cannot consume the newer confirmation.
            first.controller.confirmClearCompleted(dismissing: busyAlert)
            #expect(first.controller.presentedViewController === alert)
            first.controller.confirmClearCompleted(dismissing: alert)
            try await removalWait { f.downloads.entries.map(\.id) == [later.id] }
            try await removalWait { first.rowCount == 1 && second.rowCount == 1 }
            #expect(!FileManager.default.fileExists(atPath: f.firstURL.path))
            #expect(!FileManager.default.fileExists(atPath: f.secondURL.path))
            #expect(try await Data(contentsOf: f.downloads.exportURL(id: later.id)) == laterBytes)
            #expect(f.downloads.error == nil && !f.downloads.canRetryPersistence)
            for host in [first, second] {
                #expect(host.controller.tableView.tableHeaderView == nil)
            }
            let reopened = BrowserMobileDownloads(directory: f.directory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [later.id])
        }
    }

    @Test func failedNativeClearRetriesItsOriginalBatchFromAnotherWindow() async throws {
        try await withDownloadRemovalFixture { f in
            let first = try DownloadRemovalHost(downloads: f.downloads)
            let second = try DownloadRemovalHost(downloads: f.downloads)
            defer { first.close()
                second.close()
            }
            try await removalWait { !f.downloads.isLoading }
            let manifest = f.directory.appendingPathComponent("downloads.json")
            let original = try Data(contentsOf: manifest)
            let alert = try await first.requestClear()
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            first.controller.confirmClearCompleted(dismissing: alert)
            try await removalWait { f.downloads.canRetryPersistence && !f.downloads.isClearingCompleted }
            #expect(f.downloads.entries.count == 2)
            #expect(try Data(contentsOf: f.firstURL) == f.firstBytes)
            #expect(try Data(contentsOf: f.secondURL) == f.secondBytes)
            #expect(!f.downloads.canDelete(id: f.first.id) && !f.downloads.canDelete(id: f.second.id))
            try FileManager.default.removeItem(at: manifest)
            try original.write(to: manifest, options: .atomic)
            let laterBytes = Data("Must survive Retry".utf8)
            let later = try await f.completeLater(bytes: laterBytes)
            #expect(f.downloads.entries.count == 3 && f.downloads.canDelete(id: later.id))
            #expect(!f.downloads.canClearCompleted)
            let retry = try #require(removalView("browser.downloads.retry", in: second.controller.view) as? UIButton)
            try #require(!retry.isHidden && retry.isEnabled)
            retry.sendActions(for: .touchUpInside)
            try await removalWait { f.downloads.entries.map(\.id) == [later.id] && !f.downloads.canRetryPersistence }
            try await removalWait { first.rowCount == 1 && second.rowCount == 1 }
            #expect(f.downloads.error == nil && f.downloads.canClearCompleted)
            #expect(!FileManager.default.fileExists(atPath: f.firstURL.path))
            #expect(!FileManager.default.fileExists(atPath: f.secondURL.path))
            for host in [first, second] {
                #expect(host.controller.tableView.tableHeaderView == nil)
            }
            let reopened = BrowserMobileDownloads(directory: f.directory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [later.id])
            #expect(try await Data(contentsOf: reopened.exportURL(id: later.id)) == laterBytes)
        }
    }

    @Test func twoDownloadWindowsHoldIndependentExportsBeforeDeletingTheCapturedFile() async throws {
        try await withDownloadRemovalFixture { f in
            var firstPickers = [UIDocumentPickerViewController]()
            var secondPickers = [UIDocumentPickerViewController]()
            let first = try DownloadRemovalHost(downloads: f.downloads) { firstPickers.append($0) }
            let second = try DownloadRemovalHost(downloads: f.downloads) { secondPickers.append($0) }
            defer { first.close()
                second.close()
            }
            try await removalWait { !f.downloads.isLoading }
            try first.export(f.first.id)
            try await removalWait { firstPickers.count == 1 }
            try second.export(f.first.id)
            try await removalWait { secondPickers.count == 1 }
            #expect(!f.downloads.canDelete(id: f.first.id))
            #expect(await !f.downloads.remove(id: f.first.id))
            #expect(!f.downloads.canRetryPersistence)
            #expect(try Data(contentsOf: f.firstURL) == f.firstBytes)

            let oldPicker = firstPickers[0]
            oldPicker.delegate?.documentPickerWasCancelled?(oldPicker)
            #expect(!f.downloads.canDelete(id: f.first.id))
            try first.export(f.first.id)
            try await removalWait { firstPickers.count == 2 }
            // A callback from the first picker must not release the newer
            // export in the same window, nor the other window's reservation.
            oldPicker.delegate?.documentPickerWasCancelled?(oldPicker)
            let otherPicker = secondPickers[0]
            otherPicker.delegate?.documentPickerWasCancelled?(otherPicker)
            #expect(!f.downloads.canDelete(id: f.first.id))
            #expect(await !f.downloads.remove(id: f.first.id))
            let currentPicker = firstPickers[1]
            currentPicker.delegate?.documentPickerWasCancelled?(currentPicker)
            try await removalWait { f.downloads.canDelete(id: f.first.id) }

            let alert = try await second.requestDeletion(f.first.id)
            second.controller.confirmDeletion(id: f.first.id, dismissing: alert)
            try await removalWait { !f.downloads.entries.contains { $0.id == f.first.id } }
            try await removalWait { first.rowCount == 1 && second.rowCount == 1 }
            try await removalWait { !FileManager.default.fileExists(atPath: f.firstURL.path) }
            #expect(try Data(contentsOf: f.secondURL) == f.secondBytes)
            #expect(f.downloads.error == nil)
            for host in [first, second] {
                let status = removalView("browser.downloads.status", in: host.controller.view) as? UILabel
                #expect(status?.text == nil)
            }
            let reopened = BrowserMobileDownloads(directory: f.directory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [f.second.id])
            #expect(try await Data(contentsOf: reopened.exportURL(id: f.second.id)) == f.secondBytes)
        }
    }

    @Test func retainedNativePickerKeepsItsFileAfterTheDownloadsOwnerIsReleased() async throws {
        try await withDownloadRemovalFixture { f in
            var retainedPicker: UIDocumentPickerViewController?
            weak var releasedController: BrowserMobileDownloadsViewController?
            @MainActor func releaseOwner() async throws {
                let host = try DownloadRemovalHost(downloads: f.downloads) { retainedPicker = $0 }
                releasedController = host.controller
                defer { host.close() }
                try await removalWait { !f.downloads.isLoading }
                try host.export(f.first.id)
                try await removalWait { retainedPicker != nil }
            }
            try await releaseOwner()
            try await removalWait { releasedController == nil }
            #expect(!f.downloads.canDelete(id: f.first.id))
            #expect(await !f.downloads.remove(id: f.first.id))
            #expect(try Data(contentsOf: f.firstURL) == f.firstBytes)
            let picker = try #require(retainedPicker)
            try #require(picker.delegate != nil)
            picker.delegate?.documentPickerWasCancelled?(picker)
            try await removalWait { f.downloads.canDelete(id: f.first.id) }
            #expect(await f.downloads.remove(id: f.first.id))
            try await removalWait { !FileManager.default.fileExists(atPath: f.firstURL.path) }
            retainedPicker = nil
        }
    }

    @Test func failedNativeDownloadDeletionRetriesFromTheOtherWindowWithoutLosingFiles() async throws {
        try await withDownloadRemovalFixture { f in
            let first = try DownloadRemovalHost(downloads: f.downloads)
            let second = try DownloadRemovalHost(downloads: f.downloads)
            defer { first.close()
                second.close()
            }
            try await removalWait { !f.downloads.isLoading }
            let manifest = f.directory.appendingPathComponent("downloads.json")
            let original = try Data(contentsOf: manifest)
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            let alert = try await first.requestDeletion(f.first.id)
            first.controller.confirmDeletion(id: f.first.id, dismissing: alert)
            try await removalWait { f.downloads.canRetryPersistence && !f.downloads.isDeleting(id: f.first.id) }
            #expect(f.downloads.entries.count == 2 && first.rowCount == 2 && second.rowCount == 2)
            #expect(try Data(contentsOf: f.firstURL) == f.firstBytes)
            #expect(try Data(contentsOf: f.secondURL) == f.secondBytes)
            try FileManager.default.removeItem(at: manifest)
            try original.write(to: manifest, options: .atomic)
            let retry = try #require(removalView("browser.downloads.retry", in: second.controller.view) as? UIButton)
            try #require(!retry.isHidden && retry.isEnabled)
            retry.sendActions(for: .touchUpInside)
            try await removalWait { f.downloads.entries.map(\.id) == [f.second.id] && !f.downloads.canRetryPersistence }
            try await removalWait { first.rowCount == 1 && second.rowCount == 1 }
            try await removalWait { !FileManager.default.fileExists(atPath: f.firstURL.path) }
            #expect(try Data(contentsOf: f.secondURL) == f.secondBytes)
            #expect(f.downloads.error == nil)
            for host in [first, second] {
                let status = removalView("browser.downloads.status", in: host.controller.view) as? UILabel
                #expect(status?.text == nil)
            }
            let reopened = BrowserMobileDownloads(directory: f.directory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [f.second.id])
        }
    }
}

@MainActor private func withDownloadRemovalFixture(
    _ body: @MainActor (DownloadRemovalFixture) async throws -> Void,
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRemoval-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = DownloadRemovalFixture(directory: directory)
    try await fixture.prepare()
    try await body(fixture)
}

// MARK: - DownloadRemovalFixture

@MainActor private final class DownloadRemovalFixture {
    // MARK: Internal

    let directory: URL
    let disk: BrowserMobileDownloadDisk
    let downloads: BrowserMobileDownloads
    let firstBytes = Data("First completed file".utf8)
    let secondBytes = Data("Second file with the same display name".utf8)
    private(set) var first = BrowserMobileDownload(
        id: UUID(), filename: "download.txt", sourceURL: URL(string: "https://example.com/first"),
        status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil,
    )
    private(set) var second = BrowserMobileDownload(
        id: UUID(), filename: "download.txt", sourceURL: URL(string: "https://example.com/second"),
        status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil,
    )

    var firstURL: URL { directory.appendingPathComponent(first.id.uuidString).appendingPathComponent(first.filename) }
    var secondURL: URL { directory.appendingPathComponent(second.id.uuidString).appendingPathComponent(second.filename)
    }

    init(directory: URL) {
        self.directory = directory
        self.disk = BrowserMobileDownloadDisk(directory: directory)
        self.downloads = BrowserMobileDownloads(disk: disk)
    }

    func prepare() async throws {
        let firstFile = try await disk.prepare(id: first.id, filename: first.filename)
        try firstBytes.write(to: firstFile)
        first = try await disk.complete(first)
        let secondFile = try await disk.prepare(id: second.id, filename: second.filename)
        try secondBytes.write(to: secondFile)
        second = try await disk.complete(second)
        await downloads.load()
        try #require(downloads.entries.count == 2 && downloads.error == nil)
    }

    func completeLater(bytes: Data) async throws -> BrowserMobileDownload {
        let entry = BrowserMobileDownload(
            id: UUID(), filename: "later.txt", sourceURL: URL(string: "https://example.com/later"),
            status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil,
        )
        let file = try await disk.prepare(id: entry.id, filename: entry.filename)
        try bytes.write(to: file)
        let saved = try await disk.complete(entry)
        await downloads.load()
        return saved
    }
}

// MARK: - DownloadRemovalHost

@MainActor private final class DownloadRemovalHost {
    // MARK: Internal

    let controller: BrowserMobileDownloadsViewController
    let navigation: UINavigationController
    let window: UIWindow

    var rowCount: Int { controller.tableView.numberOfRows(inSection: 0) }

    init(
        downloads: BrowserMobileDownloads,
        onPicker: @escaping (UIDocumentPickerViewController) -> Void = { _ in },
    ) throws {
        self.controller = BrowserMobileDownloadsViewController(downloads: downloads) { _, picker in onPicker(picker) }
        self.navigation = UINavigationController(rootViewController: controller)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
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

    func export(_ id: UUID) throws {
        layout()
        let button = try #require(removalView("browser.downloads.\(id).action", in: controller.view) as? UIButton)
        try #require(!button.isHidden && button.isEnabled)
        button.sendActions(for: .touchUpInside)
    }

    func requestDeletion(_ id: UUID) async throws -> UIAlertController {
        layout()
        let table = controller.tableView!
        let index = try #require((0..<rowCount).first { row in
            table.cellForRow(at: IndexPath(row: row, section: 0))?.accessibilityIdentifier == "browser.downloads.\(id)"
        })
        let path = IndexPath(row: index, section: 0)
        let cell = try #require(table.cellForRow(at: path))
        let configuration = try #require(controller.tableView(table, trailingSwipeActionsConfigurationForRowAt: path))
        #expect(!configuration.performsFirstActionWithFullSwipe)
        let action = try #require(configuration.actions.first)
        #expect(action.style == .destructive && action.title == "Delete")
        action.handler(action, cell) { _ in }
        try await removalWait { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        try await removalWait { !alert.isBeingPresented }
        #expect(alert.preferredStyle == .alert)
        #expect(alert.actions.contains { $0.style == .cancel })
        #expect(alert.actions.contains { $0.style == .destructive })
        return alert
    }

    func requestClear() async throws -> UIAlertController {
        let button = try #require(controller.navigationItem.leftBarButtonItems?.first {
            $0.accessibilityIdentifier == "browser.downloads.clear-completed"
        })
        try await removalWait { button.isEnabled }
        try #require(button.isEnabled)
        let action = try #require(button.action)
        #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
        try await removalWait { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        try await removalWait { !alert.isBeingPresented }
        #expect(alert.view.accessibilityIdentifier == "browser.downloads.clear-confirmation")
        #expect(alert.actions.contains { $0.style == .cancel })
        #expect(alert.actions.contains { $0.style == .destructive })
        return alert
    }

    func close() { controller.invalidate()
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor private func removalView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { removalView(id, in: $0) }.first
}

@MainActor private func removalWait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Download removal did not reach its expected state")
    throw URLError(.timedOut)
}
