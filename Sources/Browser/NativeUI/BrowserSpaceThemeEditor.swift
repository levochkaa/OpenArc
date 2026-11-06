// BrowserSpaceThemeEditor.swift

import AppKit
import QuartzCore

// MARK: - BrowserSpaceThemeEditorLayout

enum BrowserSpaceThemeEditorLayout {
    static let size = NSSize(width: 356, height: 508)
    static let padOrigin = NSPoint(x: 8, y: 8)
    static let modeButtonSize: CGFloat = 32
    static let modeButtonXs: [CGFloat] = [122, 162, 202]
    static let modeButtonY: CGFloat = 32
    static let editButtonXs: [CGFloat] = [142, 182]
    static let editButtonY: CGFloat = 300
    static let presetArrowXs: [CGFloat] = [8.5, 315.5]
    static let presetY: CGFloat = 364
    static let presetClipX: CGFloat = 40.5
    static let presetClipWidth: CGFloat = 275
    static let presetFirstX: CGFloat = 7.5
    static let presetStride: CGFloat = 29.5
    static let presetSize: CGFloat = 24
    static let sliderFrame = NSRect(x: 18, y: 430, width: 224, height: 44)
    static let dialFrame = NSRect(x: 258, y: 412, width: 80, height: 80)
}

// MARK: - BrowserSpaceThemeEditorViewController

/// The Space's theme editor: a color pad with knobs, preset pages, an intensity
/// slider and a texture dial. Every change applies to the window at once.
final class BrowserSpaceThemeEditorViewController: NSViewController {
    // MARK: Private

    private static let undoLimit = 30

    // MARK: Internal

    /// Called on every change; `commit` is true when a gesture has ended.
    var onChange: (BrowserSpaceTheme, _ commit: Bool) -> Void = { _, _ in }

    private(set) var theme: BrowserSpaceTheme

    private let pad = BrowserSpaceThemePadView()
    private let presetClip = BrowserFlippedView()
    private let presetRow = BrowserFlippedView()
    private let slider = BrowserSpaceThemeSineSlider()
    private let dial = BrowserSpaceThemeDial()
    private var modeButtons = [BrowserSpaceThemeEditorButton]()
    private var addButton: BrowserSpaceThemeEditorButton?
    private var removeButton: BrowserSpaceThemeEditorButton?
    private var previousArrow: BrowserSpaceThemeEditorButton?
    private var nextArrow: BrowserSpaceThemeEditorButton?
    private var presetPage = 0
    private var undoStack = [BrowserSpaceTheme]()
    private var undoMonitor: Any?

