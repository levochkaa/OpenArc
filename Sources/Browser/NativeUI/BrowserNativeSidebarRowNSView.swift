// BrowserNativeSidebarRowNSView.swift

import AppKit
import QuartzCore

// MARK: - BrowserNativeSidebarRowNSView

/// One reusable native row for tabs, favorites, folders, space headers, Split
/// Views and New Tab.
final class BrowserNativeSidebarRowNSView: BrowserNativePressableView, NSTextFieldDelegate {
    enum Kind { case tab, appTab, folder, space, newTab, split }

    /// From the icon's trailing edge: the slash's middle 5 pt after it, the
    /// title 11.5 pt after it.
    private static let pinnedSlashOffset: CGFloat = 6
    private static let pinnedSlashTitleOffset: CGFloat = 10

    // MARK: Internal

    override var tooltipTarget: BrowserTooltipCoordinator.Target { .row }

    override var dragContentBounds: CGRect { CGRect(
        x: indent,
        y: 0,
        width: max(bounds.width - indent, 1),
        height: bounds.height,
    ) }

    private(set) var kind = Kind.tab
    private(set) var isRenaming = false
    var onSelect: () -> Void = {}
    var onModifiedSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onBeginRename: () -> Void = {}
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onBackToPinnedURL: () -> Void = {}
    var onSeparateFromPinnedTab: () -> Void = {}
    var onToggle: () -> Void = {}
    var onClose: () -> Void = {}
    var onToggleMute: () -> Void = {}
    var onSelectSplitMember: (String) -> Void = { _ in }
    var onCloseSplitMember: (String) -> Void = { _ in }
    let titleLabel = BrowserNativeControls.label("", size: BrowserChromeLayout.sidebarRowFontSize, weight: .regular)
    let captionLabel = BrowserNativeControls.label(
        "",
        size: 10.5,
        weight: .medium,
        color: BrowserChromeColors.secondaryText,
    )
    let renameField = BrowserSidebarRenameNSTextField()
    let closeButton = BrowserNativeChromeButton(symbol: "xmark", title: "", style: .sidebarClose, action: {})
    /// A tab with sound shows a speaker after its icon that mutes
    /// it, and a muted tab a crossed-out one that unmutes it.
    let muteButton = BrowserNativeChromeButton(
        symbol: "speaker.slash.fill",
        title: BrowserStrings.tabUnmuteAction,
        style: .sidebarClose,
        action: {},
    )
    /// Unread mail on a Gmail tab or Favorite.
    var showsUnreadDot = false {
        didSet {
            guard showsUnreadDot != oldValue else { return }
            if showsUnreadDot, unreadDot.superview == nil {
                unreadDot.wantsLayer = true
                unreadDot.layer?.backgroundColor = NSColor.systemRed.cgColor
                unreadDot.layer?.cornerRadius = 4
                addSubview(unreadDot)
            }
            unreadDot.isHidden = !showsUnreadDot
            needsLayout = true
        }
    }

    private(set) var isMuted = false
    private(set) var isAudible = false
    private(set) var isRecording = false
    /// Tab IDs of the split shown by this row, in pane order.
    private(set) var splitMemberIDs = [String]()

    /// A renamed split shows its icon and name, and each pane as a favicon.
    private(set) var splitName: BrowserSidebarSplitName?

    var dragOpacity: CGFloat = 1 { didSet { alphaValue = dragOpacity * appearanceProgress } }

    /// A pinned tab away from its pinned page shows a slash
    /// between its icon, which goes back, and its title.
    let pinnedSlash = BrowserNativeSidebarPinnedSlashView()
    let folderIcon = BrowserFolderIconView()
    let recordingDot = BrowserRecordingDotView()
    /// A tab with a Peek card shows the card's page icon where the close button goes.
    let peekBadge = BrowserNativeSurface()
    private(set) var peekPageURLString: String?

    private let peekBadgeIcon = BrowserFaviconNSView()

    private let unreadDot = NSView()

    // MARK: Private

    private let selectionSurface = BrowserNativeSidebarSelectionSurface()
    private var folderIconSymbol: String?
    private var folderIconID: String?
    private let favicon: BrowserFaviconNSView = {
        let view = BrowserFaviconNSView()
        view.fallback = .square
        return view
    }()

    private var splitChips = [BrowserNativeSidebarSplitChipView]()
    private let symbol = NSImageView()
    private var selected = false
    private var multiSelected = false
    private var dropTargeted = false
    /// A folder's own state; its icon also opens while something is held over it.
    private var isFolderExpanded = false
    private var splitDropSide: BrowserSidebarDragState.SplitDropTarget.Side?
    private var indent: CGFloat = 0
    private var pinnedURLRow = false
    private var splitPinnedControls = false
    private var pinnedIconHovered = false { didSet { if pinnedIconHovered != oldValue { watchSeparateKey() } } }
    /// Command held over the icon: a click then separates the page instead.
    private var separateKeyHeld = false
    private var separateKeyMonitor: Any?
    /// Change Icon: a symbol in place of the favicon.
    private var tabIcon: String?
    private var accessoryHovered = false
    private var hasPinnedTabs = false
    private let opacityAnimation = BrowserNativeAnimation()
    private var appearanceProgress: CGFloat = 1
    private let captionAnimation = BrowserNativeAnimation()
    private let disclosureAnimation = BrowserNativeAnimation()
    private var captionProgress = 0.0
    private var captionTarget = false
    private var developerHost: String?
    private let developerBorder = BrowserDeveloperRowBorder()
    private var disclosureProgress = 1.0

