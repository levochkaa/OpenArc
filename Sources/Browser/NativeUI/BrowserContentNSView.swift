import AppKit
import QuartzCore

// MARK: - BrowserContentClipping

struct BrowserContentClipping: Equatable {
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool
    var sidebarPosition = BrowserSidebarPosition.left

    var radius: CGFloat { isSidebarVisible || usesWindowContentInsets
        ? BrowserChromeLayout.leadingContentCornerRadius
        : 0
    }

    var corners: CACornerMask {
        let leading: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let trailing: CACornerMask = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        var corners: CACornerMask = []
        if usesWindowContentInsets {
            corners.formUnion(leading.union(trailing))
        } else if isSidebarVisible {
            corners.formUnion(sidebarPosition == .left ? leading : trailing)
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
        addSubview(splitPaneBars)
        splitPaneBars.hostView = hostView
        for overlay in [loading, failure] {
            overlay.fillColor = BrowserChromeColors.contentBackground
            overlay.wantsLayer = true
            overlay.layer?.masksToBounds = true
            overlay.layer?.cornerCurve = .continuous
            overlay.isHidden = true
            addSubview(overlay)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        loading.addSubview(spinner)
        loading.addSubview(loadingLabel)
        for label in [loadingLabel, failureTitle, failureMessage] {
            label.alignment = .center
            label.maximumNumberOfLines = 0
        }
        for control in [failureTitle, failureMessage, retry] {
            failure.addSubview(control)
        }
        retry.onAction = { [weak self] in
            guard let self, !failure.isHidden else { return }
            onRetryTabCreation()
        }
        loading.setAccessibilityIdentifier("browser.content.loading")
        loadingLabel.setAccessibilityIdentifier("browser.content.loading.message")
        failure.setAccessibilityRole(.group)
        failure.setAccessibilityLabel(BrowserStrings.tabCreationFailedTitle)
        failure.setAccessibilityIdentifier("browser.content.creation-failure")
        failureTitle.setAccessibilityIdentifier("browser.content.creation-failure.title")
        failureMessage.setAccessibilityIdentifier("browser.content.creation-failure.message")
        retry.setAccessibilityIdentifier("browser.content.creation-failure.retry")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.content")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    let viewport: BrowserViewportClipView
    let splitPaneBars = BrowserSplitPaneBarsView()
    var onRetryTabCreation: () -> Void = {}

    private(set) var areaCapture: BrowserAreaCaptureOverlay?

    override func layout() {
        super.layout()
        cancelAreaCaptureIfStale()
        viewport.frame = bounds
        splitPaneBars.frame = bounds
        splitPaneBars.refresh()
        loading.frame = bounds
        failure.frame = bounds

        let width = min(max(bounds.width - 48, 0), 360)
        let x = (bounds.width - width) / 2
        let loadingHeight = textHeight(loadingLabel, width: width)
        let loadingY = (bounds.height - loadingHeight - 26) / 2
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: loadingY, width: 16, height: 16)
        loadingLabel.frame = NSRect(x: x, y: loadingY + 26, width: width, height: loadingHeight)

        let titleHeight = textHeight(failureTitle, width: width)
        let messageHeight = textHeight(failureMessage, width: width)
        let failureY = (bounds.height - titleHeight - messageHeight - 60) / 2
        failureTitle.frame = NSRect(x: x, y: failureY, width: width, height: titleHeight)
        failureMessage.frame = NSRect(x: x, y: failureTitle.frame.maxY + 8, width: width, height: messageHeight)
        let retryWidth = min(max(retry.intrinsicContentSize.width, 80), width)
        retry.frame = NSRect(
            x: (bounds.width - retryWidth) / 2,
            y: failureMessage.frame.maxY + 20,
            width: retryWidth,
            height: 32
        )
    }

    func bindTabCreation(to model: BrowserChromeModel) {
        onRetryTabCreation = { [weak model] in model?.retrySelectedTabCreation() }
        splitPaneBars.model = model
        model.onSplitPaneLayoutChange = { [weak self] in self?.splitPaneBars.refresh() }
        captureModel = model
        model.onBeginAreaCapture = { [weak self, weak model] in
            guard let self, let model else { return false }
            let tabID = model.selectedTabID
            beginAreaCapture(pageTabID: tabID) { fraction in
                if let fraction {
                    model.captureArea(fraction: fraction, tabID: tabID)
                }
                model.focusSelectedPage()
            }
            return true
        }
    }

    /// The outline belongs to one page at one size: a resize, a layout change or
    /// another selected tab cancels it.
    func cancelAreaCaptureIfStale() {
        guard let areaCapture else { return }
        if areaCapture.frame != bounds || captureModel?.selectedTabID != areaCaptureTabID {
            areaCapture.onFinish(nil)
        }
    }

    /// Capture…: outlines part of the selected page, or of the focused
    /// pane in a split.
    func beginAreaCapture(pageTabID: String?, onFinish: @escaping (CGRect?) -> Void) {
        areaCapture?.removeFromSuperview()
        areaCaptureTabID = pageTabID
        let page = pageTabID.flatMap { splitPaneBars.pageFrame(forTabID: $0) }
            .map { convert($0, from: splitPaneBars) } ?? bounds
        let overlay = BrowserAreaCaptureOverlay(pageFrame: page)
        overlay.frame = bounds
        overlay.onFinish = { [weak self, weak overlay] fraction in
            guard let overlay, overlay.superview != nil else { return }
            overlay.removeFromSuperview()
            self?.areaCapture = nil
            onFinish(fraction)
        }
        addSubview(overlay)
        window?.makeFirstResponder(overlay)
        areaCapture = overlay
    }

    func update(
        hostView: NSView,
        isContextReady: Bool,
        hasSelectedTab: Bool,
        isSidebarVisible: Bool,
        usesWindowContentInsets: Bool,
        sidebarPosition: BrowserSidebarPosition = .left,
        selectedTabCreationState: BrowserTabCreationState? = nil
    ) {
        cancelAreaCaptureIfStale()
        viewport.update(hostView: hostView)
        splitPaneBars.hostView = hostView
        let isCreatingTab = hasSelectedTab && selectedTabCreationState == .creating
        let didFailToCreateTab = hasSelectedTab && selectedTabCreationState == .failed
        viewport.isHidden = !isContextReady || !hasSelectedTab || isCreatingTab || didFailToCreateTab
        splitPaneBars.isHidden = viewport.isHidden
        splitPaneBars.showsWindowControls = !isSidebarVisible
        splitPaneBars.refresh()
        let clipping = BrowserContentClipping(
            isSidebarVisible: isSidebarVisible,
            usesWindowContentInsets: usesWindowContentInsets,
            sidebarPosition: sidebarPosition
        )
        viewport.updateClipping(cornerRadius: clipping.radius, maskedCorners: clipping.corners)
        for overlay in [loading, failure] {
            overlay.layer?.cornerRadius = clipping.radius
            overlay.layer?.maskedCorners = clipping.corners
        }
        loadingLabel.stringValue = isContextReady
            ? BrowserStrings.loadingOpeningTab
            : BrowserStrings.loadingLaunchingBrowser
        loading.isHidden = isContextReady && !isCreatingTab
        failure.isHidden = !isContextReady || !didFailToCreateTab
        retry.isEnabled = !failure.isHidden
        if loading.isHidden {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        needsLayout = true
    }

    // MARK: Private

    private var areaCaptureTabID: String?
    private weak var captureModel: BrowserChromeModel?

    private let loading = BrowserNativeSurface()
    private let spinner = NSProgressIndicator()
    private let loadingLabel = BrowserNativeControls.label(
        BrowserStrings.loadingLaunchingBrowser,
        size: 12,
        color: BrowserChromeColors.secondaryText,
        wraps: true
    )
    private let failure = BrowserNativeSurface()
    private let failureTitle = BrowserNativeControls.label(
        BrowserStrings.tabCreationFailedTitle,
        size: 16,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
        wraps: true
    )
    private let failureMessage = BrowserNativeControls.label(
        BrowserStrings.tabCreationFailedMessage,
        size: 13,
        color: BrowserChromeColors.secondaryText,
        wraps: true
    )
    private let retry = BrowserActionButton(BrowserStrings.tabCreationRetry, action: {})

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil((label.stringValue as NSString)
            .boundingRect(
                with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)]
            )
            .height)
    }
}
