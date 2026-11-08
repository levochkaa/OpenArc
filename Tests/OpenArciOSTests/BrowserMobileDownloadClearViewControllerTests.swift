// BrowserMobileDownloadClearViewControllerTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func clearCompletedButtonCapturesCountAndIDsOnceAndCancelHasNoEffect() async throws {
        let first = clearUIEntry("First.txt")
        let missing = clearUIEntry("Missing.txt", status: .failed)
        let active = clearUIEntry("Active.txt", status: .downloading)
        let saving = clearUIEntry("Saving.txt", status: .saving)
        let failedTransfer = clearUIEntry("Failed transfer.txt", status: .failed)
        let source = ClearUIModel(
            entries: [first, missing, active, saving, failedTransfer], durableIDs: [first.id, missing.id],
        )
        let host = try ClearUIHost(source)
        defer { host.close() }
        let cancelled = try await host.openClear()
        #expect(cancelled.preferredStyle == .alert)
        #expect(cancelled.actions.contains { $0.style == .destructive })
        #expect(cancelled.actions.contains { $0.style == .cancel })
        #expect(cancelled.message == String(
            format: String(
                localized: "Remove %d completed downloads from this browser? Copies saved to Files will remain.",
                table: "Mobile",
            ), 2,
        ))
        #expect(source.captures.count == 1 && source.clearCalls.isEmpty)
        #expect(!host.clearButton.isEnabled)
        // A duplicate native action cannot recapture or widen the open alert.
        try host.sendClearAction()
        #expect(source.captures.count == 1)
        host.controller.cancelClearCompleted(dismissing: cancelled)
        try await clearUIWait { cancelled.presentingViewController == nil && host.clearButton.isEnabled }
        #expect(source.clearCalls.isEmpty && source.entries.count == 5)

        let confirmed = try await host.openClear()
        let captured = try #require(source.captures.last)
        #expect(captured.ids == [first.id, missing.id])
        let later = clearUIEntry("Completed after confirmation.txt")
        source.appendDurable(later)
        #expect(source.captures.count == 2 && confirmed.message == cancelled.message)
        host.controller.confirmClearCompleted(dismissing: confirmed)
        try await clearUIWait { source.clearCalls.count == 1 && !source.durableIDs.contains(first.id) }
        #expect(source.clearCalls == [captured])
        #expect(Set(source.entries.map(\.id)) == [active.id, saving.id, failedTransfer.id, later.id])
        host.controller.confirmClearCompleted(dismissing: confirmed)
        host.controller.confirmClearCompleted(dismissing: cancelled)
        await clearUIDrain()
        #expect(source.clearCalls == [captured])
        #expect(host.controller.tableView.numberOfRows(inSection: 0) == 4)
    }

    @Test func oldClearCallbackCannotConsumeANewerConfirmation() async throws {
        let entry = clearUIEntry("Only.txt")
        let source = ClearUIModel(entries: [entry])
        let host = try ClearUIHost(source)
        defer { host.close() }
        let old = try await host.openClear()
        host.controller.cancelClearCompleted(dismissing: old)
        try await clearUIWait { old.presentingViewController == nil && host.clearButton.isEnabled }
        let current = try await host.openClear()
        host.controller.confirmClearCompleted(dismissing: old)
        host.controller.cancelClearCompleted(dismissing: old)
        #expect(host.controller.presentedViewController === current && source.clearCalls.isEmpty)
        host.controller.confirmClearCompleted(dismissing: current)
        host.controller.confirmClearCompleted(dismissing: current)
        try await clearUIWait { source.clearCalls.count == 1 && source.entries.isEmpty }
        #expect(!host.clearButton.isEnabled)
    }

    @Test(arguments: ClearUIUnavailableOwner.allCases)
    func clearConfirmationRequiresItsOriginalActiveAttachedWindow(reason: ClearUIUnavailableOwner) async throws {
        let entry = clearUIEntry("Kept.txt")
        let source = ClearUIModel(entries: [entry])
        let host = try ClearUIHost(source)
        defer { host.close() }
        let alert = try await host.openClear()
        var replacement: UIWindow?
        defer {
            replacement?.isHidden = true
            replacement?.rootViewController = nil
        }
        switch reason {
        case .hidden:
            host.window.isHidden = true
        case .done:
            let done = try #require(host.controller.navigationItem.rightBarButtonItem)
            let action = try #require(done.action)
            #expect(UIApplication.shared.sendAction(action, to: done.target, from: done, for: nil))
        case .disconnected,
             .inactive:
            NotificationCenter.default.post(
                name: reason == .inactive ? UIScene.willDeactivateNotification : UIScene.didDisconnectNotification,
                object: host.window.windowScene,
            )
            // An old callback must stay invalid even if the scene resumes.
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: host.window.windowScene)
        case .differentWindow:
            let scene = try #require(host.window.windowScene)
            let moved = UIWindow(windowScene: scene)
            moved.frame = host.window.frame
            host.window.rootViewController = nil
            moved.rootViewController = host.navigation
            moved.makeKeyAndVisible()
            moved.layoutIfNeeded()
            replacement = moved
            try #require(host.controller.view.window === moved)
        }
        host.controller.confirmClearCompleted(dismissing: alert)
        // Teardown can make UIKit omit a dismissal animation. It is not a
        // confirmation and must never manufacture model work.
        alert.dismiss(animated: false)
        await clearUIDrain()
        #expect(source.clearCalls.isEmpty && source.entries == [entry])
        #expect(!source.canRetryPersistence)
    }

    @Test func busyClearIsAllOrNoneAndNeedsANewExplicitAction() async throws {
        let first = clearUIEntry("First.txt")
        let second = clearUIEntry("Second.txt")
        let source = ClearUIModel(entries: [first, second])
        let host = try ClearUIHost(source)
        defer { host.close() }
        let alert = try await host.openClear()
        source.busyIDs.insert(second.id)
        source.notify()
        host.controller.confirmClearCompleted(dismissing: alert)
        try await clearUIWait { source.clearCalls.count == 1 && host.statusText == clearUIBusyMessage }
        #expect(source.entries == [first, second] && !source.canRetryPersistence)
        source.busyIDs.removeAll()
        source.notify()
        await clearUIDrain()
        #expect(source.clearCalls.count == 1 && source.entries.count == 2)
        let other = try ClearUIHost(source)
        defer { other.close() }
        let explicit = try await other.openClear()
        let later = clearUIEntry("Later.txt")
        source.appendDurable(later)
        other.controller.confirmClearCompleted(dismissing: explicit)
        try await clearUIWait { source.entries == [later] }
        #expect(source.clearCalls.count == 2 && host.statusText != clearUIBusyMessage)
        #expect(host.controller.tableView.tableHeaderView == nil)
    }

    @Test func failedClearShowsSharedRetryAndNeverCopiesItsErrorIntoTheList() async throws {
        let first = clearUIEntry("First.txt")
        let second = clearUIEntry("Second.txt")
        let source = ClearUIModel(entries: [first, second])
        source.holdsClear = true
        let host = try ClearUIHost(source)
        defer { host.close() }
        let alert = try await host.openClear()
        let captured = try #require(source.captures.last)
        host.controller.confirmClearCompleted(dismissing: alert)
        try await clearUIWait { source.isClearingCompleted }
        #expect(!host.clearButton.isEnabled)
        try host.sendClearAction()
        #expect(source.captures == [captured])
        let status = try #require(host.rowView(first.id, suffix: "status") as? UILabel)
        #expect(status.text == String(localized: "Deleting…", table: "Mobile"))
        let export = try #require(host.rowView(first.id, suffix: "action") as? UIButton)
        #expect(!export.isEnabled)
        #expect(host.controller.tableView(
            host.controller.tableView, trailingSwipeActionsConfigurationForRowAt: .init(row: 0, section: 0),
        ) == nil)
        let later = clearUIEntry("Later.txt")
        source.appendDurable(later)
        source.finishClear(.failed)
        try await clearUIWait { source.canRetryPersistence && !source.isClearingCompleted }
        #expect(source.entries == [first, second, later] && host.statusText == ClearUIModel.failureMessage)
        #expect(!host.clearButton.isEnabled)
        let other = try ClearUIHost(source)
        defer { other.close() }
        let retry = try #require(clearUIView("browser.downloads.retry", in: other.controller.view) as? UIButton)
        #expect(retry.isEnabled && !retry.isHidden)
        retry.sendActions(for: .touchUpInside)
        try await clearUIWait { source.retriedScopes == [captured] && source.entries == [later] }
        #expect(source.clearCalls == [captured])
        #expect(host.statusText != ClearUIModel.failureMessage && other.statusText != ClearUIModel.failureMessage)
        #expect(host.controller.tableView.tableHeaderView == nil && other.controller.tableView.tableHeaderView == nil)
    }

    @Test func deleteAndClearConfirmationsCannotOverlapAndInvalidScopeHasNoRetry() async throws {
        let entry = clearUIEntry("Kept.txt")
        let source = ClearUIModel(entries: [entry])
        let host = try ClearUIHost(source)
        defer { host.close() }
        let swipe = try #require(host.controller.tableView(
            host.controller.tableView, trailingSwipeActionsConfigurationForRowAt: .init(row: 0, section: 0),
        ))
        let delete = try #require(swipe.actions.first)
        delete.handler(delete, host.controller.view) { _ in }
        try await clearUIWait { host.controller.presentedViewController is UIAlertController }
        let deletion = try #require(host.controller.presentedViewController as? UIAlertController)
        #expect(!host.clearButton.isEnabled)
        try host.sendClearAction()
        #expect(source.captures.isEmpty && host.controller.presentedViewController === deletion)
        host.controller.cancelDeletion(dismissing: deletion)
        try await clearUIWait { deletion.presentingViewController == nil && host.clearButton.isEnabled }
        let clear = try await host.openClear()
        delete.handler(delete, host.controller.view) { _ in }
        #expect(host.controller.presentedViewController === clear)
        source.nextResult = .invalidScope
        host.controller.confirmClearCompleted(dismissing: clear)
        try await clearUIWait {
            host.statusText == String(
                localized: "This Clear Completed request is no longer available.",
                table: "Mobile",
            )
        }
        #expect(source.entries == [entry] && source.removals.isEmpty && !source.canRetryPersistence)
    }

    @Test(arguments: [false, true])
    func queuedConfirmedRemovalRechecksOwnerBeforeCallingTheModel(clear: Bool) async throws {
        let entry = clearUIEntry("Kept.txt")
        let source = ClearUIModel(entries: [entry])
        let host = try ClearUIHost(source)
        defer { host.close() }
        let alert: UIAlertController
        if clear {
            alert = try await host.openClear()
        } else {
            let swipe = try #require(host.controller.tableView(
                host.controller.tableView, trailingSwipeActionsConfigurationForRowAt: .init(row: 0, section: 0),
            ))
            let action = try #require(swipe.actions.first)
            action.handler(action, host.controller.view) { _ in }
            try await clearUIWait { host.controller.presentedViewController is UIAlertController }
            alert = try #require(host.controller.presentedViewController as? UIAlertController)
            try await clearUIWait { !alert.isBeingPresented }
        }
        var invalidated = false
        // A synchronous model read made by the busy-state render invalidates
        // the owner before the newly enqueued main-actor Task can begin. Delete
        // also reads once to revalidate its entry before scheduling the Task.
        var readsBeforeInvalidation = clear ? 0 : 1
        source.onEntriesRead = { [weak controller = host.controller] in
            if readsBeforeInvalidation > 0 {
                readsBeforeInvalidation -= 1
                return
            }
            source.onEntriesRead = nil
            invalidated = true
            controller?.invalidate()
        }
        if clear {
            host.controller.confirmClearCompleted(dismissing: alert)
        } else {
            host.controller.confirmDeletion(id: entry.id, dismissing: alert)
        }
        try await clearUIWait { invalidated }
        await clearUIDrain()
        #expect(source.clearCalls.isEmpty && source.removals.isEmpty && source.entries == [entry])
    }

    @Test(arguments: [320.0, 700.0])
    func clearCompletedSingularConfirmationAndNativeControlsFitCompactWidths(width: Double) async throws {
        let source = ClearUIModel(entries: [clearUIEntry("One.txt")])
        let host = try ClearUIHost(source, width: width)
        defer { host.close() }
        host.navigation.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await host.waitUntilReady()
        host.layout()
        #expect(host.clearButton.accessibilityIdentifier == "browser.downloads.clear-completed")
        #expect(host.clearButton.title == String(localized: "Clear Completed…", table: "Mobile"))
        let bar = host.navigation.navigationBar
        // UIKit can render a system Done item as an icon. Identify the mounted
        // items through their public accessibility IDs, not a label subtree.
        // iOS 27's glass bar no longer copies an item's ID to its button; the
        // Clear button is then the one showing its title, Done the other one.
        let barButtons = clearUIBarButtons(in: bar)
        let titledClear = barButtons.first { clearUILabel(host.clearButton.title ?? "", in: $0) }
        let clearControl = try #require(
            clearUIView("browser.downloads.clear-completed", in: bar) ?? titledClear,
            "Clear control missing: \(clearUIHierarchy(bar))",
        )
        let doneControl = try #require(
            clearUIView("browser.downloads.done", in: bar) ?? barButtons.first { $0 !== titledClear },
            "Done control missing: \(clearUIHierarchy(bar))",
        )
        let clearRect = clearControl.convert(clearControl.bounds, to: bar)
        let doneRect = doneControl.convert(doneControl.bounds, to: bar)
        #expect(clearRect.width > 0 && clearRect.minX >= 0)
        #expect(doneRect.width > 0 && !doneControl.isHidden && !clearControl.isHidden)
        #expect(clearRect.maxX <= doneRect.minX && doneRect.maxX <= host.navigation.navigationBar.bounds.maxX)
        let alert = try await host.openClear()
        #expect(alert.message == String(
            localized: "Remove this completed download from this browser? Copies saved to Files will remain.",
            table: "Mobile",
        ))
        #expect(source.captures.first?.count == 1)
        host.controller.cancelClearCompleted(dismissing: alert)
        try await clearUIWait { alert.presentingViewController == nil }
        #expect(source.clearCalls.isEmpty)
    }
}

