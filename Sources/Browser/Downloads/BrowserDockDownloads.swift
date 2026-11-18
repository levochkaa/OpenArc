// BrowserDockDownloads.swift

import AppKit

// MARK: - BrowserDockDownloadProgress

/// What the Dock icon shows while files download: how many, and how far along
/// they are together.
struct BrowserDockDownloadProgress: Equatable {
    let activeCount: Int
    /// Bytes received over bytes expected, for the downloads whose size is known;
    /// nil when none is.
    let fraction: Double?

    var badgeLabel: String? {
        activeCount > 0 ? String(activeCount) : nil
    }

    init(items: [BrowserDownloadItem]) {
        let active = items.filter { !$0.state.isFinished }
        self.activeCount = active.count
        let sized = active.filter { $0.totalBytes > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = sized.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
        self.fraction = total > 0 ? min(max(Double(received) / Double(total), 0), 1) : nil
    }
}

// MARK: - BrowserDockDownloads

/// The Dock icon's download badge and progress bar, across every window.
@MainActor final class BrowserDockDownloads {
    // MARK: Internal

    static let shared = BrowserDockDownloads()

    // MARK: Private

    private static let redrawInterval: TimeInterval = 0.25

    private let models = NSHashTable<BrowserDownloadsModel>.weakObjects()
    private var isUpdateScheduled = false
    private var shown: BrowserDockDownloadProgress?

    /// Each window's downloads list joins when it is made.
    func register(_ model: BrowserDownloadsModel) {
        models.add(model)
        update()
    }

    /// Called when a window's downloads change; redraws at most a few times a second.
    func setNeedsUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redrawInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.isUpdateScheduled = false
                self?.update()
            }
        }
    }

    private func update() {
        let progress = BrowserDockDownloadProgress(items: models.allObjects.flatMap(\.items))
        guard progress != shown else { return }
        shown = progress
        let tile = NSApp.dockTile
        tile.badgeLabel = progress.badgeLabel
        if progress.activeCount > 0, let fraction = progress.fraction {
            let view = tile.contentView as? BrowserDockProgressView ?? BrowserDockProgressView()
            view.fraction = fraction
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

// MARK: - BrowserDockProgressView

/// The app's icon with a progress bar along its bottom, as the Dock draws a tile.
final class BrowserDockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(
            x: bounds.width * 0.12,
            y: bounds.height * 0.1,
            width: bounds.width * 0.76,
            height: bounds.height * 0.09,
        )
        let radius = bar.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        let inset = bar.insetBy(dx: bar.height * 0.18, dy: bar.height * 0.18)
        var filled = inset
        filled.size.width = max(inset.width * fraction, inset.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
