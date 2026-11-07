// BrowserContentNSView.swift

import AppKit
import Combine
import QuartzCore

// MARK: - BrowserContentClipping

struct BrowserContentClipping: Equatable {
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool
    var sidebarPosition = BrowserSidebarPosition.left

    var radius: CGFloat {
        if isSidebarVisible || usesWindowContentInsets {
            BrowserChromeLayout.leadingContentCornerRadius
        } else {
            0
        }
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
    // MARK: Internal

    override var isFlipped: Bool { true }

    let viewport: BrowserViewportClipView
    let splitPaneBars = BrowserSplitPaneBarsView()
    var onRetryTabCreation: () -> Void = {}

    private(set) var areaCapture: BrowserAreaCaptureOverlay?
    let permissionPrompt = BrowserSitePermissionPromptView()

    private(set) var crashPages = [String: BrowserSadTabView]()

    // MARK: Private

    private let pageShadow = CALayer()
    private var pageShadowRadius: CGFloat = 0

    private var areaCaptureTabID: String?
    private weak var captureModel: BrowserChromeModel?
    private var permissionObservation: AnyCancellable?

    private let loading = BrowserNativeSurface()
    private let spinner = NSProgressIndicator()
    private let loadingLabel = BrowserNativeControls.label(
        BrowserStrings.loadingLaunchingBrowser,
        size: 12,
        color: BrowserChromeColors.secondaryText,
        wraps: true,
    )
    private let failure = BrowserNativeSurface()
    private let failureTitle = BrowserNativeControls.label(
        BrowserStrings.tabCreationFailedTitle,
        size: 16,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
        wraps: true,
    )
    private let failureMessage = BrowserNativeControls.label(
        BrowserStrings.tabCreationFailedMessage,
        size: 13,
        color: BrowserChromeColors.secondaryText,
        wraps: true,
    )
    private let retry = BrowserActionButton(BrowserStrings.tabCreationRetry, action: {})

    init(hostView: NSView) {
        self.viewport = BrowserViewportClipView(hostView: hostView)
        super.init(frame: .zero)
        wantsLayer = true
        pageShadow.shadowColor = NSColor.black.cgColor
        pageShadow.shadowRadius = BrowserChromeLayout.contentShadowRadius
        pageShadow.shadowOffset = CGSize(width: 0, height: BrowserChromeLayout.contentShadowOffset)
        layer?.addSublayer(pageShadow)
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
        permissionPrompt.isHidden = true
        addSubview(permissionPrompt)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.content")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        cancelAreaCaptureIfStale()
        updatePageShadow()
        viewport.frame = splitPaneBars.pageAsideFrame(in: bounds) ?? bounds
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
            height: 32,
        )
        for (id, page) in crashPages {
            page.frame = pageFrame(forTabID: id)
        }
        if let request = permissionPrompt.request, !permissionPrompt.isHidden {
            // Over the top of the asking page, or of its pane in a split.
            let page = pageFrame(forTabID: request.tabID)
            permissionPrompt.frame = NSRect(
                x: page.minX + 12,
                y: page.minY + 12,
                width: min(BrowserSitePermissionPromptView.width, max(page.width - 24, 0)),
                height: permissionPrompt.fittingHeight,
            )
        }
    }

    func bindTabCreation(to model: BrowserChromeModel) {
        onRetryTabCreation = { [weak model] in model?.retrySelectedTabCreation() }
        splitPaneBars.model = model
        splitPaneBars.onPageDropPreviewChange = { [weak self] in self?.movePageAsideForDrop() }
        model.onSplitPaneLayoutChange = { [weak self] in
            self?.splitPaneBars.refresh()
            self?.cancelAreaCaptureIfStale()
        }
        captureModel = model
        permissionPrompt.onAnswer = { [weak model] id, allowed in
            model?.answerSitePermissionRequest(id: id, allowed: allowed)
        }
        permissionPrompt.onDismiss = { [weak model] id in model?.dismissSitePermissionRequest(id: id) }
        permissionObservation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refreshPermissionPrompt()
                self?.refreshCrashPages()
            }
        refreshPermissionPrompt()
        refreshCrashPages()
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
        if areaCapture.frame != bounds || captureModel?.selectedTabID != areaCaptureTabID
            || pageFrame(forTabID: areaCaptureTabID) != areaCapture.pageFrame
        {
            areaCapture.onFinish(nil)
        }
    }

    /// Capture…: outlines part of the selected page, or of the focused
    /// pane in a split.
    func beginAreaCapture(pageTabID: String?, onFinish: @escaping (CGRect?) -> Void) {
        areaCapture?.removeFromSuperview()
        areaCaptureTabID = pageTabID
        let page = pageFrame(forTabID: pageTabID)
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
        selectedTabCreationState: BrowserTabCreationState? = nil,
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
            sidebarPosition: sidebarPosition,
        )
        viewport.updateClipping(cornerRadius: clipping.radius, maskedCorners: clipping.corners)
        pageShadowRadius = clipping.radius
        updatePageShadow()
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
        refreshPermissionPrompt()
        refreshCrashPages()
        needsLayout = true
    }

    /// Crash page over each page on screen whose renderer crashed.
    func refreshCrashPages() {
        guard let model = captureModel else { return }
        let codes = model.crashedTabErrorCodes
        let visible = Set(model.selectedTabID.map { model.splitPaneTabIDs(forTabID: $0) } ?? [])
        for (id, page) in crashPages where codes[id] == nil {
            page.removeFromSuperview()
            crashPages.removeValue(forKey: id)
        }
        for (id, code) in codes {
            let page = crashPages[id] ?? {
                let page = BrowserSadTabView()
                page.onReload = { [weak model] in model?.reloadCrashedTab(id: id) }
                addSubview(page, positioned: .below, relativeTo: permissionPrompt)
                crashPages[id] = page
                return page
            }()
            if page.errorCode != code || page.accessibilityLabel() == nil {
                page.update(errorCode: code)
            }
            page.isHidden = viewport.isHidden || !visible.contains(id)
        }
        needsLayout = true
    }

    /// The window's prompt shows the request of a page on screen, if any.
    func refreshPermissionPrompt() {
        guard let request = captureModel?.visibleSitePermissionRequest, !viewport.isHidden else {
            permissionPrompt.isHidden = true
            return
        }
        permissionPrompt.update(request: request)
        permissionPrompt.isHidden = false
        needsLayout = true
    }

    /// A tab dragged from the sidebar over a page not yet split: the page
    /// slides to the other half and the window shows through where the tab will go.
    private func movePageAsideForDrop() {
        let target = splitPaneBars.pageAsideFrame(in: bounds) ?? bounds
        guard viewport.frame != target else { return }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            viewport.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            context.allowsImplicitAnimation = true
            viewport.animator().frame = target
        }
    }

    private func updatePageShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageShadow.frame = bounds
        pageShadow.shadowOpacity = pageShadowRadius > 0 ? BrowserChromeLayout.contentShadowOpacity : 0
        pageShadow.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: pageShadowRadius,
            cornerHeight: pageShadowRadius,
            transform: nil,
        )
        CATransaction.commit()
    }

    /// The page part of a split pane, or the whole content outside a split.
    private func pageFrame(forTabID tabID: String?) -> CGRect {
        tabID.flatMap { splitPaneBars.pageFrame(forTabID: $0) }.map { convert($0, from: splitPaneBars) } ?? bounds
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil((label.stringValue as NSString)
            .boundingRect(
                with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)],
            )
            .height)
    }
}
