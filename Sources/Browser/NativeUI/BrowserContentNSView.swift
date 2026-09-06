import AppKit
import QuartzCore

// MARK: - BrowserContentClipping

struct BrowserContentClipping: Equatable {
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool

    var radius: CGFloat { isSidebarVisible || usesWindowContentInsets
        ? BrowserChromeLayout.leadingContentCornerRadius
        : 0
    }

    var corners: CACornerMask {
        var corners: CACornerMask = []
        if isSidebarVisible ||
            usesWindowContentInsets
        {
            corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
        }
        if usesWindowContentInsets {
            corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
        }
        return corners
    }
}

// MARK: - BrowserContentNSView

final class BrowserContentNSView: NSView {
    // MARK: Lifecycle

    init(hostView: NSView) {
        self.viewport = BrowserViewportClipView(hostView: hostView)
        super.init(frame: .zero)
        addSubview(viewport)
        loading.fillColor = BrowserChromeColors.contentBackground
        loading.wantsLayer = true
        loading.layer?.masksToBounds = true
        loading.layer?.cornerCurve = .continuous
        addSubview(loading)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let label = BrowserNativeControls.label(
            BrowserStrings.loadingLaunchingBrowser,
            size: 12,
            color: BrowserChromeColors.secondaryText
        )
        let content = BrowserNativeControls.stack([spinner, label], spacing: 10)
        content.alignment = .centerX
        content.translatesAutoresizingMaskIntoConstraints = false
        loading.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: loading.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: loading.centerYAnchor),
        ])
        setAccessibilityIdentifier("browser.content")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    let viewport: BrowserViewportClipView

    override func layout() {
        super.layout()
        viewport.frame = bounds
        loading.frame = bounds
    }

    func update(
        hostView: NSView,
        isContextReady: Bool,
        hasSelectedTab: Bool,
        isSidebarVisible: Bool,
        usesWindowContentInsets: Bool
    ) {
        viewport.update(hostView: hostView)
        viewport.isHidden = !hasSelectedTab
        let clipping = BrowserContentClipping(
            isSidebarVisible: isSidebarVisible,
            usesWindowContentInsets: usesWindowContentInsets
        )
        viewport.updateClipping(cornerRadius: clipping.radius, maskedCorners: clipping.corners)
        loading.layer?.cornerRadius = clipping.radius
        loading.layer?.maskedCorners = clipping.corners
        loading.isHidden = isContextReady
        if isContextReady {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
    }

    // MARK: Private

    private let loading = BrowserNativeSurface()
    private let spinner = NSProgressIndicator()
}