// MARK: - ClearUIUnavailableOwner

enum ClearUIUnavailableOwner: CaseIterable { case hidden, done, inactive, disconnected, differentWindow }

// MARK: - ClearUIModel

@MainActor private final class ClearUIModel: BrowserMobileDownloadsPresenting {
    // MARK: Internal

    static let failureMessage = "The completed downloads could not be removed. Try again."

    var onEntriesRead: (@MainActor () -> Void)?
    var durableIDs: Set<UUID>
    var isLoading = false
    var error: String?
    var isClearingCompleted = false
    var busyIDs = Set<UUID>()
    var captures = [BrowserMobileDownloadClearScope]()
    var clearCalls = [BrowserMobileDownloadClearScope]()
    var retriedScopes = [BrowserMobileDownloadClearScope]()
    var removals = [UUID]()
    var holdsClear = false
    var nextResult = BrowserMobileDownloadClearResult.removed

    // MARK: Private

    private let ownerID = UUID()
    private var storedEntries: [BrowserMobileDownload]
    private var observers = [UUID: @MainActor () -> Void]()
    private var completion: CheckedContinuation<BrowserMobileDownloadClearResult, Never>?
    private var failedScope: BrowserMobileDownloadClearScope?
    private var reservedIDs = Set<UUID>()

