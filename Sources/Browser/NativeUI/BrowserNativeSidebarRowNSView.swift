// BrowserNativeSidebarRowNSView.swift

import AppKit
import QuartzCore

// MARK: - BrowserNativeSidebarRowNSView

/// One reusable native row for tabs, favorites, folders, space headers, Split
/// Views and New Tab.
final class BrowserNativeSidebarRowNSView: BrowserNativePressableView, NSTextFieldDelegate {
    // MARK: Internal

    enum Kind { case tab, appTab, folder, space, newTab, split }

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
    private(set) var isMuted = false
    private(set) var isAudible = false

    /// Tab IDs of the split shown by this row, in pane order.
    private(set) var splitMemberIDs = [String]()

    /// A renamed split shows its icon and name, and each pane as a favicon.
    private(set) var splitName: BrowserSidebarSplitName?

    var dragOpacity: CGFloat = 1 { didSet { alphaValue = dragOpacity * appearanceProgress } }

    // MARK: Private

    private let selectionSurface = BrowserNativeSidebarSelectionSurface()
    private let folderFill = NSImageView()
    private let favicon = BrowserFaviconNSView()
    private var splitChips = [BrowserNativeSidebarSplitChipView]()
    private let symbol = NSImageView()
    private let badge = NSImageView()
    private var selected = false
    private var multiSelected = false
    private var dropTargeted = false
    private var splitDropSide: BrowserSidebarDragState.SplitDropTarget.Side?
    private var indent: CGFloat = 0
    private var pinnedURLRow = false
    private var splitPinnedControls = false
    private var pinnedIconHovered = false
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
    private var disclosureProgress = 1.0