    init(theme: BrowserSpaceTheme?) {
        self.theme = theme ?? BrowserSpaceTheme()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let root = BrowserSpaceThemeEditorRootView(frame: NSRect(
            origin: .zero,
            size: BrowserSpaceThemeEditorLayout.size,
        ))
        view = root
        preferredContentSize = BrowserSpaceThemeEditorLayout.size
        pad.frame = NSRect(origin: BrowserSpaceThemeEditorLayout.padOrigin, size: NSSize(
            width: BrowserSpaceTheme.padSize,
            height: BrowserSpaceTheme.padSize,
        ))
        pad.onBeginGesture = { [weak self] in self?.pushUndo() }
        pad.onChange = { [weak self] change, commit in self?.apply(commit: commit, change) }
        root.addSubview(pad)
        for (index, x) in BrowserSpaceThemeEditorLayout.modeButtonXs.enumerated() {
            let mode = BrowserSpaceTheme.Mode.allCases[index]
            let button = BrowserSpaceThemeEditorButton(symbol: mode.symbolName, pointSize: 15)
            button.frame = NSRect(
                x: x,
                y: BrowserSpaceThemeEditorLayout.modeButtonY,
                width: BrowserSpaceThemeEditorLayout.modeButtonSize,
                height: BrowserSpaceThemeEditorLayout.modeButtonSize,
            )
            button.setAccessibilityLabel(mode.title)
            button.onAction = { [weak self] in
                self?.pushUndo()
                self?.apply(commit: true) { $0.mode = mode }
            }
            modeButtons.append(button)
            root.addSubview(button)
        }
        for (index, x) in BrowserSpaceThemeEditorLayout.editButtonXs.enumerated() {
            let isAdd = index == 1
            let button = BrowserSpaceThemeEditorButton(symbol: isAdd ? "plus" : "minus", pointSize: 13)
            button.frame = NSRect(
                x: x,
                y: BrowserSpaceThemeEditorLayout.editButtonY,
                width: BrowserSpaceThemeEditorLayout.modeButtonSize,
                height: BrowserSpaceThemeEditorLayout.modeButtonSize,
            )
            button.setAccessibilityLabel(isAdd
                ? BrowserStrings.spaceThemeAddColor
                : BrowserStrings.spaceThemeRemoveColor)
            button.onAction = { [weak self] in
                self?.pushUndo()
                self?.apply(commit: true) { isAdd ? $0.addColor() : $0.removeColor() }
            }
            if isAdd { addButton = button } else { removeButton = button }
            root.addSubview(button)
        }
        root.addSubview(presetClip)
        presetClip.frame = NSRect(
            x: BrowserSpaceThemeEditorLayout.presetClipX,
            y: BrowserSpaceThemeEditorLayout.presetY,
            width: BrowserSpaceThemeEditorLayout.presetClipWidth,
            height: BrowserSpaceThemeEditorLayout.modeButtonSize,
        )
        presetClip.wantsLayer = true
        presetClip.layer?.masksToBounds = true
        presetClip.addSubview(presetRow)
        layoutPresets()
        for (index, x) in BrowserSpaceThemeEditorLayout.presetArrowXs.enumerated() {
            let isNext = index == 1
            let arrow = BrowserSpaceThemeEditorButton(symbol: isNext ? "chevron.right" : "chevron.left", pointSize: 14)
            arrow.frame = NSRect(
                x: x,
                y: BrowserSpaceThemeEditorLayout.presetY,
                width: BrowserSpaceThemeEditorLayout.modeButtonSize,
                height: BrowserSpaceThemeEditorLayout.modeButtonSize,
            )
            arrow.showsHover = false
            arrow.setAccessibilityLabel(isNext
                ? BrowserStrings.spaceThemeNextPage
                : BrowserStrings.spaceThemePreviousPage)
            arrow.onAction = { [weak self] in self?.showPage((self?.presetPage ?? 0) + (isNext ? 1 : -1)) }
            if isNext { nextArrow = arrow } else { previousArrow = arrow }
            root.addSubview(arrow)
        }
        slider.frame = BrowserSpaceThemeEditorLayout.sliderFrame
        slider.toolTip = BrowserStrings.spaceThemeIntensity
        slider.setAccessibilityLabel(BrowserStrings.spaceThemeIntensity)
        slider.onBeginGesture = { [weak self] in self?.pushUndo() }
        slider.onChange = { [weak self] value, commit in self?.apply(commit: commit) { $0.intensity = value } }
        root.addSubview(slider)
        dial.frame = BrowserSpaceThemeEditorLayout.dialFrame
        dial.toolTip = BrowserStrings.spaceThemeCycleTexture
        dial.setAccessibilityLabel(BrowserStrings.spaceThemeCycleTexture)
        dial.onBeginGesture = { [weak self] in self?.pushUndo() }
        dial.onNoiseChange = { [weak self] value, commit in self?.apply(commit: commit) { $0.noise = value } }
        dial.onCycleTexture = { [weak self] in
            self?.pushUndo()
            self?.apply(commit: true) { theme in
                if theme.noise == 0 {
                    theme.noise = 0.8
                } else {
                    theme.texture = theme.texture.next
                }
            }
        }
        root.addSubview(dial)
        syncControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        undoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === view.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "z"
            else { return event }
            undo()
            return nil
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let undoMonitor { NSEvent.removeMonitor(undoMonitor) }
        undoMonitor = nil
        onChange(theme, true)
    }

