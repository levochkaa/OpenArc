import Foundation
import WebKit

// MARK: - BrowserMobileDownload

struct BrowserMobileDownload: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Sendable { case downloading, saving, completed, cancelled, failed }

    let id: UUID
    var filename: String
    var sourceURL: URL?
    var status: Status
    var receivedBytes: Int64
    var totalBytes: Int64?
    var error: String?
}

// MARK: - BrowserMobileDownloads

/// A profile owns this coordinator independently of its windows and page views.
/// WebKit supplies and retains the transfer's authenticated request; no URL is
/// fetched again here, and authentication/TLS handling remains with WebKit.
@MainActor final class BrowserMobileDownloads: NSObject, WKDownloadDelegate {
    // MARK: Lifecycle

    init(directory: URL) {
        self.disk = BrowserMobileDownloadDisk(directory: directory)
        super.init()
    }

    // MARK: Internal

    private(set) var entries = [BrowserMobileDownload]()
    private(set) var isLoading = false
    private(set) var error: String?

    var canRetryPersistence: Bool { !hasLoaded || !completionFailures.isEmpty || !pendingDiscards.isEmpty }

    /// A generated transfer may have no committed source page. Filtering only
    /// the engine's supplied URL would let its original-request fallback retain
    /// a blob token or the entire data URL in the durable manifest.
    static func persistentSourceURL(sourceURL: URL?, requestURL: URL?) -> URL? {
        for url in [sourceURL, requestURL].compactMap({ $0 }) {
            switch url.scheme?.lowercased() {
            case "http", "https":
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
            let restored = try await disk.load()
            let protectedIDs = Set(transfers.values.map(\.id)).union(pendingCompletions.keys)
            for entry in restored {
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    if !protectedIDs.contains(entry.id) {
                        entries[index] = entry
                    }
                } else {
                    entries.append(entry)
                }
            }
            hasLoaded = true
            if completionFailures.isEmpty, pendingDiscards.isEmpty {
                error = nil
            }
        } catch {
            self.error = String(localized: "downloads.error.load", table: "Mobile")
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
        for id in Array(pendingDiscards) {
            await discard(id: id)
        }
    }

    func adopt(_ download: WKDownload, sourceURL: URL?) {
        let key = ObjectIdentifier(download)
        guard transfers[key] == nil else { return }
        let entry = BrowserMobileDownload(
            id: UUID(), filename: "Download",
            sourceURL: Self.persistentSourceURL(sourceURL: sourceURL, requestURL: download.originalRequest?.url),
            status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil
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
                do { try await disk.discard(id: id) }
                catch { self?.reportCleanupFailure(id: id) }
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
        completionHandler: @escaping @MainActor (URL?) -> Void
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
                await discard(id: transfer.id)
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

    // MARK: Private

    private final class Transfer {
        // MARK: Lifecycle

        init(id: UUID, download: WKDownload) { self.id = id
            self.download = download
        }

        // MARK: Internal

        let id: UUID
        let download: WKDownload
    }

    private let disk: BrowserMobileDownloadDisk
    private var transfers = [ObjectIdentifier: Transfer]()
    private var pendingCompletions = [UUID: BrowserMobileDownload]()
    private var completionFailures = Set<UUID>()
    private var pendingDiscards = Set<UUID>()
    private var observers = [UUID: @MainActor () -> Void]()
    private var progressTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isRetryingPersistence = false

    private func commitCompletion(_ entry: BrowserMobileDownload) async {
        update(entry.id) { $0.status = .saving
            $0.error = nil
        }
        notify()
        do {
            let saved = try await disk.complete(entry)
            pendingCompletions.removeValue(forKey: entry.id)
            completionFailures.remove(entry.id)
            update(entry.id) { $0 = saved }
            if completionFailures.isEmpty, pendingDiscards.isEmpty {
                error = nil
            }
        } catch {
            let message = String(localized: "downloads.error.save", table: "Mobile")
            self.error = message
            completionFailures.insert(entry.id)
            update(entry.id) { $0.status = .failed
                $0.error = message
            }
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
            do { try await disk.discard(id: transfer.id) }
            catch { self?.reportCleanupFailure(id: transfer.id) }
        }
        notify()
    }

    private func startProgressUpdates() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
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

    private func discard(id: UUID) async {
        do {
            try await disk.discard(id: id)
            pendingDiscards.remove(id)
            if completionFailures.isEmpty, pendingDiscards.isEmpty {
                error = nil
            }
            notify()
        } catch { reportCleanupFailure(id: id) }
    }

    private func reportCleanupFailure(id: UUID) {
        pendingDiscards.insert(id)
        error = String(localized: "downloads.error.cleanup", table: "Mobile")
        notify()
    }

    private func notify() {
        for id in Array(observers.keys) {
            observers[id]?()
        }
    }
}
