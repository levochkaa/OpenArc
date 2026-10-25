// BrowserMobileDownloads.swift

import Foundation
import WebKit

// MARK: - BrowserMobileDownload

struct BrowserMobileDownload: Identifiable, Equatable, Codable {
    enum Status: String, Codable { case downloading, saving, completed, cancelled, failed }

    let id: UUID
    var filename: String
    var sourceURL: URL?
    var status: Status
    var receivedBytes: Int64
    var totalBytes: Int64?
    var error: String?
}

// MARK: - BrowserMobileDownloadClearScope

struct BrowserMobileDownloadClearScope: Equatable {
    // MARK: Internal

    let ids: Set<UUID>

    // MARK: Fileprivate

    fileprivate let ownerID: UUID

    var count: Int { ids.count }

    init(ids: Set<UUID>, ownerID: UUID) {
        self.ids = ids
        self.ownerID = ownerID
    }
}

// MARK: - BrowserMobileDownloadClearResult

enum BrowserMobileDownloadClearResult: Equatable {
    case removed, busy, invalidScope, failed
}

// MARK: - BrowserMobileDownloadExportLease

@MainActor final class BrowserMobileDownloadExportLease {
    // MARK: Internal

    let url: URL
    let downloadID: UUID

    // MARK: Private

    private var onFinish: (@MainActor () -> Void)?

    init(url: URL, downloadID: UUID, onFinish: @escaping @MainActor () -> Void) {
        self.url = url
        self.downloadID = downloadID
        self.onFinish = onFinish
    }

    isolated deinit { onFinish?() }

