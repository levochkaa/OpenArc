// BrowserMobileAppIconViewController.swift

import UIKit

// MARK: - BrowserMobileAppIconTile

/// One icon to pick: its picture rounded like the Home Screen's, and a mark
/// under it when it is the chosen one.
final class BrowserMobileAppIconTile: UIControl {
    // MARK: Lifecycle

    init(icon: BrowserMobileAppIcon, side: CGFloat) {
        self.icon = icon
        self.side = side
        super.init(frame: .zero)
        picture.image = icon.preview
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = side * 0.225
        picture.layer.cornerCurve = .continuous
        picture.isUserInteractionEnabled = false
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = side * 0.225 + 4
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = 2
        mark.isUserInteractionEnabled = false
        mark.contentMode = .center
        for view in [ring, picture, mark] {
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = icon.title
        accessibilityIdentifier = "browser.appIcon.\(icon.rawValue)"
        updateSelection()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    let icon: BrowserMobileAppIcon

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var isHighlighted: Bool {
        didSet { picture.alpha = isHighlighted ? 0.6 : 1 }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side + 12, height: side + 12 + Self.markGap + Self.markSide)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = (bounds.width - side) / 2
        picture.frame = CGRect(x: x, y: 6, width: side, height: side)
        ring.frame = picture.frame.insetBy(dx: -5, dy: -5)
        mark.frame = CGRect(
            x: (bounds.width - Self.markSide) / 2, y: picture.frame.maxY + 6 + Self.markGap,
            width: Self.markSide, height: Self.markSide,
        )
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateSelection()
    }

    // MARK: Private

    private static let markGap: CGFloat = 8
    private static let markSide: CGFloat = 22

    private let side: CGFloat
    private let picture = UIImageView()
    private let ring = UIView()
    private let mark = UIImageView()

    private func updateSelection() {
        ring.layer.borderColor = isSelected ? tintColor.cgColor : UIColor.clear.cgColor
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        mark.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle", withConfiguration: configuration,
        )
        mark.tintColor = isSelected ? tintColor : .tertiaryLabel
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

// MARK: - BrowserMobileAppIconViewController

/// Settings ▸ Change App Icon: the icons in a row to scroll, the Home
/// Screen's one marked.
final class BrowserMobileAppIconViewController: UIViewController {
    // MARK: Lifecycle

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "App Icon", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    /// Shows the picker as a short sheet over `presenter`.
    static func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: BrowserMobileAppIconViewController())
        // Over Settings, it keeps Settings' look.
        navigation.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("appIcon")) { _ in 236 }]
            sheet.prefersGrabberVisible = false
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "browser.appIconPicker"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "browser.appIconPicker.close"
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        let current = BrowserMobileAppIcon.current
        for icon in BrowserMobileAppIcon.allCases {
            let tile = BrowserMobileAppIconTile(icon: icon, side: 64)
            tile.isSelected = icon == current
            tile.addAction(UIAction { [weak self] _ in self?.choose(icon) }, for: .touchUpInside)
            row.addArrangedSubview(tile)
        }
        view.addSubview(scroll)
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: Private

    private let scroll = UIScrollView()
    private let row = UIStackView()

    private func choose(_ icon: BrowserMobileAppIcon) {
        Task { [weak self] in
            await BrowserMobileAppIcon.choose(icon)
            self?.showSelection(BrowserMobileAppIcon.current)
        }
        showSelection(icon)
    }

    private func showSelection(_ icon: BrowserMobileAppIcon) {
        for case let tile as BrowserMobileAppIconTile in row.arrangedSubviews {
            tile.isSelected = tile.icon == icon
        }
    }
}
