// BrowserBoostEditor.swift

import AppKit
import Combine

// MARK: - BrowserBoostEditorLayout

enum BrowserBoostEditorLayout {
    static let width: CGFloat = 184
    static let inset: CGFloat = 18
    static let contentWidth = width - inset * 2
    static let headerHeight: CGFloat = 40
    static let gap: CGFloat = 16
    static let rowHeight: CGFloat = 36
    static let toolGap: CGFloat = 10
    static let pairGap: CGFloat = 8
    static let panelCornerRadius: CGFloat = 12
    static let buttonCornerRadius: CGFloat = 8
    static let wheelCornerRadius: CGFloat = 16
    static let wheelRingWidth: CGFloat = 6
    static let primaryPuckDiameter: CGFloat = 28
    static let secondaryPuckDiameter: CGFloat = 20
    static let fontGridHeight: CGFloat = 121
    static let fontGridCornerRadius: CGFloat = 10
    static let sliderRowHeight: CGFloat = 36
    static let zappedRowHeight: CGFloat = 22
    static let zappedVisibleRows = 5
    /// The panel's middle sits on the window's trailing edge, halfway down.
    static let screenInset: CGFloat = 8
    static let codeSize = NSSize(width: 380, height: 440)
    static let codeGap: CGFloat = 8
}

// MARK: - BrowserBoostEditorColors

@MainActor enum BrowserBoostEditorColors {
    static let panel = dynamic(light: NSColor(srgbRed: 0.992, green: 0.988, blue: 1, alpha: 1), dark: NSColor(
        srgbRed: 0.157,
        green: 0.153,
        blue: 0.169,
        alpha: 1,
    ))
    static let button = dynamic(
        light: NSColor(srgbRed: 0.922, green: 0.918, blue: 0.929, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.09),
    )
    static let buttonHover = dynamic(
        light: NSColor(srgbRed: 0.882, green: 0.878, blue: 0.894, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.14),
    )
    static let card = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.06))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    static let active = NSColor(srgbRed: 0.259, green: 0.325, blue: 0.843, alpha: 1)
    static let label = dynamic(
        light: NSColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1),
        dark: NSColor(white: 0.92, alpha: 1),
    )
    static let secondaryLabel = dynamic(light: NSColor(white: 0, alpha: 0.42), dark: NSColor(white: 1, alpha: 0.5))
    static let tertiaryLabel = dynamic(light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.4))
    static let dot = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - BrowserBoostEditorViewController

/// A site's Boost: a name, colors from a wheel, lightness, contrast and
/// brightness, a font, the text's size and case, zapped elements and its own
/// code. Every change applies to the site's open pages at once.
final class BrowserBoostEditorViewController: NSViewController {
    // MARK: Internal

    static let width = BrowserBoostEditorLayout.width

    let host: String
    /// Closes the editor's panels.
    var onClose: () -> Void = {}
    /// Zapping started: the page takes the keyboard and the pointer.
    var onStartZapping: () -> Void = {}
    /// The editor's height changed.
    var onResize: (NSSize) -> Void = { _ in }
    /// Code opens or closes the CSS and JavaScript editor.
    var onToggleCode: () -> Void = {}
    /// Whether the CSS and JavaScript editor is open.
    var isCodeOpen = false {
        didSet { codeButton.isActive = isCodeOpen }
    }

    /// Changes this editor can take back, newest last.
    private(set) var undoStack = [BrowserBoost?]()
    private(set) var showsAdvancedColors = false

    // MARK: Private

    private let model: BrowserChromeModel
    private let root = BrowserBoostEditorRootView()
    private let closeButton = BrowserBoostEditorButton(symbol: "xmark", style: .round)
    private let titleButton = BrowserBoostEditorButton(title: "", symbol: "chevron.down", style: .plain)
    private let undoButton = BrowserBoostEditorButton(symbol: "arrow.counterclockwise", style: .plain)
    private let headerDivider = BrowserNativeSurface()
    private let wheel = BrowserBoostColorWheelView()
    private let invertButton = BrowserBoostEditorButton(symbol: "lightbulb", style: .filled)
    private let advancedButton = BrowserBoostEditorButton(symbol: "slider.horizontal.3", style: .filled)
    private let resetColorsButton = BrowserBoostEditorButton(symbol: "nosign", style: .filled)
    private let contrastSlider = BrowserBoostEditorSlider(
        title: BrowserStrings.boostEditorContrast,
        range: BrowserBoostColors.contrastRange,
    )
    private let brightnessSlider = BrowserBoostEditorSlider(
        title: BrowserStrings.boostEditorBrightness,
        range: BrowserBoostColors.brightnessRange,
    )
    private let saturationSlider = BrowserBoostEditorSlider(
        title: BrowserStrings.boostEditorOriginalSaturation,
        range: 0...1,
    )
    private let fontGrid = BrowserBoostFontGridView()
    private let sizeButton = BrowserBoostEditorButton(title: BrowserStrings.boostEditorSize, style: .filled)
    private let caseButton = BrowserBoostEditorButton(title: BrowserStrings.boostEditorCase, style: .filled)
    private let zapButton = BrowserBoostEditorButton(
        title: BrowserStrings.boostEditorZap,
        symbol: "bolt.fill",
        style: .filled,
        alignment: .leading,
    )
    private let zapHint = BrowserNativeControls.label(
        BrowserStrings.boostEditorZapHint,
        size: 11,
        color: BrowserBoostEditorColors.secondaryLabel,
        wraps: true,
    )
    private let zappedScroll = NSScrollView()
    private let zappedDocument = BrowserBoostFlippedView()
    private let codeButton = BrowserBoostEditorButton(
        title: BrowserStrings.boostEditorCode,
        symbol: "curlybraces",
        style: .filled,
        alignment: .leading,
    )

    private var observations = Set<AnyCancellable>()
    private var shownZappedSelectors: [String]?
    /// A drag of the wheel or a slider records one undo step at its start.
    private var isContinuousChange = false