    var entries: [BrowserMobileDownload] {
        get {
            onEntriesRead?()
            return storedEntries
        }
        set { storedEntries = newValue }
    }

    var canRetryPersistence: Bool { failedScope != nil }
    var canClearCompleted: Bool { !durableIDs.isEmpty && !isClearingCompleted && failedScope == nil }

    init(entries: [BrowserMobileDownload], durableIDs: Set<UUID>? = nil) {
        self.storedEntries = entries
        self.durableIDs = durableIDs ?? Set(entries.filter { $0.status == .completed }.map(\.id))
    }

    func captureCompletedClear() -> BrowserMobileDownloadClearScope? {
        guard canClearCompleted else { return nil }
        let scope = BrowserMobileDownloadClearScope(ids: durableIDs, ownerID: ownerID)
        captures.append(scope)
        return scope
    }

    func clearCompleted(_ scope: BrowserMobileDownloadClearScope) async -> BrowserMobileDownloadClearResult {
        clearCalls.append(scope)
        let current = scope.ids.intersection(durableIDs)
        guard current.isDisjoint(with: busyIDs) else { return .busy }
        isClearingCompleted = true
        reservedIDs = current
        notify()
        let result: BrowserMobileDownloadClearResult =
            if holdsClear {
                await withCheckedContinuation { completion = $0 }
            } else {
                nextResult
            }
        isClearingCompleted = false
        switch result {
        case .removed:
            discard(scope)
            reservedIDs = []
        case .failed:
            failedScope = scope
            error = Self.failureMessage
        case .busy,
             .invalidScope:
            reservedIDs = []
        }
        notify()
        return result
    }

