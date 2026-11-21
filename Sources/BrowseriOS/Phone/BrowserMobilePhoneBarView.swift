// BrowserMobilePhoneBarView.swift

import UIKit

// MARK: - BrowserMobilePhoneBarView

/// The phone's bottom bar: the tab stack on the left, New Tab in the middle,
/// the page menu on the right. Scrolling down shrinks it to a strip over the
/// home indicator. Over the tab switcher the same bar shows Spaces and
/// Settings in place of the tab stack and the page menu.
final class BrowserMobilePhoneBarView: UIView {
    // MARK: Internal

    static let controlHeight: CGFloat = 40
    static let roundButtonSide: CGFloat = 34
    static let plusWidth: CGFloat = 76
    static let controlTopInset: CGFloat = 12

    /// The material over the page under the bar: it turns light over light
    /// pages and dark over dark ones, and the controls inside follow.
    let background = BrowserMobileBarMaterial()
    let tabStack = BrowserMobileTabStackButton()
    let plusButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    let spacesButton = UIButton(type: .custom)
    let settingsButton = UIButton(type: .custom)
    /// Marks the page menu button while the page came over plain http.
    let insecureBadge = UIView()
    /// Brings the collapsed bar back. It is off while the controls show, so
    /// it never takes their taps.
    let expandRecognizer = UITapGestureRecognizer()

    private(set) var isCollapsed = false

    /// Spaces and Settings in place of the tab stack and the page menu.
    private(set) var showsSwitcherControls = false

    /// Dark glass and light glyphs over a dark page.
    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            background.overrideUserInterfaceStyle = isDark ? .dark : .light
            applyTheme()
        }
    }

    /// The controls beside New Tab that show now: the tab stack and the page
    /// menu, or Spaces and Settings.
    var sideControls: [UIControl] {
        showsSwitcherControls ? [spacesButton, settingsButton] : [tabStack, moreButton]
    }

    // MARK: Private

    private var roundButtons: [UIButton] { [moreButton, spacesButton, settingsButton] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.phoneBar"
        clipsToBounds = false
        tabStack.accessibilityIdentifier = "browser.showTabs"
        tabStack.accessibilityLabel = String(localized: "Tabs", table: "Mobile")
        plusButton.accessibilityIdentifier = "browser.newTab"
        plusButton.accessibilityLabel = String(localized: "New Tab", table: "Mobile")
        plusButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
            ),
            for: .normal,
        )
        plusButton.layer.cornerRadius = Self.controlHeight / 2
        plusButton.layer.cornerCurve = .continuous
        moreButton.accessibilityIdentifier = "browser.pageMenu"
        moreButton.accessibilityLabel = String(localized: "Page Menu", table: "Mobile")
        moreButton.setImage(
            UIImage(
                systemName: "chevron.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold),
            ),
            for: .normal,
        )
        moreButton.layer.cornerRadius = Self.roundButtonSide / 2
        insecureBadge.backgroundColor = .black
        insecureBadge.isUserInteractionEnabled = false
        insecureBadge.isHidden = true
        insecureBadge.bounds = CGRect(x: 0, y: 0, width: 18.7, height: 18.7)
        insecureBadge.layer.cornerRadius = 18.7 / 2
        let lock = UIImageView(image: UIImage(
            systemName: "lock.slash.fill", withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9,
                weight: .semibold,
            ),
        ))
        lock.tintColor = UIColor(red: 0.51, green: 0.51, blue: 0.53, alpha: 1)
        lock.center = CGPoint(x: 18.7 / 2, y: 18.7 / 2)
        insecureBadge.addSubview(lock)
        moreButton.addSubview(insecureBadge)
        for (button, symbol, size, title, id) in [
            (spacesButton, "desktopcomputer", 16, String(localized: "Spaces", table: "Mobile"), "browser.spaces"),
            (settingsButton, "gear", 18, String(localized: "Settings", table: "Mobile"), "browser.settings"),
        ] as [(UIButton, String, CGFloat, String, String)] {
            button.setImage(
                UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: size, weight: .medium,
                )),
                for: .normal,
            )
            button.accessibilityLabel = title
            button.accessibilityIdentifier = id
            button.layer.cornerRadius = Self.roundButtonSide / 2
            button.alpha = 0
            button.isUserInteractionEnabled = false
        }
        for button in roundButtons + [plusButton] {
            button.layer.borderWidth = 1 / 3
            button.addTarget(self, action: #selector(pressDown(_:)), for: [.touchDown, .touchDragEnter])
            button.addTarget(self, action: #selector(pressUp(_:)), for: [
                .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit,
            ])
        }
        expandRecognizer.isEnabled = false
        addGestureRecognizer(expandRecognizer)
        background.overrideUserInterfaceStyle = .light
        background.showsTopHairline = true
        addSubview(background)
        background.contentView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in self?.applyTheme()
        }
        background.contentView.addSubview(tabStack)
        background.contentView.addSubview(plusButton)
        background.contentView.addSubview(moreButton)
        background.contentView.addSubview(spacesButton)
        background.contentView.addSubview(settingsButton)
        applyTheme()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        let centerY = Self.controlTopInset + Self.controlHeight / 2
        plusButton.bounds = CGRect(x: 0, y: 0, width: Self.plusWidth, height: Self.controlHeight)
        plusButton.center = CGPoint(x: bounds.midX, y: centerY)
        moreButton.bounds = CGRect(x: 0, y: 0, width: Self.roundButtonSide, height: Self.roundButtonSide)
        moreButton.center = CGPoint(x: bounds.maxX - 24 - Self.roundButtonSide / 2, y: centerY)
        insecureBadge.center = CGPoint(x: Self.roundButtonSide / 2 + 12.8, y: Self.roundButtonSide / 2 - 13.2)
        settingsButton.frame = moreButton.frame
        spacesButton.bounds = moreButton.bounds
        spacesButton.center = CGPoint(x: 24 + Self.roundButtonSide / 2, y: centerY)
        tabStack.bounds = CGRect(x: 0, y: 0, width: 76, height: 64)
        tabStack.center = CGPoint(x: 9 + 38, y: centerY)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The tab stack's cards lean past the bar's top edge.
        super.point(inside: point, with: event) || tabStack.frame.contains(point)
    }

    /// Height for the bar above `safeBottom`: room for the controls and the
    /// home indicator, or only the indicator's strip when collapsed.
    static func height(safeBottom: CGFloat, collapsed: Bool) -> CGFloat {
        let strip = max(safeBottom, 12)
        return collapsed ? strip : controlTopInset + controlHeight + max(safeBottom - 10, 12)
    }

    /// Swaps the tab stack and the page menu for Spaces and Settings; call it
    /// inside an animation to crossfade them.
    func setShowsSwitcherControls(_ shows: Bool, showsMaterial: Bool? = nil) {
        showsSwitcherControls = shows
        // Over the switcher the bar has no material of its own.
        background.showsMaterial = showsMaterial ?? !shows
        for (view, visible) in [
            (tabStack, !shows), (moreButton, !shows), (spacesButton, shows), (settingsButton, shows),
        ] as [(UIView, Bool)] {
            view.alpha = visible ? 1 : 0
            view.isUserInteractionEnabled = visible
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        expandRecognizer.isEnabled = collapsed
        for view in [tabStack, plusButton, moreButton] as [UIView] {
            view.alpha = collapsed ? 0 : 1
            view.isUserInteractionEnabled = !collapsed
        }
    }

    private func applyTheme() {
        for button in roundButtons + [plusButton] {
            button.backgroundColor = BrowserMobileBackdrop.buttonFill
            button.layer.borderColor = BrowserMobileBackdrop.buttonBorder
                .resolvedColor(with: background.contentView.traitCollection)
                .cgColor
            button.tintColor = BrowserMobileBackdrop.glyph
        }
    }

    @objc private func pressDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }
    }

    @objc private func pressUp(_ sender: UIButton) {
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
        ) {
            sender.transform = .identity
        }
    }
}