    init(model: BrowserChromeModel, host: String) {
        self.model = model
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = root
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(BrowserStrings.boostEditorTitle)
        root.setAccessibilityIdentifier("browser.boost-editor")
        root.frame = NSRect(x: 0, y: 0, width: Self.width, height: 1)

        configure(closeButton, "close", BrowserStrings.boostEditorClose) { [weak self] in self?.onClose() }
        configure(titleButton, "title", BrowserStrings.boostEditorRename) { [weak self] in self?.showTitleMenu() }
        configure(undoButton, "undo", BrowserStrings.boostEditorUndo) { [weak self] in self?.undo() }
        headerDivider.fillColor = BrowserBoostEditorColors.border
        headerDivider.strokeWidth = 0
        root.addSubview(headerDivider)

        wheel.setAccessibilityLabel(BrowserStrings.boostEditorColors)
        wheel.setAccessibilityIdentifier("browser.boost-editor.colors")
        wheel.onBegin = { [weak self] in self?.beginContinuousChange() }
        wheel.onChange = { [weak self] tint in
            self?.change { boost in
                var colors = boost.colors ?? BrowserBoostColors()
                colors.tint = tint
                boost.colors = colors
            }
        }
        wheel.onEnd = { [weak self] in self?.endContinuousChange() }
        root.addSubview(wheel)

        configure(invertButton, "invert", BrowserStrings.boostEditorInvert) { [weak self] in
            self?.change { boost in
                var colors = boost.colors ?? BrowserBoostColors()
                colors.invertsLightness.toggle()
                boost.colors = colors
            }
        }
        configure(advancedButton, "advanced", BrowserStrings.boostEditorAdvanced) { [weak self] in
            self?.toggleAdvancedColors()
        }
        configure(resetColorsButton, "reset-colors", BrowserStrings.boostEditorResetColors) { [weak self] in
            self?.change { $0.colors = nil }
        }
        for (slider, identifier) in [
            (contrastSlider, "contrast"),
            (brightnessSlider, "brightness"),
            (saturationSlider, "original-saturation"),
        ] {
            slider.slider.setAccessibilityIdentifier("browser.boost-editor.\(identifier)")
            slider.onBegin = { [weak self] in self?.beginContinuousChange() }
            slider.onEnd = { [weak self] in self?.endContinuousChange() }
            slider.isHidden = true
            root.addSubview(slider)
        }
        contrastSlider.onChange = { [weak self] value in self?.changeColors { $0.contrast = value } }
        brightnessSlider.onChange = { [weak self] value in self?.changeColors { $0.brightness = value } }
        saturationSlider.onChange = { [weak self] value in self?.changeColors { $0.originalSaturation = value } }

        fontGrid.setAccessibilityLabel(BrowserStrings.boostEditorFonts)
        fontGrid.setAccessibilityIdentifier("browser.boost-editor.fonts")
        fontGrid.onSelect = { [weak self] family in self?.change { $0.fontFamily = family } }
        root.addSubview(fontGrid)

        configure(sizeButton, "size", BrowserStrings.boostEditorSizeHelp) { [weak self] in self?.showSizeMenu() }
        configure(caseButton, "case", BrowserStrings.boostEditorCaseHelp) { [weak self] in self?.showCaseMenu() }
        configure(zapButton, "zap", BrowserStrings.boostEditorZap) { [weak self] in self?.toggleZapping() }
        root.addSubview(zapHint)
        zappedScroll.drawsBackground = false
        zappedScroll.hasVerticalScroller = true
        zappedScroll.autohidesScrollers = true
        zappedScroll.scrollerStyle = .overlay
        zappedScroll.documentView = zappedDocument
        root.addSubview(zappedScroll)
        configure(codeButton, "code", BrowserStrings.boostEditorCode) { [weak self] in self?.onToggleCode() }

        model.userPreferencesStore
            .objectWillChange
            .merge(with: model.objectWillChange)
            .sink { [weak self] _ in
                // Sent before the change; read the new state after it.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &observations)
        refresh()
    }

    // MARK: Private

    private static func percent(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private static func caseTitle(_ textCase: BrowserBoostTextCase) -> String {
        switch textCase {
        case .capitalize: "Aa"
        case .uppercase: "AA"
        case .lowercase: "aa"
        }
    }

    private static func caseMenuTitle(_ textCase: BrowserBoostTextCase?) -> String {
        switch textCase {
        case nil: BrowserStrings.boostEditorCaseOriginal
        case .capitalize: BrowserStrings.boostEditorCaseCapitalize
        case .uppercase: BrowserStrings.boostEditorCaseUppercase
        case .lowercase: BrowserStrings.boostEditorCaseLowercase
        }
    }

    /// The current state on screen, and the editor closed once its page is gone.
    func refresh() {
        guard isViewLoaded else { return }
        guard model.currentPageKeepsBoostEditor(host: host) else {
            onClose()
            return
        }
        let boost = model.boost(forHost: host)
        titleButton.title = boost.displayTitle(defaultTitle: BrowserStrings.boostDefaultTitle)
        undoButton.isInteractionEnabled = !undoStack.isEmpty
        undoButton.alphaValue = undoStack.isEmpty ? 0.4 : 1
        let colors = boost.colors ?? BrowserBoostColors()
        if !wheel.isDragging {
            wheel.tint = colors.tint
        }
        invertButton.isActive = colors.invertsLightness
        invertButton.symbol = colors.invertsLightness ? "lightbulb.fill" : "lightbulb"
        advancedButton.isActive = showsAdvancedColors
        resetColorsButton.isInteractionEnabled = boost.colors != nil
        contrastSlider.value = colors.contrast
        brightnessSlider.value = colors.brightness
        saturationSlider.value = colors.originalSaturation
        saturationSlider.isEnabled = colors.tint != nil
        fontGrid.selectedFamily = boost.fontFamily
        sizeButton.title = boost.zoom == 1 ? BrowserStrings.boostEditorSize : Self.percent(boost.zoom)
        sizeButton.isActive = boost.zoom != 1
        caseButton.title = boost.textCase.map(Self.caseTitle) ?? BrowserStrings.boostEditorCase
        caseButton.isActive = boost.textCase != nil
        let zapping = model.boostZapSession?.host == host
        zapButton.isActive = zapping
        zapButton.isInteractionEnabled = zapping || model.currentBoostHost == host
        zapHint.isHidden = !zapping
        codeButton.isActive = isCodeOpen
        if boost.zappedSelectors != shownZappedSelectors {
            shownZappedSelectors = boost.zappedSelectors
            rebuildZappedRows(boost.zappedSelectors)
        }
        layoutContent()
    }

    /// Takes back the last change.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        restore(previous)
    }

    /// Shows or hides the contrast, brightness and saturation sliders.
    func toggleAdvancedColors() {
        showsAdvancedColors.toggle()
        for slider in [contrastSlider, brightnessSlider, saturationSlider] {
            slider.isHidden = !showsAdvancedColors
        }
        refresh()
    }

    private func configure(
        _ button: BrowserBoostEditorButton,
        _ identifier: String,
        _ title: String,
        action: @escaping () -> Void,
    ) {
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("browser.boost-editor.\(identifier)")
        button.toolTip = title
        button.onClick = { _ in action() }
        root.addSubview(button)
    }

    /// Lays the controls out top to bottom and sizes the editor to them.
    private func layoutContent() {
        let layout = BrowserBoostEditorLayout.self
        let inset = layout.inset
        let width = layout.contentWidth
        let header = layout.headerHeight
        closeButton.frame = NSRect(x: 11, y: (header - 16) / 2, width: 16, height: 16)
        undoButton.frame = NSRect(x: layout.width - 11 - 22, y: (header - 22) / 2, width: 22, height: 22)
        let titleWidth = min(ceil(titleButton.fittingWidth), layout.width - 2 * 40)
        titleButton.frame = NSRect(
            x: (layout.width - titleWidth) / 2,
            y: (header - 24) / 2,
            width: titleWidth,
            height: 24,
        )
        headerDivider.frame = NSRect(x: 0, y: header - 1, width: layout.width, height: 1)
        var y = header + layout.gap

        wheel.frame = NSRect(x: inset, y: y, width: width, height: width)
        y += width + layout.gap

        let toolWidth = (width - layout.toolGap * 2) / 3
        for (index, button) in [invertButton, advancedButton, resetColorsButton].enumerated() {
            button.frame = NSRect(
                x: inset + CGFloat(index) * (toolWidth + layout.toolGap),
                y: y,
                width: toolWidth,
                height: layout.rowHeight,
            )
        }
        y += layout.rowHeight + layout.gap

        if showsAdvancedColors {
            for slider in [contrastSlider, brightnessSlider, saturationSlider] {
                slider.frame = NSRect(x: inset, y: y, width: width, height: layout.sliderRowHeight)
                y += layout.sliderRowHeight
            }
            y += layout.gap - 4
        }

        fontGrid.frame = NSRect(x: inset, y: y, width: width, height: layout.fontGridHeight)
        y += layout.fontGridHeight + layout.gap

        let pairWidth = (width - layout.pairGap) / 2
        sizeButton.frame = NSRect(x: inset, y: y, width: pairWidth, height: layout.rowHeight)
        caseButton.frame = NSRect(
            x: inset + pairWidth + layout.pairGap,
            y: y,
            width: pairWidth,
            height: layout.rowHeight,
        )
        y += layout.rowHeight + layout.gap

        zapButton.frame = NSRect(x: inset, y: y, width: width, height: layout.rowHeight)
        y += layout.rowHeight
        if !zapHint.isHidden {
            zapHint.preferredMaxLayoutWidth = width
            let height = ceil(zapHint.fittingSize.height)
            zapHint.frame = NSRect(x: inset, y: y + 6, width: width, height: height)
            y += 6 + height
        }
        let zapped = shownZappedSelectors?.count ?? 0
        zappedScroll.isHidden = zapped == 0
        if zapped > 0 {
            let visible = CGFloat(min(zapped, layout.zappedVisibleRows))
            let listHeight = visible * layout.zappedRowHeight
            zappedScroll.frame = NSRect(x: inset, y: y + 6, width: width, height: listHeight)
            zappedDocument.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: CGFloat(zapped) * layout.zappedRowHeight,
            )
            for (index, row) in zappedDocument.subviews.enumerated() {
                row.frame = NSRect(
                    x: 0,
                    y: CGFloat(index) * layout.zappedRowHeight,
                    width: width,
                    height: layout.zappedRowHeight,
                )
            }
            y += 6 + listHeight
        }
        y += layout.gap

        codeButton.frame = NSRect(x: inset, y: y, width: width, height: layout.rowHeight)
        y += layout.rowHeight + inset

        let size = NSSize(width: layout.width, height: y)
        guard size != preferredContentSize || root.frame.size != size else { return }
        root.setFrameSize(size)
        preferredContentSize = size
        onResize(size)
    }