    func finishClear(_ result: BrowserMobileDownloadClearResult) {
        completion?.resume(returning: result)
        completion = nil
    }

    func retryPersistence() {
        if let failedScope {
            retriedScopes.append(failedScope)
            discard(failedScope)
        }
        failedScope = nil
        reservedIDs = []
        error = nil
        notify()
    }

    func canDelete(id: UUID) -> Bool {
        durableIDs.contains(id) && !busyIDs.contains(id) && !reservedIDs.contains(id)
    }

    func isDeleting(id: UUID) -> Bool { isClearingCompleted && reservedIDs.contains(id) }

    func remove(id: UUID) -> Bool {
        removals.append(id)
        guard canDelete(id: id) else { return false }
        entries.removeAll { $0.id == id }
        durableIDs.remove(id)
        notify()
        return true
    }

    func load() {}
    func cancel(id _: UUID) {}
    func acquireExport(id _: UUID) throws -> BrowserMobileDownloadExportLease {
        throw BrowserMobileDownloadError.busy
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
    func appendDurable(_ entry: BrowserMobileDownload) {
        entries.append(entry)
        durableIDs.insert(entry.id)
        notify()
    }

    private func discard(_ scope: BrowserMobileDownloadClearScope) {
        entries.removeAll { scope.ids.contains($0.id) }
        durableIDs.subtract(scope.ids)
    }
}

// MARK: - ClearUIHost

@MainActor private final class ClearUIHost {
    // MARK: Internal

