// BrowserLittleWindowLauncher.swift

import AppKit
import Combine

// MARK: - BrowserLittleWindowLauncher

/// New Small Window first asks where to go: a command bar near the top right
/// corner of the screen, above every window. What it opens goes to a small
/// window; Escape or a click elsewhere closes it.
@MainActor final class BrowserLittleWindowLauncher {
    // MARK: Internal

    /// The bar's width, and how far it sits from the screen's top right corner.
    static let barWidth: CGFloat = 490
    static let screenMargin: CGFloat = 20

    // MARK: Private

    /// Wide enough for a bar of `barWidth` plus the view's side padding.
    private static let panelSize = CGSize(width: barWidth + BrowserChromeLayout.sidebarOuterPadding * 2, height: 640)

    private let model: BrowserCommandBarModel
    private let bar: BrowserCommandBarNSView
    private let panel: BrowserLittleWindowLauncherPanel
    private var observations = Set<AnyCancellable>()

    init(model: BrowserCommandBarModel) {
        self.model = model
        self.bar = BrowserCommandBarNSView(model: model)
        self.panel = BrowserLittleWindowLauncherPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = bar
        bar.configure(blockedLeadingInset: 0, style: .standard, faviconCandidate: nil)
        model.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                if !presented {
                    self?.panel.orderOut(nil)
                }
            }
            .store(in: &observations)
        NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak model] _ in model?.dismiss() }
            .store(in: &observations)
    }

    func present(on screen: NSScreen?) -> Bool {
        guard let screen = screen ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        // The bar draws its panel some way down the view; line that panel up with the corner.
        let layout = BrowserCommandBarLayout(
            availableSize: Self.panelSize,
            style: .standard,
            displayText: "",
            suggestionCount: 0,
        )
        let barTop = layout.panelFrame.minY
        let barTrailing = Self.panelSize.width - layout.panelFrame.maxX
        panel.setFrameOrigin(CGPoint(
            x: visible.maxX - Self.screenMargin + barTrailing - Self.panelSize.width,
            y: visible.maxY - Self.screenMargin + barTop - Self.panelSize.height,
        ))
        model.present()
        panel.makeKeyAndOrderFront(nil)
        return true
    }
}

// MARK: - BrowserLittleWindowLauncherPanel

/// Takes typing without bringing the app forward, like Spotlight.
private final class BrowserLittleWindowLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The panel's clear top runs under the menu bar so the bar itself sits near the corner.
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
}
