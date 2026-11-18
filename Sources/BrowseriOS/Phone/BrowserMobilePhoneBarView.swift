// BrowserMobilePhoneBarView.swift

import UIKit

// MARK: - BrowserMobilePhoneBarView

/// The phone's bottom bar: the tab stack on the left, New Tab in the middle,
/// the page menu on the right. Scrolling down shrinks it to a strip over the
/// home indicator.
final class BrowserMobilePhoneBarView: UIView {
    // MARK: Internal

    static let controlHeight: CGFloat = 40
    static let roundButtonSide: CGFloat = 34
    static let plusWidth: CGFloat = 76
    static let controlTopInset: CGFloat = 12

    /// Glass over the page under the bar: it turns light over light pages and
    /// dark over dark ones, and the controls inside follow.
    let background = UIVisualEffectView(effect: BrowserMobileBackdrop.glass())
    let tabStack = BrowserMobileTabStackButton()
    let plusButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    /// Brings the collapsed bar back. It is off while the controls show, so
    /// it never takes their taps.
    let expandRecognizer = UITapGestureRecognizer()

    private(set) var isCollapsed = false

    /// Dark glass and light glyphs over a dark page.
    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            background.overrideUserInterfaceStyle = isDark ? .dark : .light
            applyTheme()
        }
    }

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
        for button in [plusButton, moreButton] {
            button.layer.borderWidth = 1 / 3
            button.addTarget(self, action: #selector(pressDown(_:)), for: [.touchDown, .touchDragEnter])
            button.addTarget(self, action: #selector(pressUp(_:)), for: [
                .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit,
            ])
        }
        expandRecognizer.isEnabled = false
        addGestureRecognizer(expandRecognizer)
        background.overrideUserInterfaceStyle = .light
        addSubview(background)
        background.contentView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in self?.applyTheme()
        }
        background.contentView.addSubview(tabStack)
        background.contentView.addSubview(plusButton)
        background.contentView.addSubview(moreButton)
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

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        expandRecognizer.isEnabled = collapsed
        for view in [tabStack, plusButton, moreButton] as [UIView] {
            view.alpha = collapsed ? 0 : 1
            view.isUserInteractionEnabled = !collapsed
        }
    }

    // MARK: Private

    private func applyTheme() {
        for button in [plusButton, moreButton] {
            button.backgroundColor = BrowserMobileBackdrop.buttonFill
            button.layer.borderColor = BrowserMobileBackdrop.buttonBorder
                .resolvedColor(with: background.contentView.traitCollection)
                .cgColor
            button.tintColor = .label
        }
    }

    @objc private func pressDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
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
final class BrowserMobileTabStackButton: UIControl {
    // MARK: Internal

    static let cardSize = CGSize(width: 27, height: 33)

    /// Centers of the two cards relative to the button's center.
    static let frontOffset = CGPoint(x: 8, y: -3)
    static let backOffset = CGPoint(x: -8, y: 4)
    static let frontAngle: CGFloat = 9 * .pi / 180
    static let backAngle: CGFloat = -16 * .pi / 180

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.1 : 0.3, delay: 0, options: .beginFromCurrentState) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
            }
        }
    }

    let front = BrowserMobileTabStackButton.card()
    let back = BrowserMobileTabStackButton.card()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(back)
        addSubview(front)
        isAccessibilityElement = true
        accessibilityTraits = .button
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

    // MARK: Private

    private static func card() -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = 4
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor(white: 0, alpha: 0.18).cgColor
        view.backgroundColor = .white
        view.isUserInteractionEnabled = false
        return view
    }

    private static func fill(_ view: UIImageView, _ image: UIImage?) {
        view.image = image
        // Keep the page's top in view; the bottom is cut off.
        if let image, image.size.width > 0 {
            let visibleHeight = image.size.width * cardSize.height / cardSize.width
            view.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: min(1, visibleHeight / image.size.height))
            view.contentMode = .scaleToFill
        } else {
            view.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    func setImages(front frontImage: UIImage?, back backImage: UIImage?, showsFront: Bool, showsBack: Bool) {
        Self.fill(front, frontImage)
        Self.fill(back, backImage)
        front.isHidden = !showsFront
        back.isHidden = !showsBack
    }
}
