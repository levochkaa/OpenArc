// BrowserMiniPlayerNSView.swift

import AppKit

// MARK: - BrowserMiniPlayerNSView

/// Mini player above the Space dock, for media playing in a tab off
/// screen: the tab's icon (back to the tab), previous track, play or pause,
/// next track and mute. On hover it grows upward by a row with the title and
/// Close.
final class BrowserMiniPlayerNSView: NSView {
    // MARK: Internal

    enum Action: Equatable {
        case backToTab, previousTrack, playPause, nextTrack, toggleMute, close, backToPictureInPicture
        case toggleMicrophone, toggleCamera
    }

    private static let volumeRowHeight: CGFloat = 32

    override var isFlipped: Bool { true }

    var onAction: (Action) -> Void = { _ in }
    var onVolumeChange: (Double) -> Void = { _ in }
    /// The pointer entered or left; the stack grows the player upward.
    var onExpansionChange: () -> Void = {}

    private(set) var item: BrowserMiniPlayerItem?
    private(set) var isExpanded = false

    // MARK: Private

    private let volumeSlider = BrowserMiniPlayerVolumeSlider()
    private var showsVolume = false
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
    private let microphoneButton = BrowserNativeChromeButton(
        symbol: "mic.fill",
        title: BrowserStrings.miniPlayerMuteMicrophone,
        style: .miniPlayer,
        pressEffect: .compress,
        action: {},
    )
    private let cameraButton = BrowserNativeChromeButton(
        symbol: "video.fill",
        title: BrowserStrings.miniPlayerTurnOffCamera,
        style: .miniPlayer,
        pressEffect: .compress,
        action: {},
    )
    private let pictureInPictureButton = BrowserNativeChromeButton(
        symbol: "pip.enter",
        title: BrowserStrings.miniPlayerBackToPictureInPicture,
        style: .sidebarClose,
        action: {},
    )
    /// Clips the title, which scrolls when it is longer than its row.
    private let titleClip = NSView()
    private var tracking: NSTrackingArea?
    private var marqueeDistance: CGFloat = 0

    /// How far it has grown, from 0 to 1.
    private var expansion: CGFloat = 0
    private let expansionAnimation = BrowserNativeAnimation()