    /// Goes back one edit. The stack holds a limited history of this session.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        theme = previous
        syncControls()
        onChange(theme, true)
    }

    private func layoutPresets() {
        let pages = BrowserSpaceThemePresets.pages
        presetRow.frame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(pages.count) * BrowserSpaceThemeEditorLayout.presetClipWidth,
            height: BrowserSpaceThemeEditorLayout.modeButtonSize,
        )
        for (pageIndex, page) in pages.enumerated() {
            for (index, swatch) in page.enumerated() {
                let button = BrowserSpaceThemeSwatchButton(swatch: swatch)
                button.frame = NSRect(
                    x: CGFloat(pageIndex) * BrowserSpaceThemeEditorLayout.presetClipWidth
                        + BrowserSpaceThemeEditorLayout.presetFirstX
                        + CGFloat(index) * BrowserSpaceThemeEditorLayout.presetStride,
                    y: 4,
                    width: BrowserSpaceThemeEditorLayout.presetSize,
                    height: BrowserSpaceThemeEditorLayout.presetSize,
                )
                button.onAction = { [weak self] in self?.choose(swatch) }
                presetRow.addSubview(button)
            }
        }
    }

    private func choose(_ swatch: BrowserSpaceThemePresets.Swatch) {
        pushUndo()
        pad.animatesNextChange = true
        apply(commit: true) { theme in
            var next = swatch.theme
            next.intensity = theme.intensity
            next.noise = theme.noise
            next.texture = theme.texture
            next.mode = theme.mode
            theme = next
        }
    }

    private func showPage(_ page: Int) {
        let clamped = min(max(page, 0), BrowserSpaceThemePresets.pages.count - 1)
        guard clamped != presetPage else { return }
        presetPage = clamped
        let target = -CGFloat(clamped) * BrowserSpaceThemeEditorLayout.presetClipWidth
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            presetRow.animator().setFrameOrigin(NSPoint(x: target, y: 0))
        }
        syncControls()
    }

    private func pushUndo() {
        undoStack.append(theme)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
    }

    private func apply(commit: Bool, _ change: (inout BrowserSpaceTheme) -> Void) {
        change(&theme)
        syncControls()
        onChange(theme, commit)
    }

    private func syncControls() {
        guard isViewLoaded else { return }
        (view as? BrowserSpaceThemeEditorRootView)?.card = theme.palette?.card.nsColor
        pad.theme = theme
        slider.value = theme.intensity
        slider.isControlEnabled = !theme.colors.isEmpty
        dial.noise = theme.noise
        dial.texture = theme.texture
        dial.isControlEnabled = !theme.colors.isEmpty
        for (index, button) in modeButtons.enumerated() {
            button.isSelected = BrowserSpaceTheme.Mode.allCases[index] == theme.mode
        }
        addButton?.isEnabled = theme.canAddColor
        removeButton?.isEnabled = !theme.colors.isEmpty
        previousArrow?.isEnabled = presetPage > 0
        nextArrow?.isEnabled = presetPage < BrowserSpaceThemePresets.pages.count - 1
    }
}

private extension BrowserSpaceTheme.Mode {
    var symbolName: String {
        switch self {
        case .automatic: "sparkles"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var title: String {
        switch self {
        case .automatic: BrowserStrings.spaceThemeModeAutomatic
        case .light: BrowserStrings.spaceThemeModeLight
        case .dark: BrowserStrings.spaceThemeModeDark
        }
    }
}

// MARK: - BrowserFlippedView

private class BrowserFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserSpaceThemeEditorRootView

/// The editor's card, in a dark version of the theme's color. Its controls stay
/// light on it whatever the theme's content appearance.
private final class BrowserSpaceThemeEditorRootView: BrowserFlippedView {
    var card: NSColor? {
        didSet {
            guard card != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        (card ?? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)).setFill()
        bounds.fill()
    }
}

// MARK: - BrowserSpaceThemeEditorButton

/// Glyph buttons of the editor: mode, plus, minus and page arrows.
private final class BrowserSpaceThemeEditorButton: NSView {
    override var isFlipped: Bool { true }

    // MARK: Internal

    var onAction: () -> Void = {}
    var showsHover = true

    var isSelected = false { didSet { updateAppearance() } }
    var isEnabled = true { didSet { updateAppearance() } }

    // MARK: Private

    private let icon = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false

    init(symbol: String, pointSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAppearance()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        layer?.opacity = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = isEnabled ? 1 : 0.33
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAction()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onAction()
        return true
    }

    private func updateAppearance() {
        layer?.opacity = isEnabled ? 1 : 0.33
        let highlighted = isSelected || (showsHover && isHovered && isEnabled)
        layer?.backgroundColor = highlighted ? NSColor.white.withAlphaComponent(0.11).cgColor : nil
    }
}

// MARK: - BrowserSpaceThemeSwatchButton

/// A preset's circle: its colors with a thin dark edge.
private final class BrowserSpaceThemeSwatchButton: NSView {
    // MARK: Internal

    var onAction: () -> Void = {}

    // MARK: Private

    private let swatch: BrowserSpaceThemePresets.Swatch
    private var tracking: NSTrackingArea?

    init(swatch: BrowserSpaceThemePresets.Swatch) {
        self.swatch = swatch
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // Named after its colors, so the swatches differ when heard.
        var names = [String]()
        for name in swatch.colors.map(\.spokenName) where !names.contains(name) {
            names.append(name)
        }
        setAccessibilityLabel(ListFormatter.localizedString(byJoining: names))
        setAccessibilityHelp(BrowserStrings.spaceThemeSetColor)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        let oval = NSBezierPath(ovalIn: bounds)
        let colors = swatch.colors.map(\.nsColor)
        if colors.count > 1, let gradient = NSGradient(colors: colors) {
            gradient.draw(in: oval, angle: -45)
        } else {
            colors.first?.setFill()
            oval.fill()
        }
        NSColor.black.withAlphaComponent(0.1).setStroke()
        let edge = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        edge.lineWidth = 2
        edge.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) { setScale(1.12) }
    override func mouseExited(with _: NSEvent) { setScale(1) }
    override func mouseDown(with _: NSEvent) { setScale(0.94) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setScale(inside ? 1.12 : 1)
        if inside { onAction() }
    }

    override func accessibilityPerformPress() -> Bool {
        onAction()
        return true
    }

    private func setScale(_ scale: CGFloat) {
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.setAffineTransform(
            CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y),
        )
    }
}

// MARK: - BrowserSpaceThemePadView

/// The color pad: angle around the center is hue, distance is lightness.
final class BrowserSpaceThemePadView: NSView {
    // MARK: Private

