// OpenArcDockTile.swift

import AppKit

/// Draws the icon picked in Settings on OpenArc's Dock tile while the app is
/// not running. The Dock loads this plug-in into its own process, so it keeps
/// one icon decoded at the Dock's size and nothing else.
@MainActor
@objc(OpenArcDockTile) final class OpenArcDockTile: NSObject, @preconcurrency NSDockTilePlugIn {
    // MARK: Private

    private var dockTile: NSDockTile?
    private var observer: (any NSObjectProtocol)?

    /// OpenArc.app, which holds this plug-in in Contents/PlugIns.
    private let appURL = Bundle(for: OpenArcDockTile.self)
        .bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private lazy var appBundleIdentifier = Bundle(url: appURL)?.bundleIdentifier

    // MARK: Internal

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        guard dockTile != nil, let appBundleIdentifier else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: BrowserAppIcon.changedNotificationName(bundleIdentifier: appBundleIdentifier),
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStoredIcon() }
        }
        showStoredIcon()
    }

    private func showStoredIcon() {
        guard let dockTile, let appBundleIdentifier else { return }
        let domain = appBundleIdentifier as CFString
        // The Dock keeps its own copy of the app's defaults; read the app's latest.
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue(BrowserAppIcon.preferenceKey as CFString, domain) as? String
        dockTile.contentView = BrowserAppIcon.resourceName(preferenceValue: value).flatMap {
            iconView(resourceName: $0, size: dockTile.size)
        }
        dockTile.display()
    }

    private func iconView(resourceName: String, size: NSSize) -> NSView? {
        let url = appURL.appending(path: "Contents/Resources/\(resourceName).png", directoryHint: .notDirectory)
        guard let image = BrowserAppIcon.dockImage(contentsOf: url) else { return nil }
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        return view
    }
}
