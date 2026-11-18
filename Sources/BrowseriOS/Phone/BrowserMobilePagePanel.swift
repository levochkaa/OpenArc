// BrowserMobilePagePanel.swift

import UIKit

// MARK: - BrowserMobilePagePanel

/// The page menu that grows out of the bar: address row with navigation,
/// tiles for page actions, Display Options that open in place, and Site
/// Settings. The address row starts as the bar's New Tab capsule and widens
/// once the panel is up.
final class BrowserMobilePagePanel: UIView {
    // MARK: Internal

    struct Tile {
        let title: String
        let symbol: String
        let identifier: String
        let isEnabled: Bool
        let action: () -> Void
    }

    /// What Display Options show for the current page; nil for a page they
    /// do not apply to.
    struct DisplayOptions {
        let zoomPercent: Int
        let canZoomOut: Bool
        let canZoomIn: Bool
        let prefersDesktop: Bool
    }

    static let margin: CGFloat = 16
    static let topInset: CGFloat = 16
    static let rowHeight: CGFloat = 48
    static let tileSide: CGFloat = 80
    /// Rows inside the open Display Options group.
    static let optionHeight: CGFloat = 49
    static let groupSpacing: CGFloat = 16

    private static let expandedKey = "BrowserMobilePagePanel.displayOptionsExpanded"

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onAddress: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReload: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onToggleDesktop: (() -> Void)?
    var onSiteSettings: (() -> Void)?
    /// Display Options opened or closed; the owner resizes the panel to
    /// `contentHeight` inside the animation it is given.
    var onContentHeightChange: ((_ animations: @escaping () -> Void) -> Void)?

    // MARK: Private

    /// Whether the address row is full width, or still the New Tab capsule.
    private(set) var isAddressExpanded = true
    private(set) var isDisplayExpanded = UserDefaults.standard.bool(forKey: BrowserMobilePagePanel.expandedKey)

    private let addressRow = UIView()
    private let addressContent = UIView()
    private let plusGlyph = UIImageView(image: UIImage(
        systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
    ))
    /// Everything under the address row.
    private let body = UIView()
    private var backButton = UIButton()
    private var forwardButton = UIButton()
    private let hostButton = UIButton(type: .system)
    private var copyButton = UIButton()
    private var reloadButton = UIButton()
    private var tiles = [UIButton]()
    private var tileLabels = [UILabel]()

