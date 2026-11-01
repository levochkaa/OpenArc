// BrowserMiniPlayerNSView.swift

import AppKit

// MARK: - BrowserMiniPlayerNSView

/// Mini player above the Space dock, for media playing in a tab off
/// screen: the tab's icon (back to the tab), previous track, play or pause,
/// next track and mute. On hover it grows upward by a row with the title and
/// Close.
final class BrowserMiniPlayerNSView: NSView {
    // MARK: Internal

    enum Action: Equatable { case backToTab, previousTrack, playPause, nextTrack, toggleMute, close }

    override var isFlipped: Bool { true }

    var onAction: (Action) -> Void = { _ in }
    /// The pointer entered or left; the stack grows the player upward.
    var onExpansionChange: () -> Void = {}

    private(set) var item: BrowserMiniPlayerItem?
    private(set) var isExpanded = false

    // MARK: Private

    private let material = NSVisualEffectView()
    private let outline = BrowserNativeSurface()
    private let titleLabel = BrowserNativeControls.label(
        "",
        size: 12,
        weight: .medium,
        color: BrowserChromeColors.primaryText,
    )
    private let tabButton = BrowserNativePressableView()
    private let favicon = BrowserFaviconNSView()
    private let previousButton = BrowserNativeChromeButton(
        symbol: "backward.end.fill",
        title: BrowserStrings.miniPlayerPreviousTrack,
        style: .miniPlayer,
        pressEffect: .left,
        action: {},
    )
    private let playButton = BrowserNativeChromeButton(
        symbol: "pause.fill",
        title: BrowserStrings.miniPlayerPause,
        style: .miniPlayer,
        pressEffect: .compress,
        action: {},
    )
    private let nextButton = BrowserNativeChromeButton(
        symbol: "forward.end.fill",
        title: BrowserStrings.miniPlayerNextTrack,
        style: .miniPlayer,
        pressEffect: .right,
        action: {},
    )
    private let muteButton = BrowserNativeChromeButton(
        symbol: "speaker.wave.2.fill",
        title: BrowserStrings.tabMuteAction,
        style: .miniPlayer,
        pressEffect: .compress,
        action: {},
    )
    private let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.miniPlayerClose,
        style: .sidebarClose,
        action: {},
    )
    private var tracking: NSTrackingArea?

    /// How far it has grown, from 0 to 1.
    private var expansion: CGFloat = 0
    private let expansionAnimation = BrowserNativeAnimation()

    var preferredHeight: CGFloat {
        BrowserChromeLayout.sidebarMiniPlayerHeight
            + (BrowserChromeLayout.sidebarMiniPlayerExpandedHeight - BrowserChromeLayout.sidebarMiniPlayerHeight)
            * expansion
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .active
        addSubview(material)
        outline.cornerRadius = 8
        outline.strokeColor = NSColor.labelColor.withAlphaComponent(0.08)
        addSubview(outline)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true
        closeButton.isHidden = true
        tabButton.cornerRadius = BrowserChromeLayout.sidebarCloseCornerRadius
        tabButton.addSubview(favicon)
        tabButton.onClick = { [weak self] _ in self?.onAction(.backToTab) }
        tabButton.onHoverChanged = { [weak self] hovered in
            self?.tabButton.fillColor = hovered ? BrowserChromeColors.rowHover : .clear
        }
        tabButton.tooltipTitle = BrowserStrings.miniPlayerBackToTab
        tabButton.tooltipPlacement = .aboveCapsule
        let actions: [(BrowserNativeChromeButton, Action)] = [
            (previousButton, .previousTrack),
            (playButton, .playPause),
            (nextButton, .nextTrack),
            (muteButton, .toggleMute),
            (closeButton, .close),
        ]
        for (button, action) in actions {
            button.onAction = { [weak self] in self?.onAction(action) }
            button.tooltipPlacement = .aboveCapsule
        }
        for view in [
            titleLabel,
            closeButton,
            tabButton,
            previousButton,
            playButton,
            nextButton,
            muteButton,
        ] as [NSView] {
            outline.addSubview(view)
        }
        tabButton.setAccessibilityIdentifier("browser.mini-player.tab")
        previousButton.setAccessibilityIdentifier("browser.mini-player.previous")
        playButton.setAccessibilityIdentifier("browser.mini-player.play-pause")
        nextButton.setAccessibilityIdentifier("browser.mini-player.next")
        muteButton.setAccessibilityIdentifier("browser.mini-player.mute")
        closeButton.setAccessibilityIdentifier("browser.mini-player.close")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if isExpanded {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        setExpanded(true)
    }

    override func mouseExited(with _: NSEvent) {
        setExpanded(false)
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
        let size = BrowserChromeLayout.sidebarMiniPlayerButtonSize
        let inset = BrowserChromeLayout.sidebarMiniPlayerInset
        let controlsY = bounds.height - (BrowserChromeLayout.sidebarMiniPlayerHeight + size) / 2
        let controls: [NSView] = [tabButton, previousButton, playButton, nextButton, muteButton]
        let step = max(bounds.width - inset * 2 - size, 0) / CGFloat(controls.count - 1)
        for (index, view) in controls.enumerated() {
            view.frame = NSRect(x: inset + CGFloat(index) * step, y: controlsY, width: size, height: size)
        }
        favicon.frame = tabButton.bounds.insetBy(dx: 4, dy: 4)
        let titleRowY = (BrowserChromeLayout.sidebarMiniPlayerHeight - size) / 2
        closeButton.frame = NSRect(x: bounds.width - inset - size, y: titleRowY, width: size, height: size)
        titleLabel.frame = NSRect(
            x: inset + 4,
            y: titleRowY + (size - 16) / 2,
            width: max(closeButton.frame.minX - inset - 8, 0),
            height: 16,
        )
    }

    func update(_ item: BrowserMiniPlayerItem) {
        guard item != self.item else { return }
        self.item = item
        setAccessibilityIdentifier("browser.mini-player.\(item.tabID)")
        setAccessibilityLabel(item.title)
        titleLabel.stringValue = item.title
        favicon.update(url: item.faviconURL, pageURLString: item.pageURLString)
        playButton.configureSymbol(
            item.isPlaying ? "pause.fill" : "play.fill",
            title: item.isPlaying ? BrowserStrings.miniPlayerPause : BrowserStrings.miniPlayerPlay,
        )
        muteButton.configureSymbol(
            item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: item.isMuted ? BrowserStrings.tabUnmuteAction : BrowserStrings.tabMuteAction,
        )
        previousButton.isEnabled = item.hasPreviousTrack
        nextButton.isEnabled = item.hasNextTrack
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        titleLabel.isHidden = false
        closeButton.isHidden = false
        let from = expansion
        let to: CGFloat = expanded ? 1 : 0
        guard window != nil else {
            applyExpansion(to, final: true)
            return
        }
        expansionAnimation.start(expanded ? .miniPlayerGrow : .miniPlayerShrink) { [weak self] progress in
            self?.applyExpansion(from + (to - from) * progress, final: false)
        } completion: { [weak self] in
            self?.applyExpansion(to, final: true)
        }
    }

    private func applyExpansion(_ value: CGFloat, final: Bool) {
        expansion = value
        titleLabel.alphaValue = value
        closeButton.alphaValue = value
        if final {
            titleLabel.isHidden = !isExpanded
            closeButton.isHidden = !isExpanded
        }
        needsLayout = true
        onExpansionChange()
    }
}