    // MARK: Changes

    /// One change of the Boost, which it keeps on, as an undo step of its own
    /// unless a drag already recorded one.
    private func change(_ edit: (inout BrowserBoost) -> Void) {
        if !isContinuousChange {
            recordUndo()
        }
        model.updateBoost(host: host) { boost in
            edit(&boost)
            boost.isEnabled = true
        }
    }

    private func changeColors(_ edit: (inout BrowserBoostColors) -> Void) {
        change { boost in
            var colors = boost.colors ?? BrowserBoostColors()
            edit(&colors)
            boost.colors = colors
        }
    }

    private func beginContinuousChange() {
        recordUndo()
        isContinuousChange = true
    }

    private func endContinuousChange() {
        isContinuousChange = false
        refresh()
    }

    private func recordUndo() {
        undoStack.append(model.userPreferencesStore.boosts.boost(forHost: host))
    }

    private func restore(_ boost: BrowserBoost?) {
        if let boost {
            model.updateBoost(host: host) { $0 = boost }
        } else {
            model.userPreferencesStore.boosts.removeBoost(host: host)
        }
        refresh()
    }

    // MARK: Menus

    private func showTitleMenu() {
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.boostEditorRename, to: menu) { [weak self] in self?.rename() }
        BrowserNativeMenus.add(
            BrowserStrings.boostEditorResetAll,
            to: menu,
            enabled: model.userPreferencesStore.boosts.boost(forHost: host)?.hasContent == true,
        ) { [weak self] in
            guard let self else { return }
            if model.boostZapSession?.host == host {
                model.stopZapping()
            }
            change { boost in
                boost = BrowserBoost(host: boost.host, title: boost.title)
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.boostEditorDeleteMenu, to: menu) { [weak self] in self?.delete() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: titleButton.bounds.maxY + 4), in: titleButton)
    }

    private func showSizeMenu() {
        let menu = BrowserNativeMenus.menu()
        let current = model.boost(forHost: host).zoom
        for level in BrowserBoostTextZoom.levels {
            let item = BrowserNativeMenus.add(Self.percent(level), to: menu) { [weak self] in
                self?.change { $0.textZoom = level == 1 ? nil : level }
            }
            item.state = level == current ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sizeButton.bounds.maxY + 4), in: sizeButton)
    }

    private func showCaseMenu() {
        let menu = BrowserNativeMenus.menu()
        let current = model.boost(forHost: host).textCase
        for textCase in [nil] + BrowserBoostTextCase.allCases.map(Optional.some) {
            let item = BrowserNativeMenus.add(Self.caseMenuTitle(textCase), to: menu) { [weak self] in
                self?.change { $0.textCase = textCase }
            }
            item.state = textCase == current ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: caseButton.bounds.maxY + 4), in: caseButton)
    }

    private func rename() {
        BrowserBoostDialogs
            .rename(title: model.boost(forHost: host).title ?? "", in: view.window) { [weak self] title in
                guard let self else { return }
                recordUndo()
                model.renameBoost(host: host, title: title)
            }
    }

    private func delete() {
        BrowserBoostDialogs.confirmDelete(in: view.window) { [weak self] in
            guard let self else { return }
            model.removeBoost(host: host)
            onClose()
        }
    }

    // MARK: Zapping

    private func toggleZapping() {
        if model.boostZapSession?.host == host {
            model.stopZapping()
            return
        }
        model.startZapping(host: host)
        onStartZapping()
    }

    private func rebuildZappedRows(_ selectors: [String]) {
        zappedDocument.subviews.forEach { $0.removeFromSuperview() }
        for selector in selectors {
            zappedDocument.addSubview(zappedRow(selector))
        }
    }

    private func zappedRow(_ selector: String) -> NSView {
        let row = BrowserBoostZappedRow(selector: selector)
        row.onRestore = { [weak self] in
            guard let self else { return }
            change { boost in boost.zappedSelectors.removeAll { $0 == selector } }
        }
        return row
    }
}

