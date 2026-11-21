// BrowserMobileLoadErrorView.swift

import UIKit

// MARK: - BrowserMobileLoadErrorView

/// What shows in place of a page that failed to load: a sad face, the
/// error, and a button that loads the page again. It fills its own
/// background and centers its content inside `contentInsets`.
final class BrowserMobileLoadErrorView: UIView {
    // MARK: Internal

    static let background = UIColor {
        $0.userInterfaceStyle == .dark ? .black : UIColor(red: 234 / 255, green: 235 / 255, blue: 238 / 255, alpha: 1)
    }

    private static let faceColor = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 52 / 255, alpha: 1)
            : UIColor(red: 190 / 255, green: 192 / 255, blue: 209 / 255, alpha: 1)
    }

    private static let titleColor = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 254 / 255, alpha: 1)
            : UIColor(red: 14 / 255, green: 17 / 255, blue: 95 / 255, alpha: 1)
    }

    private static let messageColor = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 137 / 255, green: 138 / 255, blue: 137 / 255, alpha: 1)
            : UIColor(red: 137 / 255, green: 139 / 255, blue: 166 / 255, alpha: 1)
    }

    /// From the face's bottom to the title's cap height, and from the
    /// title's baseline to the message's cap height.
    private static let faceToTitle: CGFloat = 70.7
    private static let titleToMessage: CGFloat = 30.3
    private static let messageToButton: CGFloat = 28
    private static let buttonHeight: CGFloat = 40
    private static let sideInset: CGFloat = 40

    /// Insets of the area the content centers in, such as the status bar
    /// above and the bar below.
    var contentInsets = UIEdgeInsets.zero {
        didSet { if contentInsets != oldValue { setNeedsLayout() } }
    }

    var onReload: (() -> Void)?

    // MARK: Private

    private let face = BrowserMobileLoadErrorFace()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let reloadButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.loadError"
        backgroundColor = Self.background
        face.color = Self.faceColor
        titleLabel.text = String(localized: "Loading Error", table: "Mobile")
        titleLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(
            ofSize: 28,
            weight: .semibold,
        ))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Self.titleColor
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        messageLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 20))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = Self.messageColor
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Reload", table: "Mobile")
        configuration.image = UIImage(
            systemName: "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold),
        )
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(
                ofSize: 17,
                weight: .semibold,
            ))
            return attributes
        }
        configuration.baseForegroundColor = BrowserMobileBackdrop.glyph
        reloadButton.configuration = configuration
        reloadButton.accessibilityIdentifier = "browser.loadError.reload"
        reloadButton.backgroundColor = BrowserMobileBackdrop.buttonFill
        reloadButton.layer.cornerRadius = Self.buttonHeight / 2
        reloadButton.layer.cornerCurve = .continuous
        reloadButton.layer.borderWidth = 1 / 3
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReload?() }, for: .touchUpInside)
        for view in [face, titleLabel, messageLabel, reloadButton] as [UIView] {
            addSubview(view)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.applyBorder() }
        applyBorder()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: contentInsets)
        let width = max(area.width - 2 * Self.sideInset, 1)
        let titleFont = titleLabel.font ?? .systemFont(ofSize: 28)
        let messageFont = messageLabel.font ?? .systemFont(ofSize: 20)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let messageHeight = messageLabel.isHidden
            ? 0
            : messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // Labels put their first baseline an ascender below their top.
        let titleGap = Self.faceToTitle - (titleFont.ascender - titleFont.capHeight)
        let messageGap = Self.titleToMessage + titleFont.descender - (messageFont.ascender - messageFont.capHeight)
        let faceSize = BrowserMobileLoadErrorFace.size
        // The face and the words center in the area; the button hangs below them.
        let blockHeight = faceSize.height + titleGap + titleHeight + (messageLabel.isHidden
            ? 0
            : messageGap + messageHeight)
        var y = (area.midY - blockHeight / 2).rounded()
        face.frame = CGRect(
            x: (area.midX - faceSize.width / 2).rounded(),
            y: y,
            width: faceSize.width,
            height: faceSize.height,
        )
        y += faceSize.height + titleGap
        titleLabel.frame = CGRect(x: area.midX - width / 2, y: y, width: width, height: titleHeight)
        y += titleHeight
        if !messageLabel.isHidden {
            y += messageGap
            messageLabel.frame = CGRect(x: area.midX - width / 2, y: y, width: width, height: messageHeight)
            y += messageHeight
        }
        let buttonWidth = min(reloadButton.sizeThatFits(CGSize(width: width, height: Self.buttonHeight)).width, width)
        reloadButton.frame = CGRect(
            x: (area.midX - buttonWidth / 2).rounded(), y: (y + Self.messageToButton).rounded(),
            width: buttonWidth, height: Self.buttonHeight,
        )
    }

    func setMessage(_ message: String?) {
        messageLabel.text = message
        messageLabel.isHidden = message?.isEmpty ?? true
        setNeedsLayout()
    }

    private func applyBorder() {
        reloadButton.layer.borderColor = BrowserMobileBackdrop.buttonBorder.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - BrowserMobileLoadErrorFace

/// Two crossed-out eyes over a frown, in thick round strokes.
private final class BrowserMobileLoadErrorFace: UIView {
    static let size = CGSize(width: 133, height: 142.3)

    private static let stroke: CGFloat = 20
    /// Half the length of each eye's arms along either axis.
    private static let eyeReach: CGFloat = 18.5
    private static let eyeCenters = [CGPoint(x: 28.5, y: 28.5), CGPoint(x: 104.5, y: 28.5)]
    private static let mouthRadius: CGFloat = 103
    /// Half the distance between the frown's two ends, and their height.
    private static let mouthHalfWidth: CGFloat = 51.85
    private static let mouthEndY: CGFloat = 132.3

    override static var layerClass: AnyClass { CAShapeLayer.self }

    var color = UIColor.gray {
        didSet { applyColor() }
    }

    private var shape: CAShapeLayer? { layer as? CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        shape?.fillColor = nil
        shape?.lineWidth = Self.stroke
        shape?.lineCap = .round
        shape?.path = Self.path()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.applyColor() }
        applyColor()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func path() -> CGPath {
        let path = CGMutablePath()
        for center in eyeCenters {
            path.move(to: CGPoint(x: center.x - eyeReach, y: center.y - eyeReach))
            path.addLine(to: CGPoint(x: center.x + eyeReach, y: center.y + eyeReach))
            path.move(to: CGPoint(x: center.x + eyeReach, y: center.y - eyeReach))
            path.addLine(to: CGPoint(x: center.x - eyeReach, y: center.y + eyeReach))
        }
        let half = asin(mouthHalfWidth / mouthRadius)
        let center = CGPoint(x: size.width / 2, y: mouthEndY + mouthRadius * cos(half))
        // Up is negative y: the frown runs over the top of its circle.
        path.move(to: CGPoint(x: center.x - mouthHalfWidth, y: mouthEndY))
        path.addArc(
            center: center, radius: mouthRadius,
            startAngle: -.pi / 2 - half, endAngle: -.pi / 2 + half, clockwise: false,
        )
        return path
    }

    private func applyColor() {
        shape?.strokeColor = color.resolvedColor(with: traitCollection).cgColor
    }
}