// MARK: - BrowserMobileTabStackButton

/// Two small tilted pictures of the tabs before this one; tapping opens the switcher.
/// A card with no tab behind it stays as a blank translucent card, so the
/// stack always shows two.
final class BrowserMobileTabStackButton: UIControl {
    // MARK: Internal

    static let cardSize = CGSize(width: 27, height: 33)

    /// Centers of the two cards relative to the button's center.
    static let frontOffset = CGPoint(x: 8, y: -3)
    static let backOffset = CGPoint(x: -8, y: 4)
    static let frontAngle: CGFloat = 9 * .pi / 180
    static let backAngle: CGFloat = -16 * .pi / 180

    // MARK: Private

    private static let blankFill = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08)
    }

    private static let edge = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.14)
    }

    let front = BrowserMobileTabStackButton.card()
    let back = BrowserMobileTabStackButton.card()
    /// Shares of the pictures' width to leave out at each side: the page's
    /// side insets, such as the strip beside the camera on iPhone Duo.
    var sideCrop: (left: CGFloat, right: CGFloat) = (0, 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(back)
        addSubview(front)
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.applyCardColors() }
        applyCardColors()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for (card, offset, angle) in [
            (front, Self.frontOffset, Self.frontAngle), (back, Self.backOffset, Self.backAngle),
        ] {
            card.transform = .identity
            card.bounds = CGRect(origin: .zero, size: Self.cardSize)
            card.center = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            card.transform = CGAffineTransform(rotationAngle: angle)
        }
    }

    private static func card() -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = 4
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.layer.borderWidth = 0.5
        view.isUserInteractionEnabled = false
        return view
    }

    func setImages(front frontImage: UIImage?, back backImage: UIImage?) {
        fill(front, frontImage)
        fill(back, backImage)
        applyCardColors()
    }

    private func fill(_ view: UIImageView, _ image: UIImage?) {
        view.image = image
        // Keep the page's top in view; the bottom is cut off.
        if let image, image.size.width > 0 {
            let share = max(1 - sideCrop.left - sideCrop.right, 0.1)
            let visibleHeight = image.size.width * share * Self.cardSize.height / Self.cardSize.width
            view.layer.contentsRect = CGRect(
                x: sideCrop.left, y: 0, width: share, height: min(1, visibleHeight / image.size.height),
            )
            view.contentMode = .scaleToFill
        } else {
            view.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    private func applyCardColors() {
        for card in [front, back] {
            card.backgroundColor = card.image == nil ? Self.blankFill : .white
            card.layer.borderColor = Self.edge.resolvedColor(with: traitCollection).cgColor
        }
    }
}