// MARK: - BrowserBoostEditorRootView

private final class BrowserBoostEditorRootView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - BrowserBoostFlippedView

final class BrowserBoostFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserBoostEditorButton

/// The editor's buttons: a rounded gray key with a title, a symbol or both,
/// filled with the accent while its state is on.
final class BrowserBoostEditorButton: BrowserNativePressableView {
    enum Style {
        /// A gray key.
        case filled
        /// A small gray circle.
        case round
        /// No fill until hovered.
        case plain
    }

    enum Alignment {
        case center
        /// The title at the start and the symbol at the end.
        case leading
    }

    // MARK: Internal

    var title: String {
        didSet {
            titleLabel.stringValue = title
            needsLayout = true
        }
    }

    var symbol: String? {
        didSet { updateSymbol() }
    }

    var isActive = false {
        didSet { if isActive != oldValue { interactionChanged() } }
    }

    // MARK: Private

    private let style: Style
    private let alignment: Alignment
    private let titleLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    /// The width the title and symbol need, for buttons that hug them.
    var fittingWidth: CGFloat {
        let titleWidth = title.isEmpty ? 0 : ceil(titleLabel.intrinsicContentSize.width) + 4
        let symbolWidth: CGFloat = symbol == nil ? 0 : 12
        return titleWidth + symbolWidth + (titleWidth > 0 && symbolWidth > 0 ? 5 : 0) + 16
    }

    init(title: String = "", symbol: String? = nil, style: Style, alignment: Alignment = .center) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.alignment = alignment
        super.init(frame: .zero)
        strokeWidth = 0
        cornerRadius = style == .round ? 8 : BrowserBoostEditorLayout.buttonCornerRadius
        pressedScale = 0.97
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: style == .plain ? 13 : 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
        icon.imageScaling = .scaleNone
        addSubview(titleLabel)
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateSymbol()
        interactionChanged()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func interactionChanged() {
        super.interactionChanged()
        let enabled = isInteractionEnabled
        fillColor =
            switch style {
            case .filled:
                isActive
                    ? BrowserBoostEditorColors.active
                    : isHovered && enabled ? BrowserBoostEditorColors.buttonHover : BrowserBoostEditorColors.button
            case .round:
                isHovered && enabled ? BrowserBoostEditorColors.buttonHover : BrowserBoostEditorColors.button
            case .plain:
                isHovered && enabled ? BrowserBoostEditorColors.button : .clear
            }
        let content = isActive ? NSColor.white : BrowserBoostEditorColors.label
        titleLabel.textColor = content
        // Symbols alone are gray; beside a title they take its color.
        icon.contentTintColor = isActive
            ? content
            : title.isEmpty || style == .round
                ? BrowserBoostEditorColors.secondaryLabel
                : content
        alphaValue = enabled ? 1 : 0.45
        setAccessibilityValue(isActive ? NSNumber(value: 1) : nil)
    }

