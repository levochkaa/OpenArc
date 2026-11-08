// BrowserDownloads.swift

import AppKit
import Combine
import Foundation

// MARK: - BrowserDownloadState

enum BrowserDownloadState: String, Codable, Equatable {
    case inProgress
    case completed
    case canceled
    case interrupted

    // MARK: Internal

    var isFinished: Bool {
        switch self {
        case .canceled,
             .completed,
             .interrupted:
            true
        case .inProgress:
            false
        }
    }
}

// MARK: - BrowserDownloadLaunch

struct BrowserDownloadLaunch: Equatable {
    let id: String
    let fileName: String
}

// MARK: - BrowserDownloadUpdate

struct BrowserDownloadUpdate: Equatable {
    let id: String
    let fileName: String
    let urlString: String
    let fullPath: String?
    let receivedBytes: Int64
    let totalBytes: Int64
    let currentSpeedBytesPerSecond: Int64
    let state: BrowserDownloadState
}

// MARK: - BrowserDownloadItem

struct BrowserDownloadItem: Identifiable, Codable, Equatable {
    let id: String
    var fileName: String
    var urlString: String
    var fullPath: String?
    var receivedBytes: Int64
    var totalBytes: Int64
    var currentSpeedBytesPerSecond: Int64
    var state: BrowserDownloadState
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?

    var progressFraction: Double? {
        guard totalBytes > 0 else {
            return nil
        }

        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    var fileURL: URL? {
        guard let fullPath, !fullPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: fullPath, isDirectory: false)
    }

    func withID(_ id: String) -> Self {
        Self(
            id: id, fileName: fileName, urlString: urlString, fullPath: fullPath, receivedBytes: receivedBytes,
            totalBytes: totalBytes, currentSpeedBytesPerSecond: currentSpeedBytesPerSecond, state: state,
            startedAt: startedAt, updatedAt: updatedAt, finishedAt: finishedAt,
        )
    }
}

// MARK: - BrowserDownloadHistory

/// A profile's finished downloads, kept in a file so that the Library and the
/// sidebar's tray list them after a relaunch. Every window of the profile
/// records into it and hears what the others record.
@MainActor final class BrowserDownloadHistory {
    static let didChangeNotification = Notification.Name("BrowserDownloadHistoryDidChange")
    static let maximumItems = 300

