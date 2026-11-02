// BrowserScreenSharePicker.swift

import AppKit
import ScreenCaptureKit

// MARK: - BrowserScreenShareSource

/// Something a page can capture, in Chromium's naming: "screen:1:0" or "window:9:0".
struct BrowserScreenShareSource: Equatable {
    let mediaID: String
    let title: String
    let detail: String?

    static func screen(id: UInt32, title: String) -> BrowserScreenShareSource {
        .init(mediaID: "screen:\(id):0", title: title, detail: nil)
    }

    static func window(id: UInt32, title: String, app: String?) -> BrowserScreenShareSource {
        .init(mediaID: "window:\(id):0", title: title, detail: app)
    }
}

// MARK: - BrowserScreenSharePicker

/// Chooses what a page's getDisplayMedia captures: a sheet of screens and windows
/// with live pictures. Without Screen Recording permission, only the main screen.
@MainActor @objc final class BrowserScreenSharePicker: NSObject {
    // MARK: Internal

    private weak var window: NSWindow?
    private let origin: String
    private var completion: ((String?) -> Void)?
    private var panel: NSPanel?
    private var tiles = [BrowserScreenShareTile]()
    private var selected: BrowserScreenShareSource?
    private let shareButton = NSButton()
    private let documentView = NSView()
    private let scroll = NSScrollView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton()
    private var loadTask: Task<Void, Never>?

    @objc(initWithWindow:origin:completion:)
    init(window: NSWindow?, origin: String, completion: @escaping (String?) -> Void) {
        self.window = window
        self.origin = origin
        self.completion = completion
        super.init()
    }

    @objc func present() {
        guard panel == nil, completion != nil else { return }
        guard let window, window.attachedSheet == nil else {
            finish(with: nil)
            return
        }
        let panel = makePanel()
        self.panel = panel
        window.beginSheet(panel)
        loadTask = Task { [weak self] in await self?.load() }
    }

    @objc func cancel() { finish(with: nil) }

    // MARK: Private

    private func finish(with mediaID: String?) {
        guard let completion else { return }
        self.completion = nil
        loadTask?.cancel()
        if let panel {
            panel.sheetParent?.endSheet(panel)
        }
        completion(mediaID)
    }