    let controller: BrowserMobileDownloadsViewController
    let navigation: UINavigationController
    let window: UIWindow

    var clearButton: UIBarButtonItem { controller.navigationItem.leftBarButtonItem! }
    var statusText: String? { (clearUIView("browser.downloads.status", in: controller.view) as? UILabel)?.text }

    init(_ source: ClearUIModel, width: Double = 390) throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        try #require(scene.activationState == .foregroundActive)
        self.controller = BrowserMobileDownloadsViewController(downloads: source)
        self.navigation = UINavigationController(rootViewController: controller)
        self.window = UIWindow(windowScene: scene)
        window.frame.size = CGSize(width: width, height: 900)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        layout()
    }

    func sendClearAction() throws {
        let action = try #require(clearButton.action)
        #expect(UIApplication.shared.sendAction(action, to: clearButton.target, from: clearButton, for: nil))
    }

    func openClear(sourceLocation: SourceLocation = #_sourceLocation) async throws -> UIAlertController {
        try await waitUntilReady(sourceLocation: sourceLocation)
        try #require(clearButton.isEnabled, sourceLocation: sourceLocation)
        try sendClearAction()
        try await clearUIWait(sourceLocation: sourceLocation) {
            self.controller.presentedViewController is UIAlertController
        }
        let alert = try #require(
            controller.presentedViewController as? UIAlertController,
            sourceLocation: sourceLocation,
        )
        #expect(
            alert.view.accessibilityIdentifier == "browser.downloads.clear-confirmation",
            sourceLocation: sourceLocation,
        )
        try await clearUIWait(sourceLocation: sourceLocation) {
            !alert.isBeingPresented && alert.view.window === self.window
        }
        return alert
    }

    func waitUntilReady(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await clearUIWait(sourceLocation: sourceLocation) {
            self.layout()
            return self.controller.viewIfLoaded?.window === self.window &&
                self.navigation.transitionCoordinator == nil && self.clearButton.isEnabled
        }
    }

    func rowView(_ id: UUID, suffix: String) -> UIView? {
        layout()
        return clearUIView("browser.downloads." + id.uuidString + "." + suffix, in: controller.view)
    }

    func layout() {
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.tableView.layoutIfNeeded()
    }

    func close() {
        controller.invalidate()
        window.isHidden = true
        window.rootViewController = nil
    }
}