    private var baseSymbol = ""
    private var showsSpaceTitleAtLeadingEdge = false
    private var title = ""
    private var initialRenameTitle = ""
    private var suppressNextBlur = false
    private var resetID = 0
    private var isResizing = false

    private var collapsed = false {
        didSet {
            guard oldValue != collapsed else { return }
            let from = disclosureProgress
            let to = collapsed ? 0.0 : 1.0
            disclosureAnimation.start(.disclosure) { [weak self] progress in
                self?.disclosureProgress = from + (to - from) * progress
                self?.updateDisclosureTransform()
            }
        }
    }

    var contentIndent: CGFloat { indent }

    private var hasRenameChanged: Bool {
        renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsPinnedSlash: Bool { kind == .tab && splitPinnedControls && !isRenaming }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressCurve = .rowPress
        for view in [
            selectionSurface,
            pinnedSlash,
            folderIcon,
            favicon,
            symbol,
            titleLabel,
            captionLabel,
            developerBorder,
            renameField,
            muteButton,
            recordingDot,
            peekBadge,
            closeButton,
        ] {
            addSubview(view)
        }
        muteButton.onAction = { [weak self] in self?.onToggleMute() }
        peekBadge.cornerRadius = 10
        peekBadge.fillColor = BrowserChromeColors.rowHover
        peekBadge.isHidden = true
        peekBadge.setAccessibilityElement(false)
        peekBadge.addSubview(peekBadgeIcon)
        peekBadgeIcon.frame = NSRect(x: 3, y: 3, width: 14, height: 14)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.setAccessibilityElement(false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.wraps = false
        titleLabel.cell?.isScrollable = false
        renameField.delegate = self
        renameField.isHidden = true
        renameField.focusPermission = { [weak self] in self?.isRenaming == true }
        captionLabel.isHidden = true
        closeButton.onAction = { [weak self] in
            guard let self else { return }
            if kind == .space, let menu = menuProvider?() {
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: closeButton.frame.minX, y: closeButton.frame.maxY),
                    in: self,
                )
            } else {
                onClose()
            }
        }
        onClick = { [weak self] event in self?.primaryClick(event) }
        onPress = { [weak self] event in self?.selectOnPress(event) ?? false }
        onDoubleClick = { [weak self] event in
            guard let self else { return }
            if kind == .tab, let event, !event.modifierFlags.intersection([.command, .shift]).isEmpty {
                primaryClick(event)
                return
            }
            if kind == .tab {
                if !selected {
                    onSelect()
                }
                onBeginRename()
            } else if kind == .split {
                selectSplitMember(at: event)
            } else {
                primaryClick(event)
            }
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let separateKeyMonitor {
            NSEvent.removeMonitor(separateKeyMonitor)
        }
    }

