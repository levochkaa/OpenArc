// BrowserDownloads.swift

import AppKit
import Combine
import Foundation

// MARK: - BrowserDownloadState

enum BrowserDownloadState: String, Equatable {
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

struct BrowserDownloadItem: Identifiable, Equatable {
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

    var hasActiveDownloads: Bool {
        items.contains { !$0.state.isFinished }
    }

    var finishedDownloadCount: Int {
        items.filter(\.state.isFinished).count
    }

    init(
        dateProvider: @escaping () -> Date = Date.init,
        workspace: NSWorkspace = .shared,
    ) {
        self.dateProvider = dateProvider
        self.workspace = workspace
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
    }

    func clearFinishedDownloads() {
        items.removeAll { $0.state.isFinished }
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