    func finish() {
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

// MARK: - BrowserMobileDownloads

/// A profile owns this coordinator independently of its windows and page views.
/// WebKit supplies and retains the transfer's authenticated request; no URL is
/// fetched again here, and authentication/TLS handling remains with WebKit.
@MainActor final class BrowserMobileDownloads: NSObject, WKDownloadDelegate {
    // MARK: Private

    private final class Transfer {
        // MARK: Internal

        let id: UUID
        let download: WKDownload

        init(id: UUID, download: WKDownload) { self.id = id
            self.download = download
        }
    }

    // MARK: Internal

    private(set) var entries = [BrowserMobileDownload]()
    private(set) var isLoading = false
    private(set) var error: String?

    private let disk: any BrowserMobileDownloadStoring
    private let clearOwnerID = UUID()
    private var activeClearScope: BrowserMobileDownloadClearScope?
    private var failedClearScope: BrowserMobileDownloadClearScope?
    private var transfers = [ObjectIdentifier: Transfer]()
    private var pendingCompletions = [UUID: BrowserMobileDownload]()
    private var completionFailures = Set<UUID>()
    private var pendingDiscards = Set<UUID>()
    private var diskCleanupIDs = Set<UUID>()
    private var persistedIDs = Set<UUID>()
    private var failedRemovals = Set<UUID>()
    private var removingIDs = Set<UUID>()
    private var exportTokens = [UUID: UUID]()
    private var latestDiskState: BrowserMobileDownloadDiskState?
    private var loadFailed = false
    private var observers = [UUID: @MainActor () -> Void]()
    private var progressTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isRetryingPersistence = false

    var canRetryPersistence: Bool {
        !hasLoaded || !completionFailures.isEmpty || !pendingDiscards.isEmpty || !diskCleanupIDs.isEmpty
            || !failedRemovals.isEmpty || failedClearScope != nil
    }

    var canClearCompleted: Bool {
        hasLoaded && activeClearScope == nil && failedClearScope == nil && !capturableCompletedIDs.isEmpty
    }

    var isClearingCompleted: Bool { activeClearScope != nil }

    private var capturableCompletedIDs: Set<UUID> {
        persistedIDs.subtracting(pendingCompletions.keys).subtracting(transfers.values.map(\.id))
    }

    init(directory: URL) {
        self.disk = BrowserMobileDownloadDisk(directory: directory)
        super.init()
    }

    init(disk: any BrowserMobileDownloadStoring) {
        self.disk = disk
        super.init()
    }

    /// A generated transfer may have no committed source page. Filtering only
    /// the engine's supplied URL would let its original-request fallback retain
    /// a blob token or the entire data URL in the durable manifest.
    static func persistentSourceURL(sourceURL: URL?, requestURL: URL?) -> URL? {
        for url in [sourceURL, requestURL].compactMap(\.self) {
            switch url.scheme?.lowercased() {
            case "http",
                 "https":
                if url.host?.isEmpty == false {
                    return url
                }
            case "about":
                if url.absoluteString.lowercased().split(separator: "#").first == "about:blank" {
                    return url
                }
            default: break
            }
        }
        return nil
    }

    func captureCompletedClear() -> BrowserMobileDownloadClearScope? {
        guard canClearCompleted else { return nil }
        return .init(ids: capturableCompletedIDs, ownerID: clearOwnerID)
    }

    func clearCompleted(_ scope: BrowserMobileDownloadClearScope) async -> BrowserMobileDownloadClearResult {
        guard scope.ownerID == clearOwnerID, !scope.ids.isEmpty else { return .invalidScope }
        guard hasLoaded, activeClearScope == nil, failedClearScope == nil else { return .busy }
        return await performClear(scope)
    }

    func canDelete(id: UUID) -> Bool {
        hasLoaded && persistedIDs.contains(id) && !removingIDs.contains(id)
            && !isReservedForClear(id)
            && !exportTokens.values.contains(id) && pendingCompletions[id] == nil
            && !transfers.values.contains(where: { $0.id == id })
    }

    func isDeleting(id: UUID) -> Bool { removingIDs.contains(id) || activeClearScope?.ids.contains(id) == true }

    func remove(id: UUID) async -> Bool {
        guard canDelete(id: id) else {
            return hasLoaded && !persistedIDs.contains(id) && !entries.contains(where: { $0.id == id })
        }
        removingIDs.insert(id)
        notify()
        defer { removingIDs.remove(id)
            notify()
        }
        do {
            let state = try await disk.removeState(id: id)
            failedRemovals.remove(id)
            publish(state)
            refreshError()
            return true
        } catch {
            failedRemovals.insert(id)
            refreshError()
            return false
        }
    }

    func acquireExport(id: UUID) async throws -> BrowserMobileDownloadExportLease {
        guard !removingIDs.contains(id), !failedRemovals.contains(id), !isReservedForClear(id) else {
            throw BrowserMobileDownloadError.busy
        }
        guard persistedIDs.contains(id), entries.contains(where: { $0.id == id && $0.status == .completed }) else {
            throw BrowserMobileDownloadError.notCompleted
        }
        let token = UUID()
        exportTokens[token] = id
        notify()
        do {
            try Task.checkCancellation()
            let url = try await disk.exportURL(id: id)
            try Task.checkCancellation()
            return BrowserMobileDownloadExportLease(url: url, downloadID: id) { [self] in
                releaseExport(token: token)
            }
        } catch {
            releaseExport(token: token)
            throw error
        }
    }

    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        notify()
        do {
            let state = try await disk.snapshot()
            publish(state)
            hasLoaded = true
            loadFailed = false
            refreshError()
        } catch {
            loadFailed = true
            refreshError()
        }
        isLoading = false
        notify()
    }

    func retryPersistence() async {
        guard !isRetryingPersistence else { return }
        isRetryingPersistence = true
        defer { isRetryingPersistence = false }
        await load()
        guard hasLoaded else { return }
        for id in Array(completionFailures) {
            if let entry = pendingCompletions[id] {
                await commitCompletion(entry)
            }
        }
        if let scope = failedClearScope, activeClearScope == nil {
            _ = await performClear(scope)
        }
        for id in Array(failedRemovals) {
            _ = await remove(id: id)
        }
        for id in Array(pendingDiscards) {
            await discardIncompleteDownload(id: id)
        }
        do {
            try await publish(disk.retryCleanup())
            refreshError()
            notify()
        } catch {
            reportCleanupFailure()
        }
    }

    func adopt(_ download: WKDownload, sourceURL: URL?) {
        let key = ObjectIdentifier(download)
        guard transfers[key] == nil else { return }
        let entry = BrowserMobileDownload(
            id: UUID(), filename: "Download",
            sourceURL: Self.persistentSourceURL(sourceURL: sourceURL, requestURL: download.originalRequest?.url),
            status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil,
        )
        transfers[key] = Transfer(id: entry.id, download: download)
        entries.insert(entry, at: 0)
        download.delegate = self
        startProgressUpdates()
        notify()
    }

    func cancel(id: UUID) {
        guard let pair = transfers.first(where: { $0.value.id == id }) else { return }
        let transfer = pair.value
        transfers.removeValue(forKey: pair.key)
        transfer.download.delegate = nil
        update(id) { $0.status = .cancelled
            $0.error = nil
        }
        stopProgressUpdatesIfIdle()
        // Wait for WebKit to stop writing before removing the partial file.
        transfer.download.cancel { [weak self, disk] _ in
            Task {
                if let self {
                    await self.discardIncompleteDownload(id: id)
                } else {
                    _ = try? await disk.discardState(id: id)
                }
            }
        }
        notify()
    }

    func exportURL(id: UUID) async throws -> URL {
        guard entries.contains(where: { $0.id == id && $0.status == .completed }) else {
            throw BrowserMobileDownloadError.notCompleted
        }
        return try await disk.exportURL(id: id)
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void,
    ) {
        let key = ObjectIdentifier(download)
        guard let transfer = transfers[key] else { completionHandler(nil)
            return
        }
        let filename = BrowserMobileDownloadDisk.safeFilename(suggestedFilename)
        update(transfer.id) {
            $0.filename = filename
            $0.totalBytes = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }
        notify()
        Task { [self] in
            let url: URL
            do {
                url = try await disk.prepare(id: transfer.id, filename: filename)
            } catch {
                fail(key: key, message: String(localized: "downloads.error.destination", table: "Mobile"))
                completionHandler(nil)
                return
            }
            guard transfers[key] === transfer else {
                completionHandler(nil)
                await discardIncompleteDownload(id: transfer.id)
                return
            }
            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let transfer = transfers.removeValue(forKey: key),
              let entry = entries.first(where: { $0.id == transfer.id }) else { return }
        download.delegate = nil
        stopProgressUpdatesIfIdle()
        pendingCompletions[entry.id] = entry
        update(entry.id) { $0.status = .saving }
        notify()
        Task { [self] in await commitCompletion(entry) }
    }

    func download(_ download: WKDownload, didFailWithError _: Error, resumeData _: Data?) {
        fail(key: ObjectIdentifier(download), message: String(localized: "downloads.error.transfer", table: "Mobile"))
    }

    /// Shared by terminal WebKit callbacks and deferred cleanup Retry.
    func discardIncompleteDownload(id: UUID) async {
        do {
            try await acceptCleanup(disk.discardState(id: id), id: id)
        } catch {
            reportCleanupFailure(id: id)
        }
    }

    private func isReservedForClear(_ id: UUID) -> Bool {
        activeClearScope?.ids.contains(id) == true || failedClearScope?.ids.contains(id) == true
    }

    private func performClear(_ scope: BrowserMobileDownloadClearScope) async -> BrowserMobileDownloadClearResult {
        let surviving = scope.ids.intersection(persistedIDs)
        let busy = removingIDs.union(failedRemovals)
            .union(exportTokens.values)
            .union(pendingCompletions.keys)
            .union(transfers.values.map(\.id))
        guard surviving.isDisjoint(with: busy) else { return .busy }
        guard !surviving.isEmpty else {
            failedClearScope = nil
            refreshError()
            notify()
            return .removed
        }
        // Reserve synchronously before disk work or observer callbacks. Failed
        // batches retain their whole captured scope for a single explicit Retry.
        activeClearScope = scope
        notify()
        defer {
            activeClearScope = nil
            notify()
        }
        do {
            let state = try await disk.removeState(ids: surviving)
            failedClearScope = nil
            publish(state)
            refreshError()
            return .removed
        } catch {
            failedClearScope = scope
            refreshError()
            return .failed
        }
    }

    private func commitCompletion(_ entry: BrowserMobileDownload) async {
        update(entry.id) { $0.status = .saving
            $0.error = nil
        }
        notify()
        do {
            let state = try await disk.completeState(entry)
            pendingCompletions.removeValue(forKey: entry.id)
            completionFailures.remove(entry.id)
            publish(state)
            refreshError()
        } catch {
            let message = String(localized: "downloads.error.save", table: "Mobile")
            completionFailures.insert(entry.id)
            update(entry.id) { $0.status = .failed
                $0.error = message
            }
            refreshError()
        }
        notify()
    }

    private func fail(key: ObjectIdentifier, message: String) {
        guard let transfer = transfers.removeValue(forKey: key) else { return }
        transfer.download.delegate = nil
        update(transfer.id) { $0.status = .failed
            $0.error = message
        }
        stopProgressUpdatesIfIdle()
        Task { [weak self, disk] in
            if let self {
                await discardIncompleteDownload(id: transfer.id)
            } else {
                _ = try? await disk.discardState(id: transfer.id)
            }
        }
        notify()
    }

    private func startProgressUpdates() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self else { return }
                var changed = false
                for transfer in transfers.values {
                    let progress = transfer.download.progress
                    let received = max(0, progress.completedUnitCount)
                    let total = progress.totalUnitCount >= 0 ? progress.totalUnitCount : nil
                    update(transfer.id) { entry in
                        if entry.receivedBytes != received || entry.totalBytes != total {
                            entry.receivedBytes = received
                            entry.totalBytes = total
                            changed = true
                        }
                    }
                }
                if changed {
                    notify()
                }
            }
        }
    }

    private func stopProgressUpdatesIfIdle() {
        guard transfers.isEmpty else { return }
        progressTask?.cancel()
        progressTask = nil
    }

    private func update(_ id: UUID, _ transform: (inout BrowserMobileDownload) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        transform(&entries[index])
    }

    private func acceptCleanup(_ state: BrowserMobileDownloadDiskState, id: UUID) {
        pendingDiscards.remove(id)
        publish(state)
        refreshError()
        notify()
    }

    private func reportCleanupFailure(id: UUID? = nil) {
        if let id {
            pendingDiscards.insert(id)
        }
        refreshError()
        if error == nil {
            error = String(localized: "downloads.error.cleanup", table: "Mobile")
        }
        notify()
    }

    private func releaseExport(token: UUID) {
        guard exportTokens.removeValue(forKey: token) != nil else { return }
        notify()
    }

    private func publish(_ state: BrowserMobileDownloadDiskState) {
        if state.revision >= (latestDiskState?.revision ?? 0) {
            latestDiskState = state
        }
        guard let state = latestDiskState else { return }
        // Even an older completion can release a transient saving guard. Always
        // reconcile against the newest disk state, never that older payload.
        let incomingIDs = Set(state.entries.map(\.id))
        let protectedIDs = Set(transfers.values.map(\.id)).union(pendingCompletions.keys)
        entries
            .removeAll { persistedIDs.contains($0.id) && !incomingIDs.contains($0.id) && !protectedIDs.contains($0.id) }
        for entry in state.entries {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                if !protectedIDs.contains(entry.id) {
                    entries[index] = entry
                }
            } else {
                entries.append(entry)
            }
        }
        persistedIDs = incomingIDs
        failedRemovals.formIntersection(incomingIDs)
        diskCleanupIDs = state.pendingCleanupIDs
    }

    private func refreshError() {
        error =
            if loadFailed {
                String(localized: "downloads.error.load", table: "Mobile")
            } else if failedClearScope != nil {
                String(localized: "downloads.error.clear", table: "Mobile")
            } else if !failedRemovals.isEmpty {
                String(localized: "downloads.error.remove", table: "Mobile")
            } else if !completionFailures.isEmpty {
                String(localized: "downloads.error.save", table: "Mobile")
            } else if !pendingDiscards.isEmpty || !diskCleanupIDs.isEmpty {
                String(
                    localized: "downloads.error.cleanup",
                    table: "Mobile",
                )
            } else {
                nil
            }
    }

    private func notify() {
        for id in Array(observers.keys) {
            observers[id]?()
        }
    }
}
