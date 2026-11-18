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
    private(set) var captureCard: BrowserCaptureCardPresenter?
    let permissionPrompt = BrowserSitePermissionPromptView()

    private(set) var crashPages = [String: BrowserSadTabView]()
    /// The canvas of each Easel on screen, by tab: the selected one and its split panes.
    private(set) var easelViews = [String: BrowserEaselView]()
    /// A note's editor over each note tab on screen, by tab ID.
    private(set) var notePages = [String: BrowserNoteEditorView]()
    /// The tab whose note took the keyboard last, so selecting it again focuses it once.
    private var focusedNoteTabID: String?
    let movedPage = BrowserMovedPageView()

    /// The area with no tab, in place of the usual page color.
    var emptyPageColor: NSColor? {
        didSet { empty.fillColor = emptyPageColor ?? BrowserChromeColors.contentBackground }
    }

    // MARK: Private

    private let pageShadow = CALayer()
    private var pageShadowRadius: CGFloat = 0
    private var easelClipping: BrowserContentClipping?
    private var noteClipping = BrowserContentClipping(isSidebarVisible: true, usesWindowContentInsets: false)

    private var areaCaptureTabID: String?
    private weak var captureModel: BrowserChromeModel?
    private var permissionObservation: AnyCancellable?

    private let loading = BrowserNativeSurface()
    /// The page's card when no tab is shown, as after closing the last one.
    private let empty = BrowserNativeSurface()
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

    var emptyPageFill: NSColor { empty.fillColor }

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
        for overlay in [empty, loading, failure] {
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
        movedPage.isHidden = true
        addSubview(movedPage)
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
        let aside = splitPaneBars.pageAsideFrame(in: bounds)
        viewport.fixedHostedSize = aside == nil ? nil : bounds.size
        viewport.frame = aside ?? bounds
        splitPaneBars.frame = bounds
        splitPaneBars.refresh()
        empty.frame = bounds
        loading.frame = bounds
        failure.frame = bounds
        movedPage.frame = bounds

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
        for (id, easel) in easelViews {
            easel.frame = pageFrame(forTabID: id)
        }
        for (id, page) in notePages {
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
        movedPage.onClick = { [weak model] in model?.showMovedPageHere() }
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
                self?.refreshEasels()
                self?.refreshNotePages()
            }
        refreshPermissionPrompt()
        refreshCrashPages()
        refreshEasels()
        refreshNotePages()
        model.onFocusNote = { [weak self] noteID, title in
            guard let page = self?.notePages.values.first(where: { $0.noteID == noteID && !$0.isHidden }) else {
                return false
            }
            return page.focus(title: title)
        }
        model.onBeginAreaCapture = { [weak self, weak model] in
            guard let self, let model else { return false }
            let tabID = model.selectedTabID
            let copies = model.areaCaptureCopiesToClipboard
            closeCaptureCard()
            beginAreaCapture(pageTabID: tabID) { fraction in
                if let fraction {
                    // A Shift-Command drag and an Easel's capture button copy the part.
                    if copies || model.easelCaptureTargetID != nil {
                        model.captureArea(fraction: fraction, tabID: tabID)
                    } else {
                        model.captureAreaForCard(fraction: fraction, tabID: tabID)
                    }
                } else {
                    model.easelCaptureTargetID = nil
                }
                model.focusSelectedPage()
            }
            return true
        }
        model.onPresentCapture = { [weak self] in self?.presentCaptureCard($0) }
    }

    /// The card over the page that offers what to do with a capture.
    func presentCaptureCard(_ request: BrowserCaptureRequest) {
        guard let model = captureModel, request.tabID == nil || request.tabID == model.selectedTabID,
              let image = BrowserCaptureImaging.cgImage(png: request.png)
        else { return }
        closeCaptureCard()
        let page = pageFrame(forTabID: request.tabID)
        let pictureFrame: CGRect
        switch request.placement {
        case .outlined(let fraction):
            pictureFrame = CGRect(
                x: page.minX + fraction.minX * page.width,
                y: page.minY + fraction.minY * page.height,
                width: fraction.width * page.width,
                height: fraction.height * page.height,
            ).integral
        case .centered:
            let size = BrowserCaptureCardView.pictureSize(
                pixelSize: CGSize(width: image.width, height: image.height),
                page: page,
            )
            let windowTop = window.map { convert(CGPoint(x: 0, y: $0.frame.height), from: nil).y } ?? page.minY
            pictureFrame = BrowserCaptureCardView.centeredPictureFrame(size: size, page: page, windowTop: windowTop)
        }
        let backdrop = request.pagePNG
            .flatMap(BrowserCaptureImaging.cgImage(png:))
            .flatMap(BrowserCaptureImaging.backdrop)
            .map { NSImage(cgImage: $0, size: page.size) }
        let card = BrowserCaptureCardView(
            picture: NSImage(cgImage: image, size: pictureFrame.size),
            pictureFrame: pictureFrame,
            pageFrame: page,
            backdrop: backdrop,
            menu: BrowserCaptureCardPresenter.menu(for: model),
        )
        card.frame = bounds
        let presenter = BrowserCaptureCardPresenter(request: request, card: card, model: model)
        card.onAction = { [weak presenter] in presenter?.perform($0) }
        card.onDismiss = { [weak self] in self?.closeCaptureCard() }
        presenter.onClose = { [weak self, weak presenter] in
            guard let presenter, self?.captureCard === presenter else { return }
            self?.closeCaptureCard()
        }
        addSubview(card)
        captureCard = presenter
        card.focusField()
    }

    func closeCaptureCard() {
        guard let captureCard else { return }
        self.captureCard = nil
        captureCard.stopFollowingEdits()
        captureCard.card.removeFromSuperview()
        captureModel?.focusSelectedPage()
    }

    /// The outline belongs to one page at one size: a resize, a layout change or
    /// another selected tab cancels it.
    func cancelAreaCaptureIfStale() {
        closeCaptureCardIfStale()
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
        captureModel?.captureSelectedPagePicture { [weak overlay] png in
            overlay?.pagePicture = png.flatMap(BrowserCaptureImaging.cgImage(png:))
        }
        var asking = false
        var waiting: CGPoint?
        func ask(_ point: CGPoint) {
            guard !asking else {
                waiting = point
                return
            }
            asking = true
            captureModel?.selectedPageElementFrame(at: point) { [weak overlay] frame in
                asking = false
                overlay?.showHoveredElement(fraction: frame)
                if let next = waiting {
                    waiting = nil
                    ask(next)
                }
            }
        }
        overlay.onHover = { ask($0) }
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
        movedPage movedPagePicture: NSImage?? = nil,
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
        for overlay in [empty, loading, failure, movedPage] {
            overlay.layer?.cornerRadius = clipping.radius
            overlay.layer?.maskedCorners = clipping.corners
        }
        easelClipping = clipping
        noteClipping = clipping
        movedPage.isHidden = !isContextReady || movedPagePicture == nil
        empty.isHidden = !isContextReady || hasSelectedTab || !movedPage.isHidden
        movedPage.picture = movedPagePicture ?? nil
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
        refreshEasels()
        refreshNotePages()
        needsLayout = true
    }

    /// An Easel's canvas covers its tab's empty page, in a split only its pane.
    func refreshEasels() {
        guard let model = captureModel else { return }
        let visible = model.visibleEaselTabIDs
        for (id, view) in easelViews where !visible.contains(id) || model.easelID(forTabID: id) != view.easelID {
            view.removeFromSuperview()
            easelViews.removeValue(forKey: id)
        }
        var shown = [BrowserEaselView]()
        for id in visible {
            guard let easelID = model.easelID(forTabID: id) else { continue }
            let view = easelViews[id] ?? {
                let view = BrowserEaselView(easelID: easelID, store: model.easelStore)
                view.onDocumentChange = { [weak model] editor in model?.syncEaselTitle(tabID: id, editor: editor) }
                view.onCapture = { [weak model] easelID in _ = model?.beginEaselCapture(easelID: easelID) }
                view.onOpenCapture = { [weak model] capture in model?.openCapturedPage(capture) }
                view.refreshLiveCapture = { [weak model] capture, completion in
                    guard let model else { return completion(nil) }
                    model.refreshLiveCapture(capture, completion: completion)
                }
                addSubview(view, positioned: .below, relativeTo: movedPage)
                easelViews[id] = view
                shown.append(view)
                return view
            }()
            view.isHidden = !empty.isHidden || !movedPage.isHidden
            view.layer?.cornerRadius = easelClipping?.radius ?? 0
            view.layer?.maskedCorners = easelClipping?.corners ?? []
            view.layer?.cornerCurve = .continuous
            if let editor = view.editor {
                model.syncEaselTitle(tabID: id, editor: editor)
            }
        }
        if let selected = model.selectedTabID, let view = easelViews[selected], shown.contains(where: { $0 === view }) {
            // After the engine has given its empty page the keyboard.
            // The engine gives its new page the keyboard a moment later; take it back.
            for delay in [0.05, 0.35, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in view?.focusCanvas() }
            }
        }
        needsLayout = true
    }

    /// A note's editor over each note tab on screen. Editors of tabs that left
    /// the screen save and go; a newly shown note takes the keyboard.
    func refreshNotePages() {
        guard let model = captureModel else { return }
        let visible = model.selectedTabID.map { model.splitPaneTabIDs(forTabID: $0) } ?? []
        var wanted = [String: String]()
        if !viewport.isHidden {
            for id in visible {
                if let noteID = model.noteID(forTabID: id) {
                    wanted[id] = noteID
                }
            }
        }
        for (id, page) in notePages where wanted[id] != page.noteID {
            page.close()
            page.removeFromSuperview()
            notePages.removeValue(forKey: id)
        }
        for (id, noteID) in wanted where notePages[id] == nil {
            let page = BrowserNoteEditorView(noteID: noteID, store: model.notesStore)
            page.onOpenLink = { [weak model] url in model?.openURLInNewTab(url, atTop: true) }
            page.onDelete = { [weak model] noteID in model?.deleteNote(id: noteID) }
            page.frame = pageFrame(forTabID: id)
            addSubview(page, positioned: .below, relativeTo: permissionPrompt)
            notePages[id] = page
        }
        for page in notePages.values {
            page.layer?.cornerRadius = notePages.count > 1 ? BrowserChromeLayout.leadingContentCornerRadius : noteClipping
                .radius
            page.layer?.maskedCorners = notePages.count > 1 ? [
                .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ] : noteClipping.corners
        }
        // The selected note takes the keyboard once each time it is selected.
        let selected = model.selectedTabID.flatMap { notePages[$0] != nil ? $0 : nil }
        if let selected, selected != focusedNoteTabID {
            focusedNoteTabID = selected
            // The engine gives its new page the keyboard a moment later; take it back.
            for delay in [0.0, 0.35, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let page = self?.notePages[selected], page.window?.isKeyWindow == true,
                          self?.captureModel?.selectedTabID == selected
                    else { return }
                    page.focusIfOutside()
                }
            }
        } else if selected == nil {
            focusedNoteTabID = nil
        }
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

    /// The card belongs to one page at one size, like the outline.
    private func closeCaptureCardIfStale() {
        guard let captureCard else { return }
        if captureCard.card.frame != bounds
            || (captureCard.request.tabID != nil && captureModel?.selectedTabID != captureCard.request.tabID)
        {
            closeCaptureCard()
        }
    }

    /// A tab dragged from the sidebar over a page not yet split: the page
    /// slides to the other half and the window shows through where the tab will go.
    private func movePageAsideForDrop() {
        let aside = splitPaneBars.pageAsideFrame(in: bounds)
        let target = aside ?? bounds
        guard viewport.frame != target else { return }
        // The page keeps its size and is clipped as it slides, rather than laying out again.
        viewport.fixedHostedSize = aside == nil ? nil : bounds.size
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

// MARK: - BrowserMovedPageView

/// The selected tab's page is in another window: a faded picture of it, which brings
/// the page back here on a click.
final class BrowserMovedPageView: NSView {
    // MARK: Internal

    /// The window's background shows through the picture.
    static let pictureOpacity: CGFloat = 0.6

    override var isFlipped: Bool { true }

    var onClick: () -> Void = {}

    var picture: NSImage? {
        didSet {
            guard picture !== oldValue else { return }
            layer?.contents = picture
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.contentsGravity = .resizeAspectFill
        layer?.opacity = Float(Self.pictureOpacity)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(BrowserStrings.movedPageShowHere)
        setAccessibilityIdentifier("browser.content.moved-page")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with _: NSEvent) {
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
