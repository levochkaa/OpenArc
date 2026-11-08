// BrowserCaptureToastView.swift

import AppKit

// MARK: - BrowserCaptureToastView

/// A small note at the page's top right after a capture, before the first one,
/// after Copy URL or a zoom change. It takes the Space's pale color and leaves
/// by itself.
final class BrowserCaptureToastView: NSView {
    // MARK: Internal

    static let didCopyNotification = Notification.Name("BrowserCaptureDidCopy")

    static let height: CGFloat = 42
    static let copiedURLHeight: CGFloat = 46
    static let zoomHeight: CGFloat = 41.5

    override var isFlipped: Bool { true }

    /// Where the note sits against the page's top trailing corner, or nil for
    /// the window's.
    private(set) var pageCornerInset: CGSize?

    /// The height of what it shows now.
    private(set) var preferredHeight = BrowserCaptureToastView.height

    var fill = NSColor.windowBackgroundColor { didSet { surface.fillColor = fill } }

    /// The width it wants, for the root view to place it.
    private(set) var preferredWidth: CGFloat = 0

    private let surface = BrowserNativeSurface()
    private let label = NSTextField(labelWithString: "")
    private let saveButton = BrowserCaptureToastButton(title: BrowserStrings.captureToastSave)
    private let shareButton = BrowserCaptureToastButton(symbol: "square.and.arrow.up")
    private let keys = BrowserNativeSurface()
    private let keysLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var fadesOut = false
    private var labelLeading: CGFloat = 12
    private var labelOffset: CGFloat = 0
    private var png: Data?
    private var copiedURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        surface.cornerRadius = 12
        surface.strokeWidth = 0
        addSubview(surface)
        for view in [label, trailingLabel, keysLabel] {
            view.font = .systemFont(ofSize: 14, weight: .medium)
            view.textColor = .black
            view.lineBreakMode = .byClipping
        }
        keys.cornerRadius = 5
        keys.strokeWidth = 0
        keys.fillColor = NSColor.black.withAlphaComponent(0.1)
        keys.addSubview(keysLabel)
        for view in [label, saveButton, shareButton, keys, trailingLabel] as [NSView] {
            surface.addSubview(view)
        }
        saveButton.onClick = { [weak self] in self?.save() }
        shareButton.onClick = { [weak self] in self?.share() }
        isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let height = bounds.height
        let y = (height - 18) / 2
        var x = labelLeading
        label.frame = NSRect(x: x, y: y + labelOffset, width: textWidth(label), height: 18)
        x = label.frame.maxX + 6
        if !keys.isHidden {
            keys.frame = NSRect(x: x, y: (Self.height - 24) / 2, width: textWidth(keysLabel) + 12, height: 24)
            keysLabel.frame = NSRect(x: 6, y: 3, width: textWidth(keysLabel), height: 18)
            x = keys.frame.maxX + 6
            trailingLabel.frame = NSRect(x: x, y: y, width: textWidth(trailingLabel), height: 18)
        }
        if !saveButton.isHidden {
            saveButton.frame = NSRect(x: x + 4, y: (height - 28) / 2, width: 48, height: 28)
            shareButton.frame = NSRect(x: saveButton.frame.maxX + 6, y: (height - 28) / 2, width: 32, height: 28)
        } else if !shareButton.isHidden {
            shareButton.frame = NSRect(x: x + 4, y: (height - 28) / 2, width: 32, height: 28)
        }
    }

    /// The page's new zoom, such as "110%", for five seconds.
    func showZoom(percent: Int) {
        png = nil
        copiedURL = nil
        preferredHeight = Self.zoomHeight
        pageCornerInset = CGSize(width: 8.5, height: 8)
        labelLeading = 10.5
        labelOffset = 1
        label.stringValue = "\(percent)%"
        keys.isHidden = true
        trailingLabel.isHidden = true
        saveButton.isHidden = true
        shareButton.isHidden = true
        preferredWidth = labelLeading * 2 + textWidth(label)
        show(for: 4.8, fading: true)
    }

    /// "Copied Current URL" and Share, after Copy URL from the menu or its shortcut.
    func showCopiedURL(_ url: URL) {
        pageCornerInset = CGSize(width: 9, height: 8)
        labelLeading = 12
        labelOffset = 0
        png = nil
        copiedURL = url
        preferredHeight = Self.copiedURLHeight
        label.stringValue = BrowserStrings.copiedCurrentURLToast
        keys.isHidden = true
        trailingLabel.isHidden = true
        saveButton.isHidden = true
        shareButton.isHidden = false
        preferredWidth = 12 + textWidth(label) + 10 + 32 + 10
        show(for: 3)
    }

    /// "Screenshot Copied to Clipboard", Save and Share.
    func showCopied(png: Data) {
        pageCornerInset = nil
        labelLeading = 12
        labelOffset = 0
        copiedURL = nil
        preferredHeight = Self.height
        self.png = png
        label.stringValue = BrowserStrings.captureToastCopied
        keys.isHidden = true
        trailingLabel.isHidden = true
        saveButton.isHidden = false
        shareButton.isHidden = false
        preferredWidth = 12 + textWidth(label) + 10 + 48 + 6 + 32 + 8
        show(for: 5)
    }

    /// The way to capture without the menu.
    func showHint(keysText: String) {
        pageCornerInset = nil
        labelLeading = 12
        labelOffset = 0
        png = nil
        copiedURL = nil
        preferredHeight = Self.height
        label.stringValue = BrowserStrings.captureToastHintLeading
        keysLabel.stringValue = keysText
        trailingLabel.stringValue = BrowserStrings.captureToastHintTrailing
        keys.isHidden = false
        trailingLabel.isHidden = false
        saveButton.isHidden = true
        shareButton.isHidden = true
        preferredWidth = 12 + textWidth(label) + 6 + textWidth(keysLabel) + 12 + 6 + textWidth(trailingLabel) + 12
        show(for: 4)
    }

    private func show(for seconds: TimeInterval, fading: Bool = false) {
        hideWork?.cancel()
        layer?.removeAllAnimations()
        isHidden = false
        alphaValue = 1
        fadesOut = fading
        superview?.needsLayout = true
        needsLayout = true
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        guard fadesOut else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        }
    }

    private func textWidth(_ field: NSTextField) -> CGFloat {
        ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width) + 4
    }

    private func save() {
        guard let png, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = BrowserStrings.captureFileName
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    private func share() {
        if let copiedURL {
            NSSharingServicePicker(items: [copiedURL])
                .show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
            return
        }
        guard let png else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(BrowserStrings.captureFileName + ".png")
        guard (try? png.write(to: url)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }
}

// MARK: - BrowserCaptureToastButton

private final class BrowserCaptureToastButton: NSView {
    // MARK: Internal

    var onClick: () -> Void = {}

    private let content: NSView

    init(title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .black
        label.alignment = .center
        self.content = label
        super.init(frame: .zero)
        setUp()
    }

    init(symbol: String) {
        let image = NSImageView(image: NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: BrowserStrings.tabShareAction,
        ) ?? NSImage())
        image.contentTintColor = .black
        self.content = image
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height: CGFloat = content is NSTextField ? 17 : 16
        content.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func mouseUp(with _: NSEvent) { onClick() }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        addSubview(content)
    }
}