private var clearUIBusyMessage: String {
    String(
        localized: "Finish any Save to Files actions or retry pending deletions, then try Clear Completed again.",
        table: "Mobile",
    )
}

private func clearUIEntry(
    _ filename: String,
    status: BrowserMobileDownload.Status = .completed,
) -> BrowserMobileDownload {
    .init(id: UUID(), filename: filename, sourceURL: nil, status: status, receivedBytes: 20, totalBytes: 20, error: nil)
}

@MainActor private func clearUIView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { clearUIView(id, in: $0) }.first
}

/// The buttons a navigation bar draws for its items, leading to trailing.
@MainActor private func clearUIBarButtons(in view: UIView) -> [UIView] {
    var found = [UIView]()
    func visit(_ view: UIView) {
        if String(describing: type(of: view)).hasSuffix("ButtonBarButton") {
            found.append(view)
            return
        }
        view.subviews.forEach(visit)
    }
    visit(view)
    return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
}

@MainActor private func clearUILabel(_ text: String, in view: UIView) -> Bool {
    if let label = view as? UILabel, label.text == text {
        return true
    }
    return view.subviews.contains { clearUILabel(text, in: $0) }
}

@MainActor private func clearUIHierarchy(_ view: UIView) -> String {
    let current = "\(type(of: view)) id=\(view.accessibilityIdentifier ?? "nil") " +
        "label=\(view.accessibilityLabel ?? "nil") bounds=\(view.bounds) hidden=\(view.isHidden)"
    return ([current] + view.subviews.map(clearUIHierarchy)).joined(separator: "\n")
}

@MainActor private func clearUIWait(
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool,
) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Clear Completed UI did not reach its expected state", sourceLocation: sourceLocation)
    throw ClearUITestError.timeout
}

@MainActor private func clearUIDrain() async { try? await Task.sleep(for: .milliseconds(40)) }

// MARK: - ClearUITestError

private enum ClearUITestError: Error { case timeout }