    private var baseSymbol = ""
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
            disclosureAnimation.start(.easeInOut(0.14)) { [weak self] progress in
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressCurve = .rowPress
        for view in [
            selectionSurface,
            folderFill,
            favicon,
            symbol,
            badge,
            titleLabel,
            captionLabel,
            renameField,
            muteButton,
            closeButton,
        ] {
            addSubview(view)
        }
        muteButton.onAction = { [weak self] in self?.onToggleMute() }
        for image in [folderFill, symbol, badge] {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
        }
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
        onDoubleClick = { [weak self] event in
            guard let self else { return }
            if kind == .tab, let event, !event.modifierFlags.intersection([.command, .shift]).isEmpty {
                primaryClick(event)
                return
            }
            if kind == .folder {
                onBeginRename()
            } else if kind == .tab {
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
        selectionSurface.frame = NSRect(x: indent, y: 0, width: max(bounds.width - indent, 0), height: bounds.height)
        let height = bounds.height
        let closeSize = BrowserChromeLayout.sidebarCloseButtonSize
        closeButton.frame = NSRect(
            x: max(bounds.width - BrowserChromeLayout.sidebarCloseButtonTrailingPadding - closeSize, 0),
            y: (height - closeSize) / 2,
            width: closeSize,
            height: closeSize,
        )
        if kind == .appTab {
            let size = BrowserChromeLayout.appTabIconSize
            favicon.frame = NSRect(x: (bounds.width - size) / 2, y: (height - size) / 2, width: size, height: size)
            symbol.frame = favicon.frame
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
        folderFill.frame = iconFrame
        let badgeSize = BrowserChromeLayout.sidebarPinnedFolderBadgeIconSize
        badge.frame = NSRect(
            x: iconFrame.midX - badgeSize / 2,
            y: iconFrame.midY - badgeSize / 2 + 1,
            width: badgeSize,
            height: badgeSize,
        )
        var titleX = indent + BrowserChromeLayout.sidebarRowTitleX
        if !muteButton.isHidden {
            // The speaker sits between the icon and the title.
            let muteSize: CGFloat = 26
            muteButton.frame = NSRect(x: titleX - 1, y: (height - muteSize) / 2, width: muteSize, height: muteSize)
            titleX = muteButton.frame.maxX
        }
        let trailing = closeButton.isHidden
            ? bounds.width - BrowserChromeLayout.sidebarTabTrailingPadding
            : closeButton.frame.minX
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
        renameField.frame = NSRect(x: titleX, y: (height - 17) / 2, width: titleWidth, height: 17)
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
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(
            pointSize: size,
            weight: weight,
        ))
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

    func removeAnimated() {
        guard window != nil else { removeFromSuperview()
            return
        }
        isInteractionEnabled = false
        closeButton.isEnabled = false
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
        icon: String? = nil,
    ) {
        kind = appTile ? .appTab : .tab
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
        symbol.image = Self.symbol(baseSymbol, size: BrowserChromeLayout.sidebarPinnedFolderIconSize)
        symbol.contentTintColor = BrowserChromeColors.sidebarRowText
        folderFill.image = Self.symbol("folder.fill", size: BrowserChromeLayout.sidebarPinnedFolderIconSize)
        folderFill.contentTintColor = BrowserChromeColors.sidebarFolderFill
        badge.image = folder.systemImageName.map { Self.symbol(
            $0,
            size: BrowserChromeLayout.sidebarPinnedFolderBadgeIconSize,
            weight: .bold,
        ) } ?? nil
        badge.contentTintColor = BrowserChromeColors.sidebarRowText
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
            chip.update(tab: tab, focused: selected && tab.id == focusedTabID, icon: icons[tab.id])
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

    func updateNewTab(isPresented: Bool, isResizing: Bool, descriptor: BrowserCommandDescriptor) {
        let wasSelected = selected
        kind = .newTab
        title = BrowserStrings.sidebarNewTab
        indent = 0
        selected = isPresented
        tooltipTitle = descriptor.helpTitle
        tooltipShortcut = descriptor.shortcut
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
            case .folder,
                 .space:
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

    private func primaryClick(_ event: NSEvent?) {
        guard !isRenaming else { return }
        switch kind {
        case .tab:
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
        folderFill.isHidden = kind != .folder
        updateSurface()
        let isTab = kind == .tab || kind == .appTab
        favicon.isHidden = !isTab || tabIcon != nil
        symbol.isHidden = (isTab && tabIcon == nil) || (kind == .split && splitName == nil)
        for chip in splitChips {
            chip.isHidden = kind != .split
            chip.isInteractionEnabled = !isResizing
        }
        badge.isHidden = kind != .folder || badge.image == nil
        let showCaption = kind == .tab && pinnedIconHovered && !isRenaming
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
                captionAnimation.start(.easeOut(0.16)) { [weak self] progress in
                    guard let self else { return }
                    captionProgress = from + (to - from) * progress
                    captionLabel.alphaValue = captionProgress
                    needsLayout = true
                } completion: { [weak self] in self?.captionLabel.isHidden = !showCaption }
            }
        }
        captionLabel.stringValue = BrowserStrings.pinnedTabBackToPinnedURL
        closeButton.isHidden = !(kind == .space || kind == .tab) || !isHovered || isRenaming || isResizing
        muteButton.isHidden = kind != .tab || !(isMuted || isAudible) || isRenaming || isResizing
        if kind == .space {
            let disclosure = hasPinnedTabs && isHovered && !isRenaming
            symbol.image = Self.symbol(
                disclosure ? "chevron.right" : baseSymbol,
                size: BrowserChromeLayout.sidebarSpaceSymbolSize,
            )
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
        if window != nil, let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from
            fade.toValue = color
            fade.duration = 0.1
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            layer.add(fade, forKey: "backgroundColor")
        }
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

    // MARK: Private

    private let selectionSurface = BrowserNativeSidebarSelectionSurface()
    private let folderFill = NSImageView()
    private let favicon = BrowserFaviconNSView()
    private let symbol = NSImageView()
    private let titleLabel = BrowserNativeControls.label("", size: 12.5, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [favicon, symbol, titleLabel, closeButton] {
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
            return
        }
        let padding: CGFloat = 7
        favicon.frame = NSRect(x: padding, y: (bounds.height - icon) / 2, width: icon, height: icon)
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
    func update(tab: BrowserChromeModel.Tab, focused: Bool, icon: String? = nil) {
        tabID = tab.id
        if isFocused != focused {
            isFocused = focused
            needsDisplay = true
        }
        favicon.update(url: tab.faviconURL, pageURLString: tab.urlString)
        favicon.isHidden = icon != nil
        symbol.isHidden = icon == nil
        symbol.image = icon.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
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