    private(set) var items: [BrowserDownloadItem]

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        let data = fileURL.flatMap { try? Data(contentsOf: $0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // The engine numbers downloads anew at each launch; kept ones get ids of their own.
        self.items = (data.flatMap { try? decoder.decode([BrowserDownloadItem].self, from: $0) } ?? [])
            .filter(\.state.isFinished)
            .map { $0.withID("kept-" + UUID().uuidString) }
    }

    func record(_ item: BrowserDownloadItem) {
        guard item.state.isFinished else { return }
        var item = item
        item.currentSpeedBytesPerSecond = 0
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        items = Array(items.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maximumItems))
        changed()
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        items = []
        changed()
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - BrowserDownloadsModel

@MainActor final class BrowserDownloadsModel: ObservableObject {
    // MARK: Private

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    // MARK: Internal

    @Published private(set) var items = [BrowserDownloadItem]()

    /// Stops a running download in the engine; set by the window's model.
    var onCancel: ((String) -> Void)?

    private let dateProvider: () -> Date
    private let workspace: NSWorkspace
    private let history: BrowserDownloadHistory?
    private var historyObserver: NSObjectProtocol?

    var hasActiveDownloads: Bool {
        items.contains { !$0.state.isFinished }
    }

    var finishedDownloadCount: Int {
        items.filter(\.state.isFinished).count
    }

    init(
        dateProvider: @escaping () -> Date = Date.init,
        workspace: NSWorkspace = .shared,
        history: BrowserDownloadHistory? = nil,
    ) {
        self.dateProvider = dateProvider
        self.workspace = workspace
        self.history = history
        guard let history else { return }
        self.items = history.items
        self.historyObserver = NotificationCenter.default.addObserver(
            forName: BrowserDownloadHistory.didChangeNotification,
            object: history,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeHistory() }
        }
    }

    isolated deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    func apply(_ update: BrowserDownloadUpdate) {
        let now = dateProvider()
        // A page may suggest nothing at first: the file on disk has the name that counts.
        let savedName = update.fullPath.map { ($0 as NSString).lastPathComponent } ?? ""
        let fileName = savedName.isEmpty
            ? sanitizedFileName(update.fileName, fallbackURLString: update.urlString)
            : savedName

        if let index = items.firstIndex(where: { $0.id == update.id }) {
            items[index].fileName = fileName
            items[index].urlString = update.urlString
            items[index].fullPath = update.fullPath ?? items[index].fullPath
            items[index].receivedBytes = max(update.receivedBytes, 0)
            items[index].totalBytes = max(update.totalBytes, 0)
            items[index].currentSpeedBytesPerSecond = max(update.currentSpeedBytesPerSecond, 0)
            items[index].state = update.state
            items[index].updatedAt = now
            if update.state.isFinished, items[index].finishedAt == nil {
                items[index].finishedAt = now
            } else if !update.state.isFinished {
                items[index].finishedAt = nil
            }
            history?.record(items[index])
            return
        }

        items.insert(
            BrowserDownloadItem(
                id: update.id,
                fileName: fileName,
                urlString: update.urlString,
                fullPath: update.fullPath,
                receivedBytes: max(update.receivedBytes, 0),
                totalBytes: max(update.totalBytes, 0),
                currentSpeedBytesPerSecond: max(update.currentSpeedBytesPerSecond, 0),
                state: update.state,
                startedAt: now,
                updatedAt: now,
                finishedAt: update.state.isFinished ? now : nil,
            ),
            at: 0,
        )
        history?.record(items[0])
    }

    func clearFinishedDownloads() {
        items.removeAll { $0.state.isFinished }
        history?.removeAll()
    }

    func cancel(_ item: BrowserDownloadItem) {
        guard item.state == .inProgress else { return }
        onCancel?(item.id)
    }

    func open(_ item: BrowserDownloadItem) {
        guard let fileURL = item.fileURL else {
            return
        }

        workspace.open(fileURL)
    }

    func reveal(_ item: BrowserDownloadItem) {
        guard let fileURL = item.fileURL else {
            return
        }

        workspace.activateFileViewerSelecting([fileURL])
    }

    func statusTitle(for item: BrowserDownloadItem) -> String {
        switch item.state {
        case .inProgress:
            BrowserStrings.downloadsStatusInProgress
        case .completed:
            BrowserStrings.downloadsStatusCompleted
        case .canceled:
            BrowserStrings.downloadsStatusCanceled
        case .interrupted:
            BrowserStrings.downloadsStatusInterrupted
        }
    }

    func detailText(for item: BrowserDownloadItem) -> String {
        switch item.state {
        case .completed:
            BrowserStrings.downloadsCompletedDetail
        case .canceled:
            BrowserStrings.downloadsCanceledDetail
        case .interrupted:
            BrowserStrings.downloadsInterruptedDetail
        case .inProgress:
            progressDetailText(for: item)
        }
    }

    /// What other windows of the profile finished, and a clear made in one of them.
    private func mergeHistory() {
        guard let history else { return }
        let recorded = Dictionary(history.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = items.filter { !$0.state.isFinished || recorded[$0.id] != nil }
        let known = Set(merged.map(\.id))
        merged += history.items.filter { !known.contains($0.id) }
        merged.sort { $0.startedAt > $1.startedAt }
        if merged != items {
            items = merged
        }
    }

    private func sanitizedFileName(_ fileName: String, fallbackURLString: String) -> String {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFileName.isEmpty {
            return trimmedFileName
        }

        if
            let url = URL(string: fallbackURLString),
            !url.lastPathComponent.isEmpty
        {
            return url.lastPathComponent
        }

        return BrowserStrings.downloadsDefaultFileName
    }

    private func progressDetailText(for item: BrowserDownloadItem) -> String {
        let received = byteString(item.receivedBytes)
        let speed = item.currentSpeedBytesPerSecond > 0
            ? byteString(item.currentSpeedBytesPerSecond)
            : nil

        if item.totalBytes > 0 {
            let total = byteString(item.totalBytes)
            if let speed {
                return BrowserStrings.downloadsProgressKnownTotalWithSpeed(
                    received: received,
                    total: total,
                    speed: speed,
                )
            }

            return BrowserStrings.downloadsProgressKnownTotal(received: received, total: total)
        }

        if let speed {
            return BrowserStrings.downloadsProgressUnknownTotalWithSpeed(received: received, speed: speed)
        }

        return BrowserStrings.downloadsProgressUnknownTotal(received)
    }

    private func byteString(_ byteCount: Int64) -> String {
        Self.byteCountFormatter.string(fromByteCount: max(byteCount, 0))
    }
}