    private let displayGroup = UIView()
    private let displayHeader = BrowserMobilePagePanelRow()
    private let displayChevron = UIImageView()
    private let zoomRow = BrowserMobilePagePanelRow()
    private let zoomStepper = UIView()
    private let zoomOutButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)
    private let desktopRow = BrowserMobilePagePanelRow()
    private let optionSeparators = [UIView(), UIView()]
    private let siteSettingsRow = BrowserMobilePagePanelRow()

    /// Height of the panel's content above the home indicator.
    var contentHeight: CGFloat {
        siteSettingsTop + Self.rowHeight
    }

    private var tileTop: CGFloat { Self.topInset + Self.rowHeight + 16 }
    private var displayTop: CGFloat { tileTop + Self.tileSide + 38 }
    private var displayHeight: CGFloat {
        Self.rowHeight + (isDisplayExpanded ? Self.optionHeight * 2 : 0)
    }

    private var siteSettingsTop: CGFloat { displayTop + displayHeight + Self.groupSpacing }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.pageMenuPanel"
        addressRow.layer.cornerRadius = Self.rowHeight / 2
        addressRow.layer.cornerCurve = .continuous
        addressRow.layer.borderWidth = 1 / 3
        addressRow.clipsToBounds = true
        addSubview(body)
        addSubview(addressRow)
        addressRow.addSubview(addressContent)
        plusGlyph.contentMode = .center
        plusGlyph.alpha = 0
        addressRow.addSubview(plusGlyph)
        self.backButton = rowButton("chevron.left", "Back", "browser.back") { [weak self] in self?.onBack?() }
        self.forwardButton = rowButton("chevron.right", "Forward", "browser.forward") { [weak self] in
            self?.onForward?()
        }
        self.copyButton = rowButton("link", "Copy Link", "browser.copyLink") { [weak self] in self?.onCopy?() }
        self.reloadButton = rowButton("arrow.clockwise", "Reload", "browser.reload") { [weak self] in
            self?.onReload?()
        }
        hostButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        hostButton.titleLabel?.lineBreakMode = .byTruncatingHead
        hostButton.accessibilityIdentifier = "browser.address"
        hostButton.addAction(UIAction { [weak self] _ in self?.onAddress?() }, for: .touchUpInside)
        for view in [backButton, forwardButton, hostButton, copyButton, reloadButton] {
            addressContent.addSubview(view)
        }
        configureDisplayOptions()
        siteSettingsRow.configure(
            title: String(localized: "Site Settings", table: "Mobile"), symbol: "gearshape",
            identifier: "browser.siteSettings",
        )
        siteSettingsRow.layer.cornerRadius = 16
        siteSettingsRow.layer.cornerCurve = .continuous
        siteSettingsRow.layer.borderWidth = 1 / 3
        siteSettingsRow.addAction(UIAction { [weak self] _ in self?.onSiteSettings?() }, for: .touchUpInside)
        body.addSubview(siteSettingsRow)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - Self.margin * 2
        body.frame = bounds
        let capsule = CGRect(
            x: (bounds.width - BrowserMobilePhoneBarView.plusWidth) / 2, y: BrowserMobilePhoneBarView.controlTopInset,
            width: BrowserMobilePhoneBarView.plusWidth, height: BrowserMobilePhoneBarView.controlHeight,
        )
        let row = isAddressExpanded
            ? CGRect(x: Self.margin, y: Self.topInset, width: width, height: Self.rowHeight)
            : capsule
        addressRow.frame = row
        addressRow.layer.cornerRadius = row.height / 2
        // The row's controls keep their full-width places, centered in the
        // capsule while it widens; the capsule clips them.
        addressContent.frame = CGRect(
            x: (row.width - width) / 2, y: (row.height - Self.rowHeight) / 2, width: width, height: Self.rowHeight,
        )
        plusGlyph.frame = CGRect(x: (row.width - 40) / 2, y: (row.height - 40) / 2, width: 40, height: 40)
        let side: CGFloat = 40
        let midY = Self.rowHeight / 2
        backButton.frame = CGRect(x: 6, y: midY - side / 2, width: side, height: side)
        forwardButton.frame = CGRect(x: 45, y: midY - side / 2, width: side, height: side)
        reloadButton.frame = CGRect(x: width - 6 - side, y: midY - side / 2, width: side, height: side)
        copyButton.frame = CGRect(x: width - 45 - side, y: midY - side / 2, width: side, height: side)
        let hostInset: CGFloat = 88
        hostButton.frame = CGRect(x: hostInset, y: 0, width: width - hostInset * 2, height: Self.rowHeight)
        let count = CGFloat(max(tiles.count, 1))
        let spacing = (width - Self.tileSide * count) / max(count - 1, 1)
        for (index, (tile, label)) in zip(tiles, tileLabels).enumerated() {
            let x = Self.margin + CGFloat(index) * (Self.tileSide + spacing)
            tile.frame = CGRect(x: x, y: tileTop, width: Self.tileSide, height: Self.tileSide)
            label.frame = CGRect(x: x - 8, y: tileTop + Self.tileSide + 6, width: Self.tileSide + 16, height: 18)
        }
        displayGroup.frame = CGRect(x: Self.margin, y: displayTop, width: width, height: displayHeight)
        displayHeader.frame = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
        displayChevron.frame = CGRect(x: width - 16 - 18, y: 0, width: 18, height: Self.rowHeight)
        displayChevron.transform = isDisplayExpanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        zoomRow.frame = CGRect(x: 0, y: Self.rowHeight, width: width, height: Self.optionHeight)
        desktopRow.frame = CGRect(x: 0, y: Self.rowHeight + Self.optionHeight, width: width, height: Self.optionHeight)
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for (index, separator) in optionSeparators.enumerated() {
            separator.frame = CGRect(
                x: 52, y: Self.rowHeight + Self.optionHeight * CGFloat(index), width: width - 52, height: hairline,
            )
        }
        zoomStepper.frame = CGRect(x: width - 10 - 88, y: (Self.optionHeight - 32) / 2, width: 88, height: 32)
        zoomOutButton.frame = CGRect(x: 0, y: 0, width: 44, height: 32)
        zoomInButton.frame = CGRect(x: 44, y: 0, width: 44, height: 32)
        siteSettingsRow.frame = CGRect(x: Self.margin, y: siteSettingsTop, width: width, height: Self.rowHeight)
    }

    func update(
        host: String, canGoBack: Bool, canGoForward: Bool, isLoading: Bool, canCopy: Bool, canReload: Bool,
        tiles newTiles: [Tile], display: DisplayOptions?, hasSiteSettings: Bool,
    ) {
        let fill = BrowserMobileBackdrop.buttonFill
        let border = BrowserMobileBackdrop.buttonBorder.resolvedColor(with: traitCollection).cgColor
        let glyph = BrowserMobileBackdrop.glyph
        hostButton.setTitle(
            host.isEmpty ? String(localized: "Search or enter address", table: "Mobile") : host,
            for: .normal,
        )
        hostButton.setTitleColor(host.isEmpty ? .secondaryLabel : glyph, for: .normal)
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        copyButton.isEnabled = canCopy
        reloadButton.isEnabled = canReload
        reloadButton.setImage(symbol(isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = isLoading
            ? String(localized: "Stop Loading", table: "Mobile")
            : String(localized: "Reload", table: "Mobile")
        addressRow.backgroundColor = fill
        addressRow.layer.borderColor = border
        for button in [backButton, forwardButton, copyButton, reloadButton] {
            button.tintColor = glyph
        }
        plusGlyph.tintColor = glyph
        if newTiles.count != tiles.count {
            tiles.forEach { $0.removeFromSuperview() }
            tileLabels.forEach { $0.removeFromSuperview() }
            tiles = newTiles.map { _ in UIButton(type: .custom) }
            tileLabels = newTiles.map { _ in UILabel() }
            tiles.forEach(body.addSubview)
            tileLabels.forEach(body.addSubview)
            setNeedsLayout()
        }
        for (index, tile) in newTiles.enumerated() {
            let button = tiles[index]
            button.accessibilityIdentifier = tile.identifier
            button.accessibilityLabel = tile.title
            button.setImage(
                UIImage(systemName: tile.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)),
                for: .normal,
            )
            button.tintColor = glyph
            button.backgroundColor = fill
            button.layer.cornerRadius = 16
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = 1 / 3
            button.layer.borderColor = border
            button.isEnabled = tile.isEnabled
            button.alpha = tile.isEnabled ? 1 : 0.45
            button.removeTarget(nil, action: nil, for: .allEvents)
            button.addAction(UIAction { _ in tile.action() }, for: .touchUpInside)
            let label = tileLabels[index]
            label.text = tile.title
            label.font = .systemFont(ofSize: 12)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            label.textColor = glyph.withAlphaComponent(0.7)
            label.alpha = button.alpha
        }
        for view in [displayGroup, siteSettingsRow] {
            view.backgroundColor = fill
            view.layer.borderColor = border
        }
        for row in [displayHeader, zoomRow, desktopRow, siteSettingsRow] {
            row.tintColor = glyph
        }
        displayChevron.tintColor = glyph.withAlphaComponent(0.7)
        for separator in optionSeparators {
            separator.backgroundColor = glyph.withAlphaComponent(0.15)
        }
        zoomStepper.backgroundColor = fill
        zoomOutButton.tintColor = glyph
        zoomInButton.tintColor = glyph
        displayGroup.alpha = display == nil ? 0.45 : 1
        displayGroup.isUserInteractionEnabled = display != nil
        if let display {
            zoomOutButton.isEnabled = display.canZoomOut
            zoomInButton.isEnabled = display.canZoomIn
            zoomOutButton.accessibilityValue = "\(display.zoomPercent)%"
            zoomInButton.accessibilityValue = "\(display.zoomPercent)%"
            desktopRow.configure(
                title: display.prefersDesktop
                    ? String(localized: "Request Mobile Site", table: "Mobile")
                    : String(localized: "Request Desktop Site", table: "Mobile"),
                symbol: display.prefersDesktop ? "iphone" : "laptopcomputer", identifier: "browser.desktopSite",
            )
        }
        siteSettingsRow.isEnabled = hasSiteSettings
        siteSettingsRow.alpha = hasSiteSettings ? 1 : 0.45
    }

    /// Lays the address row out full width, or as the New Tab capsule with
    /// the rest of the menu hidden; call it inside an animation to morph.
    func setAddressExpanded(_ expanded: Bool) {
        isAddressExpanded = expanded
        setNeedsLayout()
        layoutIfNeeded()
        let apply = {
            self.plusGlyph.alpha = expanded ? 0 : 1
            self.addressContent.alpha = expanded ? 1 : 0
            self.body.alpha = expanded ? 1 : 0
        }
        guard UIView.inheritedAnimationDuration > 0 else {
            apply()
            return
        }
        // The plus fades as the capsule starts to widen and the controls come
        // in after it; closing, the controls go first.
        UIView.animate(withDuration: expanded ? 0.12 : 0.2, delay: expanded ? 0 : 0.08, options: [
            .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve,
        ]) {
            self.plusGlyph.alpha = expanded ? 0 : 1
        }
        UIView.animate(withDuration: expanded ? 0.22 : 0.1, delay: expanded ? 0.06 : 0, options: [
            .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve,
        ]) {
            self.addressContent.alpha = expanded ? 1 : 0
            self.body.alpha = expanded ? 1 : 0
        }
    }

    private func configureDisplayOptions() {
        displayGroup.layer.cornerRadius = 16
        displayGroup.layer.cornerCurve = .continuous
        displayGroup.layer.borderWidth = 1 / 3
        displayGroup.clipsToBounds = true
        body.addSubview(displayGroup)
        displayHeader.configure(
            title: String(localized: "Display Options", table: "Mobile"), symbol: "doc.richtext",
            identifier: "browser.displayOptions",
        )
        displayHeader.addAction(UIAction { [weak self] _ in self?.toggleDisplayOptions() }, for: .touchUpInside)
        displayChevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold),
        )
        displayChevron.contentMode = .center
        displayHeader.addSubview(displayChevron)
        zoomRow.configure(
            title: String(localized: "Page Zoom", table: "Mobile"), symbol: "textformat.size",
            identifier: "browser.pageZoom",
        )
        // Its two buttons speak for themselves.
        zoomRow.isAccessibilityElement = false
        zoomStepper.layer.cornerRadius = 9
        zoomStepper.layer.cornerCurve = .continuous
        for (button, symbolName, title, id, action) in [
            (
                zoomOutButton,
                "minus",
                String(localized: "Smaller Text", table: "Mobile"),
                "browser.zoomOut",
                { [weak self] in self?.onZoomOut?() },
            ),
            (
                zoomInButton,
                "plus",
                String(localized: "Larger Text", table: "Mobile"),
                "browser.zoomIn",
                { [weak self] in self?.onZoomIn?() },
            ),
        ] as [(UIButton, String, String, String, () -> Void)] {
            button.setImage(
                UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 15, weight: .semibold,
                )),
                for: .normal,
            )
            button.accessibilityLabel = title
            button.accessibilityIdentifier = id
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            zoomStepper.addSubview(button)
        }
        let divider = UIView(frame: CGRect(x: 43.5, y: 8, width: 1, height: 16))
        divider.backgroundColor = UIColor.separator
        zoomStepper.addSubview(divider)
        zoomRow.addSubview(zoomStepper)
        desktopRow.addAction(UIAction { [weak self] _ in self?.onToggleDesktop?() }, for: .touchUpInside)
        for view in [zoomRow, desktopRow] as [UIView] + optionSeparators {
            displayGroup.addSubview(view)
        }
        displayGroup.addSubview(displayHeader)
        setOptionsVisible(isDisplayExpanded)
    }

    /// Opens or closes Display Options in place; the choice is kept for the
    /// next time the menu opens.
    private func toggleDisplayOptions() {
        isDisplayExpanded.toggle()
        UserDefaults.standard.set(isDisplayExpanded, forKey: Self.expandedKey)
        let expanded = isDisplayExpanded
        let resize = { [weak self] in
            guard let self else { return }
            setNeedsLayout()
            layoutIfNeeded()
        }
        UIView.animate(withDuration: expanded ? 0.2 : 0.12, delay: expanded ? 0.05 : 0, options: [
            .beginFromCurrentState,
        ]) {
            self.setOptionsVisible(expanded)
        }
        if let onContentHeightChange {
            onContentHeightChange(resize)
        } else {
            resize()
        }
    }

    private func setOptionsVisible(_ visible: Bool) {
        for view in [zoomRow, desktopRow] as [UIView] + optionSeparators {
            view.alpha = visible ? 1 : 0
        }
        zoomRow.isUserInteractionEnabled = visible
        desktopRow.isUserInteractionEnabled = visible
    }

    private func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
    }

    private func rowButton(_ symbolName: String, _ title: String, _ id: String, action: @escaping () -> Void)
        -> UIButton
    {
        let button = UIButton(type: .system)
        button.setImage(symbol(symbolName), for: .normal)
        button.accessibilityLabel = NSLocalizedString(title, tableName: "Mobile", comment: "Page menu action")
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

// MARK: - BrowserMobilePagePanelRow

/// A full-width row of the page menu: an icon and a title, leading.
final class BrowserMobilePagePanelRow: UIControl {
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.2) {
                self.backgroundColorOverlay.alpha = self.isHighlighted ? 1 : 0
            }
        }
    }

    private let icon = UIImageView()
    private let label = UILabel()

    private let backgroundColorOverlay = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColorOverlay.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.08)
            : UIColor(white: 0, alpha: 0.06)
        }
        backgroundColorOverlay.alpha = 0
        backgroundColorOverlay.isUserInteractionEnabled = false
        addSubview(backgroundColorOverlay)
        icon.contentMode = .center
        label.font = .systemFont(ofSize: 17)
        addSubview(icon)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColorOverlay.frame = bounds
        icon.frame = CGRect(x: 14, y: 0, width: 30, height: bounds.height)
        label.frame = CGRect(x: 52, y: 0, width: bounds.width - 52 - 110, height: bounds.height)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        label.textColor = tintColor
    }

    func configure(title: String, symbol: String, identifier: String) {
        label.text = title
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
        accessibilityLabel = title
        accessibilityIdentifier = identifier
    }
}