    /// Key knob 40 pt inside a 5 pt ring, the others 24 pt inside a 3 pt ring.
    private final class Knob {
        let fill = CALayer()
        let ring = CALayer()
    }

    override var isFlipped: Bool { true }

    // MARK: Internal

    var onBeginGesture: () -> Void = {}
    var onChange: ((inout BrowserSpaceTheme) -> Void, Bool) -> Void = { _, _ in }
    var animatesNextChange = false

    var theme = BrowserSpaceTheme() {
        didSet {
            guard theme != oldValue else { return }
            updateKnobs()
            emptyLabel.isHidden = !theme.colors.isEmpty
        }
    }

    private let emptyLabel = NSTextField(labelWithString: BrowserStrings.spaceThemeEmpty)
    private var knobs = [Knob]()
    private var tracking: NSTrackingArea?
    private var dragOffset: CGPoint?
    private var isHovered = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        emptyLabel.alignment = .center
        emptyLabel.isEditable = false
        emptyLabel.isBordered = false
        emptyLabel.drawsBackground = false
        addSubview(emptyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.spaceThemeEmpty)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    override func draw(_: NSRect) {
        NSColor.white.withAlphaComponent(0.045).setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.4).setFill()
        var y: CGFloat = 1
        while y < bounds.height {
            var x: CGFloat = 1.5
            while x < bounds.width {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1, height: 1)).fill()
                x += 5
            }
            y += 5
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(knobIndex(at: convert(event.locationInWindow, from: nil)) != nil)
    }

    override func mouseExited(with _: NSEvent) {
        if dragOffset == nil { setHovered(false) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onBeginGesture()
        // Grabbing a knob keeps its offset; anywhere else, the key color jumps there.
        if knobIndex(at: point) != nil, let key = theme.knobPositions.first {
            dragOffset = CGPoint(x: key.x - point.x, y: key.y - point.y)
        } else {
            dragOffset = .zero
            animatesNextChange = !theme.colors.isEmpty
            move(to: point, commit: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset else { return }
        let point = convert(event.locationInWindow, from: nil)
        move(to: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y), commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOffset else { return }
        let point = convert(event.locationInWindow, from: nil)
        move(to: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y), commit: true)
        self.dragOffset = nil
        setHovered(knobIndex(at: point) != nil)
    }

    private func knobIndex(at point: CGPoint) -> Int? {
        for (index, position) in theme.knobPositions.enumerated() {
            let radius: CGFloat = index == 0 ? 24.5 : 15
            if hypot(position.x - point.x, position.y - point.y) <= radius { return index }
        }
        return nil
    }

    private func move(to point: CGPoint, commit: Bool) {
        let limit = BrowserSpaceTheme.padSize
        let clamped = CGPoint(x: min(max(point.x, 0), limit), y: min(max(point.y, 0), limit))
        onChange({ $0.moveKey(to: clamped) }, commit)
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateKnobs()
    }

    private func updateKnobs() {
        guard let layer else { return }
        let positions = theme.knobPositions
        while knobs.count > positions.count {
            let knob = knobs.removeLast()
            knob.fill.removeFromSuperlayer()
            knob.ring.removeFromSuperlayer()
        }
        while knobs.count < positions.count {
            let knob = Knob()
            knob.ring.backgroundColor = nil
            knob.ring.borderColor = NSColor.white.cgColor
            layer.addSublayer(knob.fill)
            layer.addSublayer(knob.ring)
            knobs.append(knob)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animatesNextChange)
        CATransaction.setAnimationDuration(0.25)
        animatesNextChange = false
        // The key knob on top; the others below it, as on the wheel.
        for (index, knob) in knobs.enumerated().reversed() {
            let isKey = index == 0
            let grow: CGFloat = isHovered && isKey ? 49.0 / 45 : 1
            let inner = (isKey ? 40 : 24) * grow
            let outer = (isKey ? 45 : 27) * grow
            let position = positions[index]
            knob.fill.frame = CGRect(x: position.x - inner / 2, y: position.y - inner / 2, width: inner, height: inner)
            knob.fill.cornerRadius = inner / 2
            knob.fill.backgroundColor = theme.colors[index].nsColor.cgColor
            knob.ring.frame = CGRect(x: position.x - outer / 2, y: position.y - outer / 2, width: outer, height: outer)
            knob.ring.cornerRadius = outer / 2
            knob.ring.borderWidth = (isKey ? 5 : 3) * grow
            layer.insertSublayer(knob.ring, at: UInt32(layer.sublayers?.count ?? 0))
            layer.insertSublayer(knob.fill, below: knob.ring)
        }
        CATransaction.commit()
    }
}

// MARK: - BrowserSpaceThemeSineSlider

/// The intensity slider: a wave that grows with its value and drifts while in use.
final class BrowserSpaceThemeSineSlider: NSView {
    // MARK: Private

    private enum LiveReason { case hover, drag }

    private static let padding: CGFloat = 8
    private static let travel: CGFloat = 208
    private static let period: CGFloat = 37.4
    private static let maximumAmplitude: CGFloat = 15

    override var isFlipped: Bool { true }

    // MARK: Internal

    var onBeginGesture: () -> Void = {}
    var onChange: (Double, Bool) -> Void = { _, _ in }

    var value = 1.0 { didSet { if value != oldValue { needsDisplay = true } } }
    var isControlEnabled = true {
        didSet {
            guard isControlEnabled != oldValue else { return }
            alphaValue = isControlEnabled ? 1 : 0.6
            needsDisplay = true
        }
    }

    private var tracking: NSTrackingArea?
    private var phase: CGFloat = 0
    private var liveReasons = Set<LiveReason>()
    private var timer: Timer?

    /// Grows with the value: 27 x 59 at full intensity.
    private var handleRect: NSRect {
        let width = 11 + 16 * value
        let height = 43 + 16 * value
        return NSRect(
            x: Self.padding + Self.travel * value - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height,
        )
    }

    override func draw(_: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
        NSColor.white.withAlphaComponent(0.075).setFill()
        NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
        let wave = wavePath()
        wave.lineWidth = 5
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.15).setStroke()
        wave.stroke()
        guard isControlEnabled else { return }
        let handleX = Self.padding + Self.travel * value
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: handleX, height: bounds.height).clip()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let handle = handleRect
        NSColor.white.setFill()
        NSBezierPath(roundedRect: handle, xRadius: handle.width / 2, yRadius: handle.width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) { setLive(true, for: .hover) }
    override func mouseExited(with _: NSEvent) { setLive(false, for: .hover) }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else { return }
        onBeginGesture()
        setLive(true, for: .drag)
        onChange(value(at: event), false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isControlEnabled else { return }
        onChange(value(at: event), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isControlEnabled else { return }
        setLive(false, for: .drag)
        onChange(value(at: event), true)
    }

    private func wavePath() -> NSBezierPath {
        let amplitude = isControlEnabled ? Self.maximumAmplitude * (0.15 + 0.85 * value) : Self.maximumAmplitude
        let path = NSBezierPath()
        var x = Self.padding
        let end = bounds.width - Self.padding
        while x <= end {
            let y = bounds.midY - amplitude * sin((x - Self.padding) / Self.period * 2 * .pi + phase)
            x == Self.padding ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            x += 2
        }
        return path
    }

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return min(max((x - Self.padding) / Self.travel, 0), 1)
    }

    private func setLive(_ live: Bool, for reason: LiveReason) {
        if live { liveReasons.insert(reason) } else { liveReasons.remove(reason) }
        let running = !liveReasons.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard running != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard running else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.phase += 0.05
                self?.needsDisplay = true
            }
        }
    }
}