    override func layout() {
        super.layout()
        let symbolSize = icon.image?.size ?? .zero
        // Labels draw a little past their measured width.
        var titleSize = titleLabel.intrinsicContentSize
        titleSize.width = ceil(titleSize.width) + 4
        let titleY = (bounds.height - titleSize.height) / 2
        switch (alignment, title.isEmpty) {
        case (_, true):
            icon.frame = NSRect(
                x: (bounds.width - symbolSize.width) / 2,
                y: (bounds.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height,
            )
        case (.leading, false):
            titleLabel.frame = NSRect(x: 14, y: titleY, width: bounds.width - 40, height: titleSize.height)
            icon.frame = NSRect(
                x: bounds.width - 14 - symbolSize.width,
                y: (bounds.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height,
            )
        case (.center, false):
            let gap: CGFloat = symbol == nil ? 0 : 4
            let total = min(titleSize.width + gap + symbolSize.width, bounds.width - 8)
            let titleWidth = total - gap - symbolSize.width
            let x = (bounds.width - total) / 2
            titleLabel.frame = NSRect(x: x, y: titleY, width: titleWidth, height: titleSize.height)
            icon.frame = NSRect(
                x: x + titleWidth + gap,
                y: (bounds.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height,
            )
        }
    }

    private func updateSymbol() {
        let size: CGFloat =
            switch style {
            case .round: 7
            case .plain: title.isEmpty ? 13 : 9
            case .filled: 14
            }
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: size, weight: style == .round ? .bold : .medium))
        needsLayout = true
    }
}

// MARK: - BrowserBoostColorWheelView

/// A rounded square framed by a hue ring. The light color's puck sits at its
/// hue's angle, as far out as its saturation; the dark color's puck follows
/// at an offset and can be dragged around on its own.
final class BrowserBoostColorWheelView: NSView {
    // MARK: Private

    private enum Drag {
        case primary
        case secondary
    }

    /// Where the light puck rests before a tint is picked.
    static let restingTint = BrowserBoostColors.Tint(hue: 20, saturation: 0.55)

    // MARK: Internal

    override var isFlipped: Bool { true }

    var tint: BrowserBoostColors.Tint? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    var onBegin: () -> Void = {}
    var onChange: (BrowserBoostColors.Tint) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private(set) var isDragging = false

    private var drag: Drag?

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// How far a puck's middle may go from the center: the inner square's edge.
    private var reach: CGFloat {
        bounds.width / 2 - BrowserBoostEditorLayout.wheelRingWidth - BrowserBoostEditorLayout.primaryPuckDiameter / 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = BrowserBoostEditorLayout.self
        let outer = bounds
        let ring = layout.wheelRingWidth
        let outerPath = CGPath(
            roundedRect: outer,
            cornerWidth: layout.wheelCornerRadius,
            cornerHeight: layout.wheelCornerRadius,
            transform: nil,
        )
        let innerRect = outer.insetBy(dx: ring, dy: ring)
        let innerRadius = layout.wheelCornerRadius - ring
        let innerPath = CGPath(
            roundedRect: innerRect,
            cornerWidth: innerRadius,
            cornerHeight: innerRadius,
            transform: nil,
        )

        // The ring: every hue around it once a tint is picked, gray before.
        context.saveGState()
        context.addPath(outerPath)
        context.addPath(innerPath)
        context.clip(using: .evenOdd)
        if tint != nil {
            // Thin wedges from the center, one hue each, clockwise from the right.
            let radius = hypot(outer.width, outer.height)
            let step = 3.0
            for hue in stride(from: 0.0, to: 360.0, by: step) {
                let rgb = BrowserBoostColors.rgb(hue: hue + step / 2, saturation: 0.95, lightness: 0.55)
                context.setFillColor(CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
                let start = CGFloat(hue) * .pi / 180
                let end = CGFloat(hue + step + 0.5) * .pi / 180
                context.move(to: center)
                context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                context.closePath()
                context.fillPath()
            }
        } else {
            context.setFillColor(BrowserBoostEditorColors.button.cgColor)
            context.fill(outer)
        }
        context.restoreGState()

        // The inside: the card's color with a faint dot grid.
        context.saveGState()
        context.addPath(innerPath)
        context.clip()
        context.setFillColor(BrowserBoostEditorColors.card.cgColor)
        context.fill(innerRect)
        if let tint {
            // A faint glow of the light color around its puck.
            let glow = BrowserBoostColors.rgb(hue: tint.hue, saturation: tint.saturation, lightness: 0.9)
            let colors = [
                CGColor(srgbRed: glow.red, green: glow.green, blue: glow.blue, alpha: 0.7),
                CGColor(srgbRed: glow.red, green: glow.green, blue: glow.blue, alpha: 0),
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors as CFArray,
                locations: [0, 1],
            ) {
                let point = puckCenter(hue: tint.hue, saturation: tint.saturation)
                context.drawRadialGradient(
                    gradient,
                    startCenter: point,
                    startRadius: 0,
                    endCenter: point,
                    endRadius: innerRect.width * 0.8,
                    options: [],
                )
            }
        }
        context.setFillColor(BrowserBoostEditorColors.dot.cgColor)
        var y = innerRect.minY + 4
        while y < innerRect.maxY {
            var x = innerRect.minX + 4
            while x < innerRect.maxX {
                context.fillEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += 7
            }
            y += 7
        }
        context.restoreGState()

        // The pucks, the dark one under the light one.
        let shown = tint ?? Self.restingTint
        let secondary = puckCenter(hue: shown.secondaryHue, saturation: shown.saturation)
        let primary = puckCenter(hue: shown.hue, saturation: shown.saturation)
        let darkColor: CGColor
        let lightColor: CGColor
        if let tint {
            let dark = BrowserBoostColors.rgb(hue: tint.secondaryHue, saturation: tint.saturation, lightness: 0.18)
            let light = BrowserBoostColors.rgb(hue: tint.hue, saturation: tint.saturation, lightness: 0.7)
            darkColor = CGColor(srgbRed: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
            lightColor = CGColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: 1)
        } else {
            darkColor = CGColor(gray: 0.45, alpha: 1)
            lightColor = CGColor(gray: 0.78, alpha: 1)
        }
        drawPuck(in: context, at: secondary, diameter: layout.secondaryPuckDiameter, color: darkColor)
        drawPuck(in: context, at: primary, diameter: layout.primaryPuckDiameter, color: lightColor)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let current = tint ?? Self.restingTint
        let secondary = puckCenter(hue: current.secondaryHue, saturation: current.saturation)
        let primary = puckCenter(hue: current.hue, saturation: current.saturation)
        let onSecondary = tint != nil
            && hypot(point.x - secondary.x, point.y - secondary.y) <= BrowserBoostEditorLayout
            .secondaryPuckDiameter / 2 + 3
            && hypot(point.x - primary.x, point.y - primary.y) > BrowserBoostEditorLayout.primaryPuckDiameter / 2
        drag = onSecondary ? .secondary : .primary
        isDragging = true
        onBegin()
        move(to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        drag = nil
        isDragging = false
        onEnd()
    }

    func puckCenter(hue: Double, saturation: Double) -> CGPoint {
        let angle = hue * .pi / 180
        let distance = CGFloat(saturation) * reach
        return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }

    /// The tint a point of the wheel picks, keeping the dark color's offset.
    func tint(at point: CGPoint, secondaryHueOffset: Double) -> BrowserBoostColors.Tint {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let hue = atan2(dy, dx) * 180 / .pi
        let saturation = min(sqrt(dx * dx + dy * dy) / Double(max(reach, 1)), 1)
        return BrowserBoostColors.Tint(hue: hue, saturation: saturation, secondaryHueOffset: secondaryHueOffset)
    }

    private func move(to point: CGPoint) {
        let current = tint ?? Self.restingTint
        let next: BrowserBoostColors.Tint
        switch drag {
        case .secondary:
            let angle = atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
            var offset = BrowserBoostColors.normalizedHue(angle - current.hue)
            if offset > 180 { offset -= 360 }
            next = BrowserBoostColors.Tint(
                hue: current.hue,
                saturation: current.saturation,
                secondaryHueOffset: offset,
            )
        case nil, .primary:
            next = tint(at: point, secondaryHueOffset: current.secondaryHueOffset)
        }
        tint = next
        onChange(next)
    }

    private func drawPuck(in context: CGContext, at point: CGPoint, diameter: CGFloat, color: CGColor) {
        let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.25))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: rect)
        context.restoreGState()
        context.setFillColor(color)
        context.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
    }
}