    override func pointerMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for chip in splitChips {
            chip.isHovered = isHovered && !isResizing && chip.frame.contains(point)
        }
        pinnedIconHovered = isHovered && !isRenaming && splitPinnedControls
            && point.x >= indent && point.x < indent + BrowserChromeLayout.sidebarPinnedURLIconButtonSize
        accessoryHovered = isHovered && !closeButton.isHidden && closeButton.frame.contains(point)
        refreshAppearance()
    }

    override func interactionChanged() {
        super.interactionChanged()
        if !isHovered {
            pinnedIconHovered = false
            accessoryHovered = false
            for chip in splitChips {
                chip.isHovered = false
            }
        }
        refreshAppearance()
    }

    override func layout() {
        super.layout()
        unreadDot.frame = NSRect(x: max(bounds.width - 12, 0), y: 4, width: 8, height: 8)
        developerBorder.frame = NSRect(x: indent, y: 0, width: max(bounds.width - indent, 0), height: bounds.height)
        selectionSurface.frame = NSRect(x: indent, y: 0, width: max(bounds.width - indent, 0), height: bounds.height)
        let height = bounds.height
        let closeSize = BrowserChromeLayout.sidebarCloseButtonSize
        closeButton.frame = NSRect(
            x: max(bounds.width - BrowserChromeLayout.sidebarCloseButtonTrailingPadding - closeSize, 0),
            y: (height - closeSize) / 2,
            width: closeSize,
            height: closeSize,
        )
        peekBadge.frame = NSRect(x: closeButton.frame.midX - 10, y: (height - 20) / 2, width: 20, height: 20)
        if kind == .appTab {
            let size = BrowserChromeLayout.appTabIconSize
            favicon.frame = NSRect(x: (bounds.width - size) / 2, y: (height - size) / 2, width: size, height: size)
            symbol.frame = favicon.frame
            // Favorites lead with the dot.
            let dot = BrowserRecordingDotView.diameter
            recordingDot.frame = NSRect(x: 7, y: 7, width: dot, height: dot)
            return
        }
        if kind == .split {
            layoutSplitChips()
            return
        }
        let iconWidth: CGFloat = kind == .folder
            ? BrowserChromeLayout.sidebarPinnedFolderIconSize
            : kind == .space
                ? BrowserChromeLayout.sidebarSpaceSymbolSize + 4
                : kind == .newTab
                    ? (symbol.image?.size.width ?? BrowserChromeLayout.sidebarNewTabSymbolSize)
                    : BrowserChromeLayout.sidebarFaviconSize
        let iconX = indent + (BrowserChromeLayout.sidebarRowLeadingColumnWidth - iconWidth) / 2
        let iconHeight = kind == .newTab
            ? (symbol.image?.size.height ?? BrowserChromeLayout.sidebarNewTabSymbolSize)
            : iconWidth
        let iconFrame = NSRect(x: iconX, y: (height - iconHeight) / 2, width: iconWidth, height: iconHeight)
        favicon.frame = iconFrame
        symbol.frame = iconFrame
        folderIcon.frame = iconFrame
        let slashSize = BrowserNativeSidebarPinnedSlashView.size
        pinnedSlash.frame = NSRect(
            x: iconFrame.maxX + Self.pinnedSlashOffset - slashSize.width / 2,
            y: (height - slashSize.height) / 2,
            width: slashSize.width,
            height: slashSize.height,
        )
        var titleX = indent + BrowserChromeLayout.sidebarRowTitleX
        if kind == .space, showsSpaceTitleAtLeadingEdge {
            // A Space without its own icon shows only its name, until hovered.
            titleX = BrowserChromeLayout.sidebarSpaceTitleXWithoutIcon
        }
        if showsPinnedSlash {
            titleX = iconFrame.maxX + Self.pinnedSlashTitleOffset
        }
        if !recordingDot.isHidden {
            // The recording dot leads the title, before the speaker.
            let dot = BrowserRecordingDotView.diameter
            recordingDot.frame = NSRect(x: titleX + 1, y: (height - dot) / 2, width: dot, height: dot)
            titleX = recordingDot.frame.maxX + 7
        }
        if !muteButton.isHidden {
            // The speaker sits between the icon and the title.
            let muteSize: CGFloat = 26
            muteButton.frame = NSRect(x: titleX - 1, y: (height - muteSize) / 2, width: muteSize, height: muteSize)
            titleX = muteButton.frame.maxX
        }
        let trailing = !closeButton.isHidden
            ? closeButton.frame.minX
            : !peekBadge.isHidden
                ? peekBadge.frame.minX - 4
                : bounds.width - BrowserChromeLayout.sidebarTabTrailingPadding
        let titleWidth = max(trailing - titleX, 0)
        // Share the rename field's frame so the title glyphs stay centered and do not jump on rename.
        // The pinned URL caption lifts the title to keep the two-line stack centered.
        let titleY = (height - 17) / 2 - 7.5 * captionProgress
        titleLabel.frame = NSRect(
            x: titleX,
            y: titleY,
            width: titleWidth,
            height: 17,
        )
        captionLabel.frame = NSRect(
            x: titleX,
            y: titleLabel.frame.maxY + 13 * (1 - captionProgress),
            width: titleWidth,
            height: 13,
        )
        updateDisclosureTransform()
        renameField.frame = NSRect(
            x: titleX,
            y: (height - 17) / 2 + BrowserSidebarRenameNSTextField.editorLineLift,
            width: titleWidth,
            height: 17,
        )
    }

    override func draw(_: NSRect) {
        if let side = splitDropSide {
            let gap: CGFloat = 4
            let surface = NSRect(x: indent, y: 0, width: max(bounds.width - indent, 0), height: bounds.height)
            let half = (surface.width - gap) / 2
            let leading = NSRect(x: surface.minX, y: 0, width: half, height: surface.height)
            let trailing = NSRect(x: leading.maxX + gap, y: 0, width: half, height: surface.height)
            for (rect, active) in [(leading, side == .leading), (trailing, side == .trailing)] {
                (active ? BrowserChromeColors.rowSelected : BrowserChromeColors.rowHover).setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                    yRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                ).fill()
            }
            return
        }
        if kind == .appTab {
            (isHovered ? BrowserChromeColors.currentURLRowHover : BrowserChromeColors.currentURLRow).setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                yRadius: BrowserChromeLayout.sidebarRowCornerRadius,
            ).fill()
            return
        }
        if kind == .tab, splitPinnedControls, isHovered, !pinnedIconHovered, !selected, !multiSelected {
            let leading = indent + BrowserChromeLayout.sidebarPinnedURLIconButtonSize
                - BrowserChromeLayout.sidebarPinnedURLTextHoverOverlap
            BrowserChromeColors.rowHover.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: leading, y: 0, width: max(bounds.width - leading, 0), height: bounds.height),
                xRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                yRadius: BrowserChromeLayout.sidebarRowCornerRadius,
            ).fill()
        }
        if pinnedIconHovered, splitPinnedControls {
            BrowserChromeColors.rowHover.setFill()
            let rect = NSRect(
                x: indent,
                y: 0,
                width: BrowserChromeLayout.sidebarPinnedURLIconButtonSize,
                height: bounds.height,
            )
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                yRadius: BrowserChromeLayout.sidebarRowCornerRadius,
            )
            if selected {
                path.appendRect(NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
            }
            path.fill()
        }
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        BrowserIconImage.image(named: name, pointSize: size, weight: weight)
    }

    /// Split drop preview: the row splits into two halves and the half
    /// the dragged tab will take is filled.
    func setSplitDropSide(_ side: BrowserSidebarDragState.SplitDropTarget.Side?) {
        guard splitDropSide != side else { return }
        splitDropSide = side
        needsDisplay = true
    }

    func setDropHighlighted(_ value: Bool) {
        guard dropTargeted != value else { return }
        dropTargeted = value
        if kind == .folder {
            folderIcon.setTilted(isFolderExpanded || value, animated: window != nil)
        }
        updateSurface()
        needsDisplay = true
    }

    func animateInsertion() {
        guard window != nil else { return }
        appearanceProgress = 0
        alphaValue = 0
        opacityAnimation.start(.rowFade) { [weak self] progress in
            guard let self else { return }
            appearanceProgress = min(max(progress, 0), 1)
            alphaValue = dragOpacity * appearanceProgress
        }
    }

    /// Fades the row out. With `rising`, it also moves up that far, its title gone at
    /// once, as a collapsing Space folds its pinned rows under the header.
    func removeAnimated(rising: CGFloat = 0) {
        guard window != nil else { removeFromSuperview()
            return
        }
        isInteractionEnabled = false
        closeButton.isEnabled = false
        if rising > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            titleLabel.isHidden = true
            captionLabel.isHidden = true
            wantsLayer = true
            let animation = BrowserNativeAnimation.Curve.rowFade.layerAnimation(keyPath: "position")
            animation.isAdditive = true
            animation.fromValue = NSValue(point: .zero)
            animation.toValue = NSValue(point: CGPoint(x: 0, y: -rising))
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer?.add(animation, forKey: "fold")
        }
        let from = appearanceProgress
        opacityAnimation.start(.rowFade) { [weak self] progress in
            guard let self else { return }
            appearanceProgress = from * min(max(1 - progress, 0), 1)
            alphaValue = dragOpacity * appearanceProgress
        } completion: { [weak self] in self?.removeFromSuperview() }
    }

    func update(
        tab: BrowserChromeModel.Tab,
        appTile: Bool = false,
        selected: Bool,
        multiSelected: Bool = false,
        renaming: Bool = false,
        indentLevel: Int = 0,
        isResizing: Bool,
        resetID: Int = 0,
        closeDescriptor: BrowserCommandDescriptor,
        muted: Bool = false,
        audible: Bool = false,
        recording: Bool = false,
        peekPage: String? = nil,
        icon: String? = nil,
        developerHost: String? = nil,
    ) {
        kind = appTile ? .appTab : .tab
        self.developerHost = appTile ? nil : developerHost
        tabIcon = icon
        if let icon {
            symbol.image = Self.symbol(
                icon,
                size: appTile ? BrowserChromeLayout.appTabIconSize * 0.8 : BrowserChromeLayout.sidebarFaviconSize,
            )
            symbol.contentTintColor = BrowserChromeColors.primaryText
        }
        isMuted = muted && !appTile
        isAudible = audible && !appTile
        isRecording = recording
        if peekPageURLString != peekPage {
            peekPageURLString = peekPage
            let origin = peekPage.flatMap { URLComponents(string: $0) }.flatMap { components -> URL? in
                guard let scheme = components.scheme, let host = components.host else { return nil }
                return URL(string: "\(scheme)://\(host)/favicon.ico")
            }
            peekBadgeIcon.update(url: origin, pageURLString: peekPage)
        }
        muteButton.configureSymbol(
            isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: isMuted ? BrowserStrings.tabUnmuteAction : BrowserStrings.tabMuteAction,
        )
        muteButton.setAccessibilityIdentifier(
            isMuted ? "browser.sidebar.unmute-tab.\(tab.id)" : "browser.sidebar.mute-tab.\(tab.id)",
        )
        self.selected = selected
        self.multiSelected = multiSelected
        pinnedURLRow = !appTile && tab.placement == .spacePinned && tab.pinnedURLString != nil
        splitPinnedControls = pinnedURLRow && tab.canResetToPinnedURL
        indent = CGFloat(max(indentLevel, 0)) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
        title = tab.displayTitle
        favicon.update(url: tab.faviconURL, pageURLString: tab.urlString)
        tooltipTitle = tab.displayTitle
        tooltipCaption = !appTile && selected ? BrowserStrings.tabRenameTooltipCaption : nil
        tooltipAnchorXFraction = BrowserChromeLayout.sidebarRowTooltipAnchorXFraction
        tooltipShortcut = nil
        closeButton.configureSymbol(selected && pinnedURLRow ? "minus" : "xmark", title: closeDescriptor.helpTitle)
        closeButton.tooltipShortcut = selected ? closeDescriptor.shortcut : nil
        setAccessibilityIdentifier("browser.sidebar.tab.\(tab.id)")
        closeButton.setAccessibilityIdentifier("browser.sidebar.close-tab.\(tab.id)")
        renameField.setAccessibilityIdentifier("browser.sidebar.rename-tab.\(tab.id)")
        updateCommon(
            renaming: renaming,
            renameTitle: tab.userTitleOverride ?? tab.displayTitle,
            isResizing: isResizing,
            resetID: resetID,
        )
    }

    func update(
        folder: BrowserChromeModel.PinnedTabFolder,
        showsOpenTabs: Bool = false,
        renaming: Bool,
        indentLevel: Int,
        dropTargeted: Bool,
        isResizing: Bool,
        resetID: Int,
    ) {
        kind = .folder
        title = folder.title
        indent = CGFloat(max(indentLevel, 0)) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
        self.dropTargeted = dropTargeted
        baseSymbol = "folder"
        folderIcon.setColors(
            stroke: BrowserChromeColors.sidebarFolderStroke,
            backFill: BrowserChromeColors.sidebarFolderBack,
            frontFill: BrowserChromeColors.sidebarFolderFill,
        )
        isFolderExpanded = folder.isExpanded
        folderIcon.setTilted(
            folder.isExpanded || dropTargeted,
            animated: window != nil && folderIconID == folder.id,
        )
        if folderIconSymbol != folder.systemImageName {
            folderIconSymbol = folder.systemImageName
            // Drawn large and scaled into the front panel, so it stays sharp.
            folderIcon.setIcon(
                folder.systemImageName.flatMap { Self.symbol($0, size: 24, weight: .bold) },
                color: BrowserChromeColors.sidebarFolderStroke,
            )
        }
        folderIcon.setShowsDots(showsOpenTabs && !folder.isExpanded)
        folderIconID = folder.id
        tooltipTitle = nil
        setAccessibilityIdentifier("browser.sidebar.folder.\(folder.id)")
        renameField.setAccessibilityIdentifier("browser.sidebar.rename-folder.\(folder.id)")
        updateCommon(renaming: renaming, renameTitle: title, isResizing: isResizing, resetID: resetID)
    }

    func update(
        space: BrowserChromeModel.Space,
        renaming: Bool,
        collapsed: Bool,
        hasPinnedTabs: Bool,
        dropTargeted: Bool,
        isResizing: Bool,
        resetID: Int,
    ) {
        kind = .space
        title = space.title
        indent = 0
        self.dropTargeted = dropTargeted
        self.collapsed = collapsed
        self.hasPinnedTabs = hasPinnedTabs
        baseSymbol = space.systemImageName
        tooltipTitle = nil
        closeButton.configureSymbol("ellipsis", title: BrowserStrings.spaceChangeIconAction)
        closeButton.tooltipTitle = nil
        setAccessibilityIdentifier("browser.sidebar.space-header.\(space.id)")
        renameField.setAccessibilityIdentifier("browser.sidebar.rename-space.\(space.id)")
        updateCommon(renaming: renaming, renameTitle: title, isResizing: isResizing, resetID: resetID)
    }

    /// A Split View shows as one row with a chip per pane, in pane order,
    /// at the position of its first member.
    func update(
        split members: [BrowserChromeModel.Tab],
        focusedTabID: String?,
        selected: Bool,
        multiSelected: Bool = false,
        indentLevel: Int = 0,
        name: BrowserSidebarSplitName? = nil,
        icons: [String: String] = [:],
        recordingTabIDs: Set<String> = [],
        isResizing: Bool,
        resetID: Int = 0,
    ) {
        kind = .split
        self.selected = selected
        self.multiSelected = multiSelected
        pinnedURLRow = false
        splitPinnedControls = false
        indent = CGFloat(max(indentLevel, 0)) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
        splitMemberIDs = members.map(\.id)
        splitName = name
        title = name?.title ?? members.map(\.displayTitle).joined(separator: ", ")
        baseSymbol = name?.systemImageName ?? "rectangle.split.2x1"
        symbol.image = Self.symbol(baseSymbol, size: BrowserChromeLayout.sidebarFaviconSize)
        symbol.contentTintColor = BrowserChromeColors.secondaryText
        tooltipTitle = nil
        tooltipCaption = nil
        tooltipShortcut = nil
        while splitChips.count < members.count {
            let chip = BrowserNativeSidebarSplitChipView()
            chip.closeButton.onAction = { [weak self, weak chip] in
                guard let self, let id = chip?.tabID else { return }
                onCloseSplitMember(id)
            }
            chip.onPress = { [weak self, weak chip] in
                guard let self, let id = chip?.tabID else { return }
                onSelectSplitMember(id)
            }
            addSubview(chip)
            splitChips.append(chip)
        }
        while splitChips.count > members.count {
            splitChips.removeLast().removeFromSuperview()
        }
        for (chip, tab) in zip(splitChips, members) {
            chip.update(
                tab: tab,
                focused: selected && tab.id == focusedTabID,
                icon: icons[tab.id],
                recording: recordingTabIDs.contains(tab.id),
            )
            chip.isCompact = name != nil
        }
        setAccessibilityIdentifier("browser.sidebar.split.\(members.first?.id ?? "")")
        updateCommon(
            renaming: false,
            renameTitle: title,
            isResizing: isResizing,
            resetID: resetID,
        )
        setAccessibilityLabel("\(BrowserStrings.splitViewButtonTitle): \(title)")
    }

    func updateNewTab(isPresented: Bool, isResizing: Bool, descriptor _: BrowserCommandDescriptor) {
        let wasSelected = selected
        kind = .newTab
        title = BrowserStrings.sidebarNewTab
        indent = 0
        selected = isPresented
        tooltipTitle = nil
        tooltipShortcut = nil
        symbol.image = Self.symbol("plus", size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .regular)
        symbol.contentTintColor = BrowserChromeColors.secondaryText
        setAccessibilityIdentifier("browser.sidebar.new-tab")
        updateCommon(renaming: false, renameTitle: title, isResizing: isResizing, resetID: 0)
        if wasSelected, !isPresented {
            synchronizeHoverWithPointer()
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        if suppressNextBlur {
            suppressNextBlur = false
            return
        }
        guard isRenaming else { return }
        if kind == .space || hasRenameChanged {
            onCommitRename(renameField.stringValue)
        }
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            suppressNextBlur = true
            renameField.pendingFocus = false
            if kind == .space || hasRenameChanged {
                onCommitRename(renameField.stringValue)
            } else {
                onCancelRename()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suppressNextBlur = true
            renameField.pendingFocus = false
            renameField.stringValue = initialRenameTitle
            onCancelRename()
            return true
        default: return false
        }
    }

    /// Follows Command while the pointer is on the pinned icon, for its caption.
    private func watchSeparateKey() {
        if pinnedIconHovered, separateKeyMonitor == nil {
            separateKeyHeld = NSEvent.modifierFlags.contains(.command)
            separateKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let held = event.modifierFlags.contains(.command)
                if held != separateKeyHeld {
                    separateKeyHeld = held
                    refreshAppearance()
                }
                return event
            }
        } else if !pinnedIconHovered, let monitor = separateKeyMonitor {
            NSEvent.removeMonitor(monitor)
            separateKeyMonitor = nil
            separateKeyHeld = false
        }
    }

    private func updateSurface() {
        let selectedFill = enclosingSpaceThemePalette?.selection ?? BrowserChromeColors.rowSelected
        selectionSurface.alphaScale = selected || !multiSelected ? 1 : 0.82
        selectionSurface.fill =
            switch kind {
            case .split,
                 .tab:
                selected || multiSelected
                    ? selectedFill
                    : isHovered && !splitPinnedControls ? BrowserChromeColors.rowHover : nil
            case .newTab:
                isResizing
                    ? nil
                    : selected
                        ? selectedFill
                        : isHovered ? BrowserChromeColors.rowHover : nil
            case .folder:
                // The sidebar draws a band behind a folder that takes the drop.
                isHovered && !dropTargeted ? BrowserChromeColors.rowHover : nil
            case .space:
                dropTargeted ? selectedFill : isHovered ? BrowserChromeColors.rowHover : nil
            case .appTab: nil
            }
    }

    private func updateDisclosureTransform() {
        let angle = kind == .space && hasPinnedTabs && isHovered && !isRenaming ? .pi / 2 * disclosureProgress : 0
        symbol.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbol.layer?.setAffineTransform(CGAffineTransform(translationX: symbol.bounds.midX, y: symbol.bounds.midY)
            .rotated(by: angle)
            .translatedBy(x: -symbol.bounds.midX, y: -symbol.bounds.midY))
        CATransaction.commit()
    }

    /// Chips: 28 pt tall, equal widths, 4 pt apart and 4 pt inside the
    /// row's own rounded surface.
    private func layoutSplitChips() {
        let inset: CGFloat = 4
        let spacing: CGFloat = 4
        let height = min(BrowserNativeSidebarSplitChipView.height, max(bounds.height - inset * 2, 0))
        let count = CGFloat(splitChips.count)
        guard count > 0 else { return }
        if splitName != nil {
            let side = height
            var x = bounds.width - inset - side * count - spacing * (count - 1)
            let chipsMinX = x
            for chip in splitChips {
                chip.frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
                x += side + spacing
            }
            let icon = BrowserChromeLayout.sidebarFaviconSize
            symbol.frame = NSRect(
                x: indent + (BrowserChromeLayout.sidebarRowLeadingColumnWidth - icon) / 2,
                y: (bounds.height - icon) / 2,
                width: icon,
                height: icon,
            )
            let titleX = indent + BrowserChromeLayout.sidebarRowTitleX
            titleLabel.frame = NSRect(
                x: titleX,
                y: (bounds.height - 17) / 2,
                width: max(chipsMinX - 6 - titleX, 0),
                height: 17,
            )
            return
        }
        let available = max(bounds.width - indent - inset * 2 - spacing * (count - 1), 0)
        let width = (available / count).rounded(.down)
        var x = indent + inset
        for chip in splitChips {
            chip.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            x += width + spacing
        }
    }

    private func selectSplitMember(at event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        let chip = point.flatMap { point in splitChips.first { $0.frame.contains(point) } }
        if let id = chip?.tabID ?? splitChips.first(where: \.isFocused)?.tabID ?? splitMemberIDs.first {
            onSelectSplitMember(id)
        }
    }

    /// A plain press shows its page at once instead of on release; a press on
    /// the shown tab still renames it on release.
    private func selectOnPress(_ event: NSEvent) -> Bool {
        guard !isRenaming, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        else { return false }
        switch kind {
        case .tab:
            if selected {
                return false
            }
            if splitPinnedControls {
                let point = convert(event.locationInWindow, from: nil)
                if point.x >= indent, point.x < indent + BrowserChromeLayout.sidebarPinnedURLIconButtonSize {
                    return false
                }
            }
            onSelect()
            return true
        case .appTab:
            onSelect()
            return true
        case .split:
            selectSplitMember(at: event)
            return true
        case .folder, .newTab, .space:
            return false
        }
    }

    private func primaryClick(_ event: NSEvent?) {
        guard !isRenaming else { return }
        switch kind {
        case .tab:
            if splitPinnedControls, let event, event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift)
            {
                let point = convert(event.locationInWindow, from: nil)
                if point.x >= indent, point.x < indent + BrowserChromeLayout.sidebarPinnedURLIconButtonSize {
                    onSeparateFromPinnedTab()
                    return
                }
            }
            if let event, !event.modifierFlags.intersection([.command, .shift]).isEmpty {
                onModifiedSelect(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                return
            }
            if splitPinnedControls, let event {
                let point = convert(event.locationInWindow, from: nil)
                if point.x >= indent, point.x < indent + BrowserChromeLayout.sidebarPinnedURLIconButtonSize {
                    onBackToPinnedURL()
                    return
                }
            }
            if selected {
                onBeginRename()
            } else {
                onSelect()
            }
        case .folder: onToggle()
        case .space: if hasPinnedTabs {
                onToggle()
            } else {
                onBeginRename()
            }
        case .appTab,
             .newTab: onSelect()
        case .split: selectSplitMember(at: event)
        }
    }

    private func updateCommon(renaming: Bool, renameTitle: String, isResizing: Bool, resetID: Int) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(
            ofSize: kind == .space ? BrowserChromeLayout.sidebarSpaceFontSize : BrowserChromeLayout.sidebarRowFontSize,
            weight: kind == .folder || kind == .space ? .semibold : .regular,
        )
        // The editor keeps the title's font, so a folder's name stays semibold.
        renameField.font = titleLabel.font
        titleLabel.textColor = kind == .space || kind == .newTab
            ? BrowserChromeColors.sidebarDimText
            : enclosingSpaceThemePalette?.title.nsColor ?? BrowserChromeColors.sidebarRowText
        setAccessibilityLabel(title)
        if self.resetID != resetID || isResizing && !self.isResizing {
            resetInteraction()
        }
        self.resetID = resetID
        self.isResizing = isResizing
        if isRenaming != renaming {
            isRenaming = renaming
            if renaming {
                initialRenameTitle = renameTitle
                renameField.stringValue = renameTitle
                suppressNextBlur = false
            } else {
                suppressNextBlur = true
            }
            renameField.syncFocus(renaming)
        }
        isInteractionEnabled = !isResizing && !renaming
        refreshAppearance()
    }

    private func refreshAppearance() {
        titleLabel.isHidden = kind == .appTab || (kind == .split && splitName == nil) || isRenaming
        renameField.isHidden = !isRenaming
        folderIcon.isHidden = kind != .folder
        // VoiceOver hears which tab is shown or selected.
        setAccessibilitySelected((kind == .tab || kind == .appTab || kind == .split) && (selected || multiSelected))
        // Hover splits the row into the icon and title areas, and the slash between them goes.
        let slashVisible = showsPinnedSlash && !isHovered
        if pinnedSlash.isHidden == slashVisible {
            pinnedSlash.isHidden = !slashVisible
            needsLayout = true
        }
        updateSurface()
        let isTab = kind == .tab || kind == .appTab
        favicon.isHidden = !isTab || tabIcon != nil
        symbol.isHidden = (isTab && tabIcon == nil) || (kind == .split && splitName == nil) || kind == .folder
        for chip in splitChips {
            chip.isHidden = kind != .split
            chip.isInteractionEnabled = !isResizing
        }
        let showCaption = kind == .tab && (pinnedIconHovered || developerHost != nil) && !isRenaming
        developerBorder.isHidden = kind != .tab || developerHost == nil || !selected
        if showCaption != captionTarget {
            captionTarget = showCaption
            let from = captionProgress
            let to = showCaption ? 1.0 : 0.0
            if showCaption {
                captionLabel.isHidden = false
            }
            if window == nil {
                captionProgress = to
                captionLabel.isHidden = !showCaption
                captionLabel.alphaValue = to
            } else {
                captionAnimation.start(.caption) { [weak self] progress in
                    guard let self else { return }
                    captionProgress = from + (to - from) * progress
                    captionLabel.alphaValue = captionProgress
                    needsLayout = true
                } completion: { [weak self] in self?.captionLabel.isHidden = !showCaption }
            }
        }
        captionLabel.stringValue = pinnedIconHovered
            ? separateKeyHeld
                ? BrowserStrings.pinnedTabSeparate
                : BrowserStrings.pinnedTabBackToPinnedURL
            : developerHost ?? ""
        closeButton.isHidden = !(kind == .space || kind == .tab) || !isHovered || isRenaming || isResizing
        let showsPeekBadge = kind == .tab && peekPageURLString != nil && closeButton.isHidden && !isRenaming
        if peekBadge.isHidden == showsPeekBadge {
            peekBadge.isHidden = !showsPeekBadge
            needsLayout = true
        }
        muteButton.isHidden = kind != .tab || !(isMuted || isAudible) || isRenaming || isResizing
        let showsRecording = (kind == .tab || kind == .appTab) && isRecording && !isRenaming
        if recordingDot.isHidden == showsRecording {
            recordingDot.isHidden = !showsRecording
            needsLayout = true
        }
        if kind == .space {
            let disclosure = hasPinnedTabs && isHovered && !isRenaming
            symbol.image = Self.symbol(
                disclosure ? "chevron.right" : baseSymbol,
                size: BrowserChromeLayout.sidebarSpaceSymbolSize,
            )
            showsSpaceTitleAtLeadingEdge = !disclosure && baseSymbol == BrowserChromeModel.defaultSpaceIconName
            symbol.isHidden = showsSpaceTitleAtLeadingEdge
            symbol.contentTintColor = disclosure ? BrowserChromeColors.secondaryText : BrowserChromeColors.primaryText
            updateDisclosureTransform()
        }
        permitsTooltip = !isRenaming && !isResizing && !pinnedIconHovered && !accessoryHovered &&
            !(kind == .newTab && selected)
        refreshTooltip()
        needsLayout = true
        needsDisplay = true
    }
}