// MARK: - BrowserSpaceThemeDial

/// The texture dial: turning it sets how strong the texture is, a click on its
/// center changes the texture. One full turn is full strength.
final class BrowserSpaceThemeDial: NSView {
    // MARK: Private

    private static let dotCount = 21
    private static let dotRadius = 32.0

    override var isFlipped: Bool { true }

    // MARK: Internal

    var onBeginGesture: () -> Void = {}
    var onNoiseChange: (Double, Bool) -> Void = { _, _ in }
    var onCycleTexture: () -> Void = {}

    var noise = 0.0 { didSet { if noise != oldValue { needsDisplay = true } } }
    var texture = BrowserSpaceTheme.Texture.grain { didSet { if texture != oldValue { needsDisplay = true } } }
    var isControlEnabled = true {
        didSet {
            guard isControlEnabled != oldValue else { return }
            alphaValue = isControlEnabled ? 1 : 0.6
            needsDisplay = true
        }
    }

    private var tracking: NSTrackingArea?
    private var pressedCenter = false
    private var didDrag = false
    private var isCenterHovered = false

    override func draw(_: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for index in 0..<Self.dotCount {
            let turn = Double(index) / Double(Self.dotCount)
            let angle = (turn * 360 - 90) * .pi / 180
            let passed = isControlEnabled && noise > 0 && turn <= noise
            NSColor.white.withAlphaComponent(passed ? 0.6 : 0.15).setFill()
            let dot = NSPoint(x: center.x + Self.dotRadius * cos(angle), y: center.y + Self.dotRadius * sin(angle))
            NSBezierPath(ovalIn: NSRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)).fill()
        }
        let knob = NSRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)
        if isControlEnabled, noise > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: knob).addClip()
            NSColor.white.withAlphaComponent(0.6).setFill()
            knob.fill()
            BrowserSpaceThemeTexture.tile(texture).draw(in: knob, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.white.withAlphaComponent(isCenterHovered ? 0.3 : 0.15).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 1
        ring.stroke()
        guard isControlEnabled else { return }
        let angle = (noise * 360 - 90) * .pi / 180
        let indicator = NSPoint(x: center.x + 32 * cos(angle), y: center.y + 32 * sin(angle))
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: indicator.x, y: indicator.y)
        context?.rotate(by: CGFloat(noise * 2 * .pi))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: -4, y: -8, width: 8, height: 16), xRadius: 4, yRadius: 4).fill()
        context?.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { setCenterHovered(isInCenter(event)) }
    override func mouseExited(with _: NSEvent) { setCenterHovered(false) }

    override func scrollWheel(with event: NSEvent) {
        guard isControlEnabled else { return }
        let delta = (event.scrollingDeltaY + event.scrollingDeltaX) / 600
        onNoiseChange(min(max(noise + delta, 0), 1), event.phase == .ended || event.momentumPhase == .ended)
    }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else { return }
        pressedCenter = isInCenter(event)
        didDrag = false
        if !pressedCenter { onBeginGesture() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isControlEnabled else { return }
        if pressedCenter, !didDrag { onBeginGesture() }
        didDrag = true
        onNoiseChange(noise(at: event), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isControlEnabled else { return }
        if pressedCenter, !didDrag, isInCenter(event) {
            onCycleTexture()
        } else {
            onNoiseChange(noise(at: event), true)
        }
    }

    private func isInCenter(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= 20
    }

    private func setCenterHovered(_ hovered: Bool) {
        guard hovered != isCenterHovered else { return }
        isCenterHovered = hovered
        needsDisplay = true
    }

    private func noise(at event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        let angle = atan2(point.y - bounds.midY, point.x - bounds.midX) * 180 / .pi + 90
        let turn = (angle + 360).truncatingRemainder(dividingBy: 360) / 360
        // Near the top, stay on the side the dial is already on, not the far end.
        if noise > 0.75, turn < 0.25 { return 1 }
        if noise < 0.25, turn > 0.75 { return 0 }
        return turn
    }
}