// MARK: - BrowserMiniPlayerStackNSView

/// The sidebar's mini players, newest nearest the dock. The list keeps room
/// for their collapsed rows; a player growing on hover covers the list's
/// bottom instead of moving it.
final class BrowserMiniPlayerStackNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onAction: (String, BrowserMiniPlayerNSView.Action) -> Void = { _, _ in }
    /// The players' heights changed; the sidebar lays the stack out again.
    var onHeightChange: () -> Void = {}

    private(set) var players = [BrowserMiniPlayerNSView]()

    // MARK: Private

    private var items = [BrowserMiniPlayerItem]()

    /// Room the list leaves, from the collapsed players.
    var reservedHeight: CGFloat {
        players.isEmpty ? 0 : height(expanded: false)
    }

    /// The stack's current height, with a player grown on hover.
    var currentHeight: CGFloat {
        players.isEmpty ? 0 : height(expanded: true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        var y = bounds.height
        for player in players.reversed() {
            y -= player.preferredHeight
            player.frame = NSRect(x: 0, y: y, width: bounds.width, height: player.preferredHeight)
            y -= BrowserChromeLayout.sidebarMiniPlayerSpacing
        }
    }

    func update(items: [BrowserMiniPlayerItem]) {
        guard items != self.items else { return }
        self.items = items
        let reusable = Dictionary(players.compactMap { player in player.item.map { ($0.tabID, player) } }) { first, _ in
            first
        }
        let next = items.map { item -> BrowserMiniPlayerNSView in
            let player = reusable[item.tabID] ?? makePlayer()
            player.update(item)
            return player
        }
        for player in players where !next.contains(where: { $0 === player }) {
            player.removeFromSuperview()
        }
        // Newest last, nearest the dock.
        players = next.reversed()
        for player in players where player.superview !== self {
            addSubview(player)
        }
        needsLayout = true
        onHeightChange()
    }

    private func makePlayer() -> BrowserMiniPlayerNSView {
        let player = BrowserMiniPlayerNSView()
        player.onAction = { [weak self, weak player] action in
            guard let id = player?.item?.tabID else { return }
            self?.onAction(id, action)
        }
        player.onExpansionChange = { [weak self] in
            self?.needsLayout = true
            self?.onHeightChange()
        }
        return player
    }

    private func height(expanded: Bool) -> CGFloat {
        players.reduce(CGFloat(players.count - 1) * BrowserChromeLayout.sidebarMiniPlayerSpacing) { total, player in
            total + (expanded ? player.preferredHeight : BrowserChromeLayout.sidebarMiniPlayerHeight)
        }
    }
}