// MARK: - BrowserNativeSidebarPinnedSlashView

/// A line corner to corner, 1 pt in from each, 2 pt wide with round caps,
/// leaning forward: 15 pt tall and 2 pt across.
final class BrowserNativeSidebarPinnedSlashView: NSView {
    // MARK: Internal

    static let size = NSSize(width: 4, height: 15)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1, y: bounds.height - 1))
        path.line(to: NSPoint(x: bounds.width - 1, y: 1))
        path.lineWidth = 2
        path.lineCapStyle = .round
        BrowserChromeColors.sidebarPinnedSlash.setStroke()
        path.stroke()
    }
}

// MARK: - BrowserNativeSidebarSelectionSurface

/// A row's hover or selection pill, with a continuous curve and a short fade.
private final class BrowserNativeSidebarSelectionSurface: NSView {
    // MARK: Internal

    override var wantsUpdateLayer: Bool { true }

    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var alphaScale: CGFloat = 1 { didSet { if alphaScale != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = BrowserChromeLayout.sidebarRowCornerRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        let color = fill.map { $0.withAlphaComponent($0.alphaComponent * alphaScale).cgColor } ?? NSColor.clear.cgColor
        guard color != layer.backgroundColor else { return }
        layer.backgroundColor = color
    }
}

// MARK: - BrowserNativeSidebarSplitChipView

/// One pane of a Split View row: favicon, title and a close button on hover.
final class BrowserNativeSidebarSplitChipView: NSView {
    // MARK: Internal

