// BrowserMobilePagePanel.swift

import UIKit

/// The page menu that grows out of the bar: address row with navigation,
/// tiles for page actions, then the page's display options. The address row
/// starts as the bar's New Tab capsule and widens once the panel is up.
final class BrowserMobilePagePanel: UIView {
    // MARK: Internal

    struct Tile {
        let title: String
        let symbol: String
        let identifier: String
        let isEnabled: Bool
        let action: () -> Void
    }

    static let margin: CGFloat = 16
    static let topInset: CGFloat = 17
    static let rowHeight: CGFloat = 46
    static let tileSide: CGFloat = 80

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onAddress: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReload: (() -> Void)?

    // MARK: Private

    /// Whether the address row is full width, or still the New Tab capsule.
    private(set) var isAddressExpanded = true

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
    private let displayButton = UIButton(type: .system)
    private let displayChevron = UIImageView()

    /// Height of the panel's content above the home indicator.
    var contentHeight: CGFloat {
        displayTop + Self.rowHeight + 14
    }

    private var tileTop: CGFloat { Self.topInset + Self.rowHeight + 16 }
    private var displayTop: CGFloat { tileTop + Self.tileSide + 39 }

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
        self
            .reloadButton = rowButton("arrow.clockwise", "Reload", "browser.reload") { [weak self] in
                self?.onReload?()
            }
        hostButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        hostButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        hostButton.accessibilityIdentifier = "browser.address"
        hostButton.addAction(UIAction { [weak self] _ in self?.onAddress?() }, for: .touchUpInside)
        for view in [backButton, forwardButton, hostButton, copyButton, reloadButton] {
            addressContent.addSubview(view)
        }
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Display Options", table: "Mobile")
        configuration.image = UIImage(
            systemName: "textformat.size",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17),
        )
        configuration.imagePadding = 14
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 17)
            return attributes
        }
        displayButton.configuration = configuration
        displayButton.contentHorizontalAlignment = .leading
        displayButton.showsMenuAsPrimaryAction = true
        displayButton.preferredMenuElementOrder = .fixed
        displayButton.accessibilityIdentifier = "browser.displayOptions"
        displayButton.layer.cornerRadius = 16
        displayButton.layer.cornerCurve = .continuous
        displayButton.layer.borderWidth = 1 / 3
        displayChevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold),
        )
        displayChevron.contentMode = .center
        displayButton.addSubview(displayChevron)
        body.addSubview(displayButton)
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
        backButton.frame = CGRect(x: 8, y: midY - side / 2, width: side, height: side)
        forwardButton.frame = CGRect(x: 47, y: midY - side / 2, width: side, height: side)
        reloadButton.frame = CGRect(x: width - 8 - side, y: midY - side / 2, width: side, height: side)
        copyButton.frame = CGRect(x: width - 45 - side, y: midY - side / 2, width: side, height: side)
        let hostInset: CGFloat = 92
        hostButton.frame = CGRect(x: hostInset, y: 0, width: width - hostInset * 2, height: Self.rowHeight)
        let count = CGFloat(max(tiles.count, 1))
        let spacing = (width - Self.tileSide * count) / max(count - 1, 1)
        for (index, (tile, label)) in zip(tiles, tileLabels).enumerated() {
            let x = Self.margin + CGFloat(index) * (Self.tileSide + spacing)
            tile.frame = CGRect(x: x, y: tileTop, width: Self.tileSide, height: Self.tileSide)
            label.frame = CGRect(x: x - 8, y: tileTop + Self.tileSide + 6, width: Self.tileSide + 16, height: 18)
        }
        displayButton.frame = CGRect(x: Self.margin, y: displayTop, width: width, height: Self.rowHeight)
        displayChevron.frame = CGRect(x: width - 18 - 16, y: 0, width: 16, height: Self.rowHeight)
    }

    func update(
        host: String, canGoBack: Bool, canGoForward: Bool, isLoading: Bool, canCopy: Bool, canReload: Bool,
        tiles newTiles: [Tile], displayMenu: UIMenu?,
    ) {
        displayButton.menu = displayMenu
        displayButton.isEnabled = displayMenu != nil
        displayButton.alpha = displayMenu == nil ? 0.45 : 1
        displayButton.backgroundColor = BrowserMobileBackdrop.buttonFill
        displayButton.layer.borderColor = BrowserMobileBackdrop.buttonBorder
            .resolvedColor(with: traitCollection)
            .cgColor
        displayButton.tintColor = .label
        displayChevron.tintColor = .secondaryLabel
        hostButton.setTitle(
            host.isEmpty ? String(localized: "Search or enter address", table: "Mobile") : host,
            for: .normal,
        )
        hostButton.setTitleColor(host.isEmpty ? .secondaryLabel : .label, for: .normal)
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        copyButton.isEnabled = canCopy
        reloadButton.isEnabled = canReload
        reloadButton.setImage(symbol(isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = isLoading
            ? String(localized: "Stop Loading", table: "Mobile")
            : String(localized: "Reload", table: "Mobile")
        addressRow.backgroundColor = BrowserMobileBackdrop.buttonFill
        addressRow.layer.borderColor = BrowserMobileBackdrop.buttonBorder.resolvedColor(with: traitCollection).cgColor
        for button in [backButton, forwardButton, copyButton, reloadButton] {
            button.tintColor = .label
        }
        plusGlyph.tintColor = .label
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
            button.tintColor = .label
            button.backgroundColor = BrowserMobileBackdrop.buttonFill
            button.layer.cornerRadius = 16
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = 1 / 3
            button.layer.borderColor = BrowserMobileBackdrop.buttonBorder.resolvedColor(with: traitCollection).cgColor
            button.isEnabled = tile.isEnabled
            button.alpha = tile.isEnabled ? 1 : 0.45
            button.removeTarget(nil, action: nil, for: .allEvents)
            button.addAction(UIAction { _ in tile.action() }, for: .touchUpInside)
            let label = tileLabels[index]
            label.text = tile.title
            label.font = .systemFont(ofSize: 13)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            label.textColor = .label.withAlphaComponent(0.66)
            label.alpha = button.alpha
        }
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