    var preferredHeight: CGFloat {
        (showsVolume ? Self.volumeRowHeight : 0) + BrowserChromeLayout.sidebarMiniPlayerHeight
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
        titleLabel.lineBreakMode = .byClipping
        titleClip.wantsLayer = true
        titleClip.layer?.masksToBounds = true
        titleClip.isHidden = true
        titleClip.addSubview(titleLabel)
        closeButton.isHidden = true
        pictureInPictureButton.isHidden = true
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
            (pictureInPictureButton, .backToPictureInPicture),
            (microphoneButton, .toggleMicrophone),
            (cameraButton, .toggleCamera),
        ]
        for (button, action) in actions {
            button.onAction = { [weak self] in self?.onAction(action) }
            button.tooltipPlacement = .aboveCapsule
        }
        for view in [
            titleClip,
            closeButton,
            pictureInPictureButton,
            tabButton,
            previousButton,
            playButton,
            nextButton,
            muteButton,
            microphoneButton,
            cameraButton,
        ] as [NSView] {
            outline.addSubview(view)
        }
        outline.addSubview(volumeSlider)
        volumeSlider.isHidden = true
        volumeSlider.onChange = { [weak self] in self?.onVolumeChange($0) }
        muteButton.onLongPress = { [weak self] in self?.setShowsVolume(true) }
        tabButton.setAccessibilityIdentifier("browser.mini-player.tab")
        previousButton.setAccessibilityIdentifier("browser.mini-player.previous")
        playButton.setAccessibilityIdentifier("browser.mini-player.play-pause")
        nextButton.setAccessibilityIdentifier("browser.mini-player.next")
        muteButton.setAccessibilityIdentifier("browser.mini-player.mute")
        closeButton.setAccessibilityIdentifier("browser.mini-player.close")
        pictureInPictureButton.setAccessibilityIdentifier("browser.mini-player.picture-in-picture")
        microphoneButton.setAccessibilityIdentifier("browser.mini-player.microphone")
        cameraButton.setAccessibilityIdentifier("browser.mini-player.camera")
        microphoneButton.isHidden = true
        cameraButton.isHidden = true
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
        setShowsVolume(false)
        setExpanded(false)
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
        let size = BrowserChromeLayout.sidebarMiniPlayerButtonSize
        let inset = BrowserChromeLayout.sidebarMiniPlayerInset
        let volumeRow: CGFloat = showsVolume ? Self.volumeRowHeight : 0
        let controlsY = bounds.height - volumeRow - (BrowserChromeLayout.sidebarMiniPlayerHeight + size) / 2
        // A call's player has its microphone and camera in place of the tracks.
        let controls: [NSView] = item?.call == nil
            ? [tabButton, previousButton, playButton, nextButton, muteButton]
            : [tabButton, microphoneButton, cameraButton, muteButton]
        let step = max(bounds.width - inset * 2 - size, 0) / CGFloat(controls.count - 1)
        for (index, view) in controls.enumerated() {
            view.frame = NSRect(x: inset + CGFloat(index) * step, y: controlsY, width: size, height: size)
        }
        volumeSlider.frame = NSRect(
            x: inset,
            y: bounds.height - Self.volumeRowHeight,
            width: bounds.width - inset * 2,
            height: 24,
        )
        favicon.frame = tabButton.bounds.insetClamped(dx: 4, dy: 4)
        let titleRowY = (BrowserChromeLayout.sidebarMiniPlayerHeight - size) / 2
        closeButton.frame = NSRect(x: bounds.width - inset - size, y: titleRowY, width: size, height: size)
        pictureInPictureButton.frame = closeButton.frame.offsetBy(dx: -size - 2, dy: 0)
        let titleEnd = item?.isVideo == true ? pictureInPictureButton.frame.minX : closeButton.frame.minX
        titleClip.frame = NSRect(
            x: inset + 4,
            y: titleRowY + (size - 16) / 2,
            width: max(titleEnd - inset - 8, 0),
            height: 16,
        )
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        titleLabel.frame = NSRect(x: 0, y: 0, width: max(titleWidth, titleClip.bounds.width), height: 16)
        updateMarquee()
    }

    /// How far a title longer than its row scrolls to show its end, or 0.
    static func marqueeDistance(titleWidth: CGFloat, rowWidth: CGFloat) -> CGFloat {
        max(ceil(titleWidth - rowWidth), 0)
    }

    func update(_ item: BrowserMiniPlayerItem) {
        guard item != self.item else { return }
        self.item = item
        setAccessibilityIdentifier("browser.mini-player.\(item.tabID)")
        setAccessibilityLabel(item.title)
        titleLabel.stringValue = item.title
        titleLabel.toolTip = item.title
        needsLayout = true
        favicon.update(url: item.faviconURL, pageURLString: item.pageURLString)
        playButton.configureSymbol(
            item.isPlaying ? "pause.fill" : "play.fill",
            title: item.isPlaying ? BrowserStrings.miniPlayerPause : BrowserStrings.miniPlayerPlay,
        )
        muteButton.configureSymbol(
            item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: item.isMuted ? BrowserStrings.tabUnmuteAction : BrowserStrings.tabMuteAction,
        )
        volumeSlider.value = item.volume
        previousButton.isEnabled = item.hasPreviousTrack
        nextButton.isEnabled = item.hasNextTrack
        let call = item.call
        for button in [previousButton, playButton, nextButton] {
            button.isHidden = call != nil
        }
        microphoneButton.isHidden = call == nil
        cameraButton.isHidden = call == nil
        if let call {
            microphoneButton.configureSymbol(
                call.isMicrophoneOn ? "mic.fill" : "mic.slash.fill",
                title: call.isMicrophoneOn
                    ? BrowserStrings.miniPlayerMuteMicrophone
                    : BrowserStrings.miniPlayerUnmuteMicrophone,
            )
            cameraButton.configureSymbol(
                call.isCameraOn ? "video.fill" : "video.slash.fill",
                title: call.isCameraOn ? BrowserStrings.miniPlayerTurnOffCamera : BrowserStrings.miniPlayerTurnOnCamera,
            )
            microphoneButton.isEnabled = call.canToggleMicrophone
            cameraButton.isEnabled = call.canToggleCamera
        }
        needsLayout = true
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        titleClip.isHidden = false
        closeButton.isHidden = false
        pictureInPictureButton.isHidden = item?.isVideo != true
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

    /// While the player is open, a long title scrolls to its end and back,
    /// resting at both ends.
    private func updateMarquee() {
        guard let layer = titleLabel.layer ?? {
            titleLabel.wantsLayer = true
            return titleLabel.layer
        }() else { return }
        let distance = Self.marqueeDistance(
            titleWidth: ceil(titleLabel.intrinsicContentSize.width),
            rowWidth: titleClip.bounds.width,
        )
        let key = "marquee"
        guard isExpanded, distance > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: key)
            marqueeDistance = 0
            return
        }
        guard distance != marqueeDistance || layer.animation(forKey: key) == nil else { return }
        marqueeDistance = distance
        let travel = Double(distance) / 30
        let rest = 1.5
        let total = rest * 2 + travel * 2
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -distance, -distance, 0]
        animation.keyTimes = [0, rest / total, (rest + travel) / total, (rest * 2 + travel) / total, 1]
            .map { NSNumber(value: $0) }
        animation.duration = total
        animation.repeatCount = .infinity
        layer.add(animation, forKey: key)
    }

    /// Holding the speaker opens a level slider under the controls.
    private func setShowsVolume(_ shows: Bool) {
        guard shows != showsVolume else { return }
        showsVolume = shows
        volumeSlider.isHidden = !shows
        needsLayout = true
        onExpansionChange()
    }

    private func applyExpansion(_ value: CGFloat, final: Bool) {
        expansion = value
        titleClip.alphaValue = value
        closeButton.alphaValue = value
        pictureInPictureButton.alphaValue = value
        if final {
            titleClip.isHidden = !isExpanded
            closeButton.isHidden = !isExpanded
            pictureInPictureButton.isHidden = !isExpanded || item?.isVideo != true
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
    var onVolumeChange: (String, Double) -> Void = { _, _ in }
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
        player.onVolumeChange = { [weak self, weak player] volume in
            guard let id = player?.item?.tabID else { return }
            self?.onVolumeChange(id, volume)
        }
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

// MARK: - BrowserMiniPlayerVolumeSlider

/// A thin track with a white knob; the filled part takes the accent color.
private final class BrowserMiniPlayerVolumeSlider: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onChange: (Double) -> Void = { _ in }
    var value = 1.0 { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        let knob: CGFloat = 18
        let track = NSRect(x: 0, y: (bounds.height - 4) / 2, width: bounds.width, height: 4)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let x = (bounds.width - knob) * value
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: track.minY, width: x + knob / 2, height: 4),
            xRadius: 2,
            yRadius: 2,
        ).fill()
        NSColor.white.setFill()
        let oval = NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - knob) / 2, width: knob, height: knob))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        oval.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }

    private func update(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        value = min(max((x - 9) / max(bounds.width - 18, 1), 0), 1)
        onChange(value)
    }
}