    static let height: CGFloat = 28

    override var isFlipped: Bool { true }

    let closeButton = BrowserNativeChromeButton(symbol: "xmark", title: "", style: .sidebarClose, action: {})
    private(set) var tabID: String?
    private(set) var isFocused = false
    var onPress: () -> Void = {}

    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            closeButton.isHidden = !isHovered || !isInteractionEnabled || isCompact
            needsLayout = true
            needsDisplay = true
        }
    }

    var isInteractionEnabled = true {
        didSet { closeButton.isHidden = !isHovered || !isInteractionEnabled || isCompact }
    }

    /// A favicon-only chip in a renamed split row; its pane closes from the row menu.
    var isCompact = false {
        didSet {
            guard oldValue != isCompact else { return }
            titleLabel.isHidden = isCompact
            closeButton.isHidden = !isHovered || !isInteractionEnabled || isCompact
            needsLayout = true
        }
    }

    /// Split cells lead with the recording dot.
    let recordingDot = BrowserRecordingDotView()

    // MARK: Private

    private let selectionSurface = BrowserNativeSidebarSelectionSurface()
    private let favicon: BrowserFaviconNSView = {
        let view = BrowserFaviconNSView()
        view.fallback = .square
        return view
    }()

    private let symbol = NSImageView()
    private let titleLabel = BrowserNativeControls.label("", size: 12.5, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [favicon, symbol, recordingDot, titleLabel, closeButton] {
            addSubview(view)
        }
        symbol.isHidden = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.wraps = false
        closeButton.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let icon = BrowserChromeLayout.sidebarFaviconSize
        if isCompact {
            favicon.frame = NSRect(
                x: (bounds.width - icon) / 2,
                y: (bounds.height - icon) / 2,
                width: icon,
                height: icon,
            )
            symbol.frame = favicon.frame
            let dot = BrowserRecordingDotView.diameter
            recordingDot.frame = NSRect(x: 3, y: 3, width: dot, height: dot)
            return
        }
        let padding: CGFloat = 7
        var iconX = padding
        if !recordingDot.isHidden {
            let dot = BrowserRecordingDotView.diameter
            recordingDot.frame = NSRect(x: padding, y: (bounds.height - dot) / 2, width: dot, height: dot)
            iconX = recordingDot.frame.maxX + 5
        }
        favicon.frame = NSRect(x: iconX, y: (bounds.height - icon) / 2, width: icon, height: icon)
        symbol.frame = favicon.frame
        let closeSize: CGFloat = 20
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - 4,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize,
        )
        let titleX = favicon.frame.maxX + 6
        let trailing = closeButton.isHidden ? bounds.width - padding : closeButton.frame.minX - 2
        titleLabel.frame = NSRect(x: titleX, y: (bounds.height - 17) / 2, width: max(trailing - titleX, 0), height: 17)
    }

    override func draw(_: NSRect) {
        (isFocused ? BrowserChromeColors.splitChipFocused : BrowserChromeColors.splitChip).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if isHovered, !isFocused {
            BrowserChromeColors.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }

    /// `icon` is the tab's chosen symbol, shown instead of its favicon.
    func update(tab: BrowserChromeModel.Tab, focused: Bool, icon: String? = nil, recording: Bool = false) {
        tabID = tab.id
        if recordingDot.isHidden == recording {
            recordingDot.isHidden = !recording
            needsLayout = true
        }
        if isFocused != focused {
            isFocused = focused
            needsDisplay = true
        }
        favicon.update(url: tab.faviconURL, pageURLString: tab.urlString)
        favicon.isHidden = icon != nil
        symbol.isHidden = icon == nil
        symbol.image = icon.flatMap {
            BrowserIconImage.image(named: $0, pointSize: 12)
        }
        symbol.contentTintColor = BrowserChromeColors.primaryText
        titleLabel.stringValue = tab.displayTitle
        titleLabel.textColor = BrowserChromeColors.primaryText
        closeButton.setAccessibilityLabel(BrowserStrings.tabCloseAction)
        closeButton.setAccessibilityIdentifier("browser.sidebar.split-member.close.\(tab.id)")
        setAccessibilityLabel(tab.displayTitle)
        setAccessibilityIdentifier("browser.sidebar.split-member.\(tab.id)")
    }
}

// MARK: - BrowserDeveloperRowBorder

/// The hazard-tape edge of a selected row whose site is in Developer Mode.
private final class BrowserDeveloperRowBorder: NSView {
    private let base = CAShapeLayer()
    private let dashes = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [base, dashes] {
            shape.fillColor = nil
            shape.lineWidth = 2
            layer?.addSublayer(shape)
        }
        base.strokeColor = NSColor(srgbRed: 49 / 255, green: 41 / 255, blue: 14 / 255, alpha: 1).cgColor
        dashes.strokeColor = NSColor(srgbRed: 247 / 255, green: 206 / 255, blue: 70 / 255, alpha: 1).cgColor
        dashes.lineDashPattern = [6, 6]
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let radius = BrowserChromeLayout.sidebarRowCornerRadius
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil,
        )
        for shape in [base, dashes] {
            shape.frame = bounds
            shape.path = path
        }
    }
}