// MARK: - BrowserBoostEditorSlider

/// A slider with its name above it.
final class BrowserBoostEditorSlider: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    let slider = NSSlider()
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }
    var onEnd: () -> Void = {}

    // MARK: Private

    private let label: NSTextField
    private var isTracking = false

    var value: Double {
        get { slider.doubleValue }
        set { if !isTracking { slider.doubleValue = newValue } }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            label.alphaValue = newValue ? 1 : 0.45
        }
    }

    init(title: String, range: ClosedRange<Double>) {
        self.label = BrowserNativeControls.label(
            title,
            size: 11,
            weight: .medium,
            color: BrowserBoostEditorColors.secondaryLabel,
        )
        super.init(frame: .zero)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(title)
        addSubview(label)
        addSubview(slider)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 14)
        slider.frame = NSRect(x: 0, y: 15, width: bounds.width, height: 18)
    }

    @objc private func changed() {
        let event = NSApp.currentEvent
        let phaseEnded = event?.type == .leftMouseUp
        if !isTracking, !phaseEnded {
            isTracking = true
            onBegin()
        }
        onChange(slider.doubleValue)
        if phaseEnded || event == nil || event?.type == .keyDown, isTracking {
            isTracking = false
            onEnd()
        }
    }
}

// MARK: - BrowserBoostFontGridView

/// A white card of five fonts to a row, each shown as "Aa"; a click picks
/// one, a click on the picked one goes back to the site's fonts.
final class BrowserBoostFontGridView: BrowserNativeSurface {
    // MARK: Internal

    var onSelect: (String?) -> Void = { _ in }

    var selectedFamily: String? {
        didSet {
            guard selectedFamily != oldValue else { return }
            for cell in cells {
                cell.isSelected = cell.family == selectedFamily
            }
        }
    }

    // MARK: Private

    private var cells = [BrowserBoostFontCell]()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fillColor = BrowserBoostEditorColors.card
        strokeColor = BrowserBoostEditorColors.border
        strokeWidth = 1
        cornerRadius = BrowserBoostEditorLayout.fontGridCornerRadius
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        for option in BrowserBoostFont.options {
            let cell = BrowserBoostFontCell(family: option.family)
            cell.onClick = { [weak self, weak cell] _ in
                guard let self, let cell else { return }
                onSelect(cell.isSelected ? nil : cell.family)
            }
            cells.append(cell)
            addSubview(cell)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let columns = BrowserBoostFont.columns
        let rows = (cells.count + columns - 1) / columns
        let padding: CGFloat = 4
        let cellWidth = (bounds.width - padding * 2) / CGFloat(columns)
        let cellHeight = (bounds.height - padding * 2) / CGFloat(rows)
        for (index, cell) in cells.enumerated() {
            cell.frame = NSRect(
                x: padding + CGFloat(index % columns) * cellWidth,
                y: padding + CGFloat(index / columns) * cellHeight,
                width: cellWidth,
                height: cellHeight,
            ).insetBy(dx: 1, dy: 1)
        }
    }
}

// MARK: - BrowserBoostFontCell

private final class BrowserBoostFontCell: BrowserNativePressableView {
    // MARK: Internal

    let family: String

    var isSelected = false {
        didSet { if isSelected != oldValue { interactionChanged() } }
    }

    // MARK: Private

    private let sample = NSTextField(labelWithString: "Aa")

    init(family: String) {
        self.family = family
        super.init(frame: .zero)
        strokeWidth = 0
        cornerRadius = 6
        pressedScale = 0.94
        sample.font = NSFont(name: family, size: 13) ?? NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: 13,
        ) ?? .systemFont(ofSize: 13)
        sample.alignment = .center
        sample.setAccessibilityElement(false)
        addSubview(sample)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(family)
        setAccessibilityIdentifier("browser.boost-editor.font.\(family)")
        toolTip = family
        interactionChanged()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = isSelected
            ? BrowserBoostEditorColors.active
            : isHovered ? BrowserBoostEditorColors.button : .clear
        sample.textColor = isSelected
            ? .white
            : isHovered ? BrowserBoostEditorColors.label : BrowserBoostEditorColors.tertiaryLabel
        setAccessibilityValue(isSelected ? NSNumber(value: 1) : NSNumber(value: 0))
    }

    override func layout() {
        super.layout()
        let height = ceil(sample.intrinsicContentSize.height)
        sample.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

// MARK: - BrowserBoostZappedRow

/// A zapped element: its selector and a button that brings it back.
private final class BrowserBoostZappedRow: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onRestore: () -> Void = {}

    // MARK: Private

    private let label = NSTextField(labelWithString: "")
    private let restore = BrowserBoostEditorButton(symbol: "arrow.uturn.backward", style: .plain)

    init(selector: String) {
        super.init(frame: .zero)
        label.stringValue = selector
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = BrowserBoostEditorColors.secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = selector
        restore.setAccessibilityLabel(BrowserStrings.boostEditorRemoveHiddenElement)
        restore.setAccessibilityIdentifier("browser.boost-editor.remove-hidden-element")
        restore.toolTip = BrowserStrings.boostEditorRemoveHiddenElement
        restore.onClick = { [weak self] _ in self?.onRestore() }
        addSubview(label)
        addSubview(restore)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        restore.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        label.frame = NSRect(x: 2, y: (bounds.height - 14) / 2, width: bounds.width - 26, height: 14)
    }
}

