// BrowserDeveloperToolbarView.swift

import AppKit

/// The bar above a page in Developer Mode: the full address in a fixed-width
/// font, with the developer tools and page actions at its end.
final class BrowserDeveloperToolbarView: NSView {
    // MARK: Internal

    static let height: CGFloat = 40

    override var isFlipped: Bool { true }

    private let model: BrowserChromeModel
    private let lock = NSImageView()
    private let address = NSTextField(labelWithString: "")
    private let actions: [[BrowserNativeChromeButton]]
    private var separators = [NSView]()

    // MARK: Private

    private var tint: NSColor {
        let key = model.selectedSpaceTheme?.palette?.key.nsColor ?? NSColor(white: 0.3, alpha: 1)
        return key.blended(withFraction: 0.45, of: .black) ?? key
    }

    init(model: BrowserChromeModel) {
        self.model = model
        func button(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> BrowserNativeChromeButton {
            BrowserNativeChromeButton(
                symbol: symbol,
                title: title,
                style: .chrome,
                pressEffect: .compress,
                action: action,
            )
        }
        self.actions = [
            [button("link", BrowserStrings.tabCopyURLAction) { [weak model] in _ = model?.copySelectedTabLink() }],
            [button("camera", BrowserCommands.captureArea.helpTitle) { [weak model] in model?.beginAreaCapture() }],
            [
                button("apple.terminal", BrowserStrings.menuJavaScriptConsole) { [weak model] in
                    model?.showJavaScriptConsole()
                },
                button("globe", BrowserStrings.menuNetworkInspector) { [weak model] in model?.showNetworkInspector() },
                button("scope", BrowserStrings.menuInspectElements) { [weak model] in model?.inspectElements() },
            ],
            [
                button("puzzlepiece.extension", BrowserStrings.menuOpenExtensions) { [weak model] in
                    model?.openExtensionsControlCenter()
                },
                button("rectangle.split.2x1", BrowserStrings.menuAddSplitView) { [weak model] in
                    model?.presentSplitViewCommandBar()
                },
            ],
        ]
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        lock.contentTintColor = .white
        addSubview(lock)
        address.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        address.textColor = .white
        address.lineBreakMode = .byTruncatingTail
        address.isSelectable = true
        addSubview(address)
        for group in actions {
            group.forEach(addSubview)
        }
        for _ in actions.dropLast() {
            let separator = NSView()
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            separators.append(separator)
            addSubview(separator)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityIdentifier("browser.developer-toolbar")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: BrowserChromeLayout.leadingContentCornerRadius,
            yRadius: BrowserChromeLayout.leadingContentCornerRadius,
        )
        tint.setFill()
        path.fill()
        path.addClip()
        // Diagonal stripes mark the page as being in Developer Mode.
        NSColor.white.withAlphaComponent(0.03).setFill()
        let stripe: CGFloat = 26
        var x = -bounds.height
        while x < bounds.width {
            let band = NSBezierPath()
            band.move(to: NSPoint(x: x, y: bounds.height))
            band.line(to: NSPoint(x: x + bounds.height, y: 0))
            band.line(to: NSPoint(x: x + bounds.height + stripe, y: 0))
            band.line(to: NSPoint(x: x + stripe, y: bounds.height))
            band.close()
            band.fill()
            x += stripe * 2
        }
    }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.chromeButtonSize
        let barHeight = Self.height
        lock.frame = NSRect(x: 16, y: (barHeight - 16) / 2, width: 14, height: 16)
        var x = bounds.width - 8
        var separatorIndex = separators.count - 1
        for (index, group) in actions.enumerated().reversed() {
            for button in group.reversed() {
                x -= size
                button.frame = NSRect(x: x, y: (barHeight - size) / 2, width: size, height: size)
            }
            if index > 0 {
                x -= 8
                separators[separatorIndex].frame = NSRect(x: x, y: (barHeight - 16) / 2, width: 1, height: 16)
                separatorIndex -= 1
                x -= 9
            }
        }
        address.frame = NSRect(x: 38, y: (barHeight - 17) / 2, width: max(x - 46, 0), height: 17)
    }

    func refresh() {
        let urlString = model.currentTab?.urlString ?? ""
        if address.stringValue != urlString {
            address.stringValue = urlString
        }
        lock.isHidden = !urlString.hasPrefix("https://")
        needsDisplay = true
    }
}