    private func makePanel() -> NSPanel {
        let width: CGFloat = 660
        let height: CGFloat = 500
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: true,
        )
        panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return panel }
        let host = URLComponents(string: origin)?.host ?? origin
        let title = NSTextField(labelWithString: String(format: BrowserStrings.screenShareTitle, host))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: height - 40, width: width - 40, height: 22)
        content.addSubview(title)

        scroll.frame = NSRect(x: 20, y: 66, width: width - 40, height: height - 116)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        content.addSubview(scroll)

        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 66, width: width - 40, height: 40)
        note.isHidden = true
        content.addSubview(note)

        settingsButton.title = BrowserStrings.screenShareOpenSettings
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.sizeToFit()
        settingsButton.frame.origin = NSPoint(x: 20, y: 18)
        settingsButton.isHidden = true
        content.addSubview(settingsButton)

        shareButton.title = BrowserStrings.screenShareAction
        shareButton.bezelStyle = .rounded
        shareButton.keyEquivalent = "\r"
        shareButton.target = self
        shareButton.action = #selector(share)
        shareButton.isEnabled = false
        shareButton.sizeToFit()
        shareButton.frame.origin = NSPoint(x: width - 20 - shareButton.frame.width, y: 18)
        shareButton.setAccessibilityIdentifier("browser.screen-share.share")
        content.addSubview(shareButton)

        let cancelButton = NSButton(
            title: BrowserStrings.screenShareCancel,
            target: self,
            action: #selector(cancelPressed),
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.sizeToFit()
        cancelButton.frame.origin = NSPoint(x: shareButton.frame.minX - 8 - cancelButton.frame.width, y: 18)
        cancelButton.setAccessibilityIdentifier("browser.screen-share.cancel")
        content.addSubview(cancelButton)
        return panel
    }

    @objc private func share() { finish(with: selected?.mediaID) }
    @objc private func cancelPressed() { finish(with: nil) }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func load() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            let own = Bundle.main.bundleIdentifier
            let screens = content.displays.enumerated().map { index, display in
                (BrowserScreenShareSource.screen(
                    id: display.displayID,
                    title: "\(BrowserStrings.screenShareScreens)\(content.displays.count > 1 ? " \(index + 1)" : "")",
                ), SCContentFilter(display: display, excludingWindows: []), CGSize(
                    width: display.width,
                    height: display.height,
                ))
            }
            let windows = content.windows.compactMap { item -> (BrowserScreenShareSource, SCContentFilter, CGSize)? in
                guard item.windowLayer == 0, item.frame.width > 80, item.frame.height > 80,
                      let title = item.title, !title.isEmpty, item.owningApplication?.bundleIdentifier != own
                else { return nil }
                return (
                    .window(id: item.windowID, title: title, app: item.owningApplication?.applicationName),
                    SCContentFilter(desktopIndependentWindow: item),
                    item.frame.size,
                )
            }
            show(screens.map(\.0) + windows.map(\.0))
            for (source, filter, size) in screens + windows {
                guard !Task.isCancelled else { return }
                let configuration = SCStreamConfiguration()
                let scale = min(320 / max(size.width, 1), 200 / max(size.height, 1), 1)
                configuration.width = max(Int(size.width * scale), 1)
                configuration.height = max(Int(size.height * scale), 1)
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration,
                ) {
                    tiles.first { $0.source == source }?.setPicture(NSImage(cgImage: image, size: .zero))
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            // No permission yet: the main screen still works, and macOS asks when it starts.
            show([.screen(id: CGMainDisplayID(), title: BrowserStrings.screenShareScreens)])
            note.stringValue = BrowserStrings.screenShareNeedsPermission
            note.isHidden = false
            settingsButton.isHidden = false
            scroll.frame.origin.y = 112
            scroll.frame.size.height -= 46
        }
    }

    private func show(_ sources: [BrowserScreenShareSource]) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = sources.map { source in
            BrowserScreenShareTile(source: source) { [weak self] tile, activated in
                guard let self else { return }
                selected = tile.source
                tiles.forEach { $0.isChosen = $0 === tile }
                shareButton.isEnabled = true
                if activated { share() }
            }
        }
        let columns = 3
        let size = BrowserScreenShareTile.size
        let rows = (tiles.count + columns - 1) / columns
        let width = scroll.contentSize.width
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(CGFloat(rows) * (size.height + 10), scroll.contentSize.height),
        )
        let columnWidth = width / CGFloat(columns)
        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            tile.frame = NSRect(
                x: CGFloat(index % columns) * columnWidth + (columnWidth - size.width) / 2,
                y: documentView.frame.height - CGFloat(row + 1) * (size.height + 10),
                width: size.width,
                height: size.height,
            )
            documentView.addSubview(tile)
        }
        if let first = tiles.first, selected == nil {
            selected = first.source
            first.isChosen = true
            shareButton.isEnabled = true
        }
    }
}

// MARK: - BrowserScreenShareTile

final class BrowserScreenShareTile: NSView {
    // MARK: Internal

    static let size = CGSize(width: 190, height: 150)

    let source: BrowserScreenShareSource

    var isChosen = false {
        didSet {
            layer?.borderColor = isChosen ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    private let picture = NSImageView()
    private let onChoose: (BrowserScreenShareTile, Bool) -> Void

    init(source: BrowserScreenShareSource, onChoose: @escaping (BrowserScreenShareTile, Bool) -> Void) {
        self.source = source
        self.onChoose = onChoose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(source.title)
        picture.frame = NSRect(x: 8, y: 44, width: Self.size.width - 16, height: Self.size.height - 52)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(picture)
        let title = NSTextField(labelWithString: source.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 8, y: 22, width: Self.size.width - 16, height: 16)
        addSubview(title)
        let detail = NSTextField(labelWithString: source.detail ?? "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 8, y: 6, width: Self.size.width - 16, height: 14)
        addSubview(detail)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onChoose(self, event.clickCount >= 2) }

    func setPicture(_ image: NSImage) { picture.image = image }
}