// MARK: - BrowserBoostCodeViewController

/// A Boost's own CSS and JavaScript, one tab each. CSS applies as it is
/// typed; JavaScript is saved when its field loses focus, the tab changes or
/// the editor closes, and reloads the site's pages.
final class BrowserBoostCodeViewController: NSViewController, NSTextViewDelegate {
    // MARK: Private

    private static let cssCommitDelay: TimeInterval = 0.3

    // MARK: Internal

    let host: String
    var onClose: () -> Void = {}

    private let model: BrowserChromeModel
    private let tabs = NSSegmentedControl(
        labels: [BrowserStrings.boostEditorCSS, BrowserStrings.boostEditorJavaScript],
        trackingMode: .selectOne,
        target: nil,
        action: nil,
    )
    private let closeButton = BrowserBoostEditorButton(symbol: "xmark", style: .round)
    private let cssView = BrowserBoostCodeViewController.makeCodeView()
    private let javaScriptView = BrowserBoostCodeViewController.makeCodeView()
    private let detail = BrowserNativeControls.label(
        "",
        size: 11,
        color: BrowserBoostEditorColors.secondaryLabel,
        wraps: true,
    )
    private var pendingCSSCommit: DispatchWorkItem?

    init(model: BrowserChromeModel, host: String) {
        self.model = model
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = BrowserBoostFlippedView(frame: NSRect(origin: .zero, size: BrowserBoostEditorLayout.codeSize))
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(BrowserStrings.boostEditorCode)
        root.setAccessibilityIdentifier("browser.boost-editor.code-panel")
        view = root
        let boost = model.boost(forHost: host)
        tabs.selectedSegment = 0
        tabs.segmentStyle = .automatic
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.setAccessibilityIdentifier("browser.boost-editor.code-tabs")
        closeButton.setAccessibilityLabel(BrowserStrings.boostEditorClose)
        closeButton.toolTip = BrowserStrings.boostEditorClose
        closeButton.onClick = { [weak self] _ in self?.onClose() }
        cssView.textView.string = boost.css
        cssView.textView.delegate = self
        cssView.textView.setAccessibilityLabel(BrowserStrings.boostEditorCSS)
        cssView.textView.setAccessibilityIdentifier("browser.boost-editor.css")
        javaScriptView.textView.string = boost.javaScript
        javaScriptView.textView.delegate = self
        javaScriptView.textView.setAccessibilityLabel(BrowserStrings.boostEditorJavaScript)
        javaScriptView.textView.setAccessibilityIdentifier("browser.boost-editor.javascript")
        for subview in [tabs, closeButton, cssView.scrollView, javaScriptView.scrollView, detail] as [NSView] {
            root.addSubview(subview)
        }
        let size = BrowserBoostEditorLayout.codeSize
        closeButton.frame = NSRect(x: 12, y: 13, width: 16, height: 16)
        tabs.sizeToFit()
        tabs.frame = NSRect(
            x: (size.width - tabs.frame.width) / 2,
            y: 9,
            width: tabs.frame.width,
            height: tabs.frame.height,
        )
        let editorFrame = NSRect(x: 12, y: 42, width: size.width - 24, height: size.height - 42 - 48)
        cssView.scrollView.frame = editorFrame
        javaScriptView.scrollView.frame = editorFrame
        detail.preferredMaxLayoutWidth = size.width - 24
        detail.frame = NSRect(x: 12, y: editorFrame.maxY + 8, width: size.width - 24, height: 32)
        preferredContentSize = size
        showTab()
    }

    // MARK: Private

    private static func makeCodeView() -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = BrowserBoostEditorLayout.buttonCornerRadius
        scrollView.layer?.masksToBounds = true
        let textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = BrowserBoostEditorColors.card
        textView.textContainerInset = NSSize(width: 6, height: 8)
        return (scrollView, textView)
    }

    /// Saves typed CSS and JavaScript that are not saved yet.
    func commitPendingEdits() {
        guard isViewLoaded else { return }
        commitCSS()
        commitJavaScript()
    }

    func focusEditor() {
        let textView = tabs.selectedSegment == 0 ? cssView.textView : javaScriptView.textView
        view.window?.makeFirstResponder(textView)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === cssView.textView else { return }
        pendingCSSCommit?.cancel()
        let commit = DispatchWorkItem { [weak self] in self?.commitCSS() }
        pendingCSSCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cssCommitDelay, execute: commit)
    }

    func textDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextView === javaScriptView.textView {
            commitJavaScript()
        } else {
            commitCSS()
        }
    }

    @objc private func switchTab() {
        commitPendingEdits()
        showTab()
        focusEditor()
    }

    private func showTab() {
        let showsCSS = tabs.selectedSegment == 0
        cssView.scrollView.isHidden = !showsCSS
        javaScriptView.scrollView.isHidden = showsCSS
        detail.stringValue = showsCSS
            ? BrowserStrings.boostEditorCSSDetail
            : BrowserStrings.boostEditorJavaScriptDetail
    }

    private func commitCSS() {
        pendingCSSCommit?.cancel()
        pendingCSSCommit = nil
        let css = cssView.textView.string
        guard css != model.boost(forHost: host).css else { return }
        model.updateBoost(host: host) { boost in
            boost.css = css
            boost.isEnabled = true
        }
    }

    private func commitJavaScript() {
        let javaScript = javaScriptView.textView.string
        guard javaScript != model.boost(forHost: host).javaScript else { return }
        model.updateBoost(host: host) { boost in
            boost.javaScript = javaScript
            boost.isEnabled = true
        }
    }
}

// MARK: - BrowserBoostDialogs

/// Renaming and deleting a Boost, as sheets on its window.
@MainActor enum BrowserBoostDialogs {
    static func rename(title: String, in window: NSWindow?, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.boostRenameTitle
        alert.addButton(withTitle: BrowserStrings.boostRenameDone)
        alert.addButton(withTitle: BrowserStrings.boostCancel)
        let field = NSTextField(string: title)
        field.placeholderString = BrowserStrings.boostDefaultTitle
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        field.setAccessibilityIdentifier("browser.boost.rename-field")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                done(field.stringValue)
            }
        }
        if let window = window?.sheetParent ?? window?.parent ?? window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    static func confirmDelete(in window: NSWindow?, delete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.boostDeleteTitle
        alert.informativeText = BrowserStrings.boostDeleteDetail
        let confirm = alert.addButton(withTitle: BrowserStrings.boostDeleteConfirm)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: BrowserStrings.boostCancel)
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                delete()
            }
        }
        if let window = window?.sheetParent ?? window?.parent ?? window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

// MARK: - BrowserBoostPanel

/// A borderless rounded panel that floats over its browser window and moves
/// with it. It takes the keyboard only for text fields, so the page keeps it
/// while zapping.
final class BrowserBoostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Internal

    var onEscape: () -> Bool = { false }

    // MARK: Private

    private let container = BrowserBoostPanelContainer()

    init(content: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        container.frame = NSRect(origin: .zero, size: content.frame.size)
        container.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
    }

    override func cancelOperation(_ sender: Any?) {
        if !onEscape() {
            super.cancelOperation(sender)
        }
    }
}

// MARK: - BrowserBoostPanelContainer

private final class BrowserBoostPanelContainer: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = BrowserBoostEditorLayout.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateColors()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BrowserBoostEditorColors.panel.cgColor
            layer?.borderColor = BrowserBoostEditorColors.border.cgColor
        }
    }
}

// MARK: - BrowserBoostEditorPanelController

/// The editor's panel, centered on the window's trailing edge halfway down,
/// and the code panel beside it. Both float over the window and move with it.
@MainActor final class BrowserBoostEditorPanelController {
    // MARK: Internal

    let editor: BrowserBoostEditorViewController
    /// The panels closed.
    var onClose: () -> Void = {}
    private(set) var code: BrowserBoostCodeViewController?

    // MARK: Private

    private let model: BrowserChromeModel
    private let panel: BrowserBoostPanel
    private var codePanel: BrowserBoostPanel?
    private weak var parentWindow: NSWindow?
    private var observers = [NSObjectProtocol]()
    private var isClosed = false

    var host: String { editor.host }

    init(model: BrowserChromeModel, host: String, parent: NSWindow) {
        self.model = model
        self.editor = BrowserBoostEditorViewController(model: model, host: host)
        self.parentWindow = parent
        self.panel = BrowserBoostPanel(content: editor.view)
        panel.appearance = parent.appearance
        editor.onClose = { [weak self] in self?.close() }
        editor.onResize = { [weak self] size in self?.resize(to: size) }
        editor.onToggleCode = { [weak self] in self?.toggleCode() }
        panel.onEscape = { [weak self] in self?.escape() ?? false }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func show() {
        guard let parentWindow, !isClosed else { return }
        panel.setContentSize(editor.preferredContentSize)
        position()
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    /// Escape ends zapping first, then closes the editor.
    func escape() -> Bool {
        if model.boostZapSession?.host == host {
            model.stopZapping()
        } else {
            close()
        }
        return true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        code?.commitPendingEdits()
        if model.boostZapSession?.host == host {
            model.stopZapping()
        }
        for window in [codePanel, panel].compactMap(\.self) {
            parentWindow?.removeChildWindow(window)
            window.orderOut(nil)
            window.close()
        }
        codePanel = nil
        onClose()
    }

    func toggleCode() {
        if let codePanel {
            code?.commitPendingEdits()
            parentWindow?.removeChildWindow(codePanel)
            codePanel.orderOut(nil)
            codePanel.close()
            self.codePanel = nil
            code = nil
            editor.isCodeOpen = false
            return
        }
        let controller = BrowserBoostCodeViewController(model: model, host: host)
        controller.onClose = { [weak self] in self?.toggleCode() }
        let codePanel = BrowserBoostPanel(content: controller.view)
        codePanel.appearance = panel.appearance
        codePanel.becomesKeyOnlyIfNeeded = false
        codePanel.onEscape = { [weak self] in
            self?.toggleCode()
            return true
        }
        code = controller
        self.codePanel = codePanel
        editor.isCodeOpen = true
        position()
        parentWindow?.addChildWindow(codePanel, ordered: .above)
        codePanel.makeKeyAndOrderFront(nil)
        controller.focusEditor()
    }

    private func resize(to size: NSSize) {
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        // The top stays put while the editor grows or shrinks.
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(clamped(frame), display: true)
        positionCode()
    }

    private func position() {
        guard let parentWindow else { return }
        let size = editor.preferredContentSize
        let window = parentWindow.frame
        let frame = NSRect(
            x: window.maxX - size.width / 2,
            y: window.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        panel.setFrame(clamped(frame), display: true)
        positionCode()
    }

    private func positionCode() {
        guard let codePanel else { return }
        let size = BrowserBoostEditorLayout.codeSize
        let frame = NSRect(
            x: panel.frame.minX - BrowserBoostEditorLayout.codeGap - size.width,
            y: panel.frame.maxY - size.height,
            width: size.width,
            height: size.height,
        )
        codePanel.setFrame(clamped(frame), display: true)
    }

    /// Kept inside the screen's visible part.
    private func clamped(_ frame: NSRect) -> NSRect {
        guard let screen = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame else { return frame }
        let area = screen.insetBy(dx: BrowserBoostEditorLayout.screenInset, dy: BrowserBoostEditorLayout.screenInset)
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }
}
