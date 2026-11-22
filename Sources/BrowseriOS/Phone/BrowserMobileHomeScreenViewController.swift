// BrowserMobileHomeScreenViewController.swift

import UIKit

// MARK: - BrowserMobileHomeScreenViewController

/// Settings ▸ Add to Home Screen: the widgets as they look, and how to add one.
/// iOS lets only the person add a widget, so this shows the way.
final class BrowserMobileHomeScreenViewController: UIViewController, UIScrollViewDelegate {
    // MARK: Lifecycle

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    static func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: BrowserMobileHomeScreenViewController())
        // Over Settings, it keeps Settings' look.
        navigation.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        navigation.sheetPresentationController?.detents = [.large()]
        presenter.present(navigation, animated: true)
    }

    /// The steps that add the widget, in order.
    static var steps: [String] {
        [
            String(localized: "Touch and hold an empty spot on your Home Screen.", table: "Mobile"),
            String(localized: "Tap Edit in the corner, then Add Widget.", table: "Mobile"),
            String(localized: "Find OpenArc in the list, pick a size and tap Add Widget.", table: "Mobile"),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "browser.homeScreen"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "browser.homeScreen.close"

        let title = UILabel()
        title.text = String(localized: "Bring OpenArc to your Home Screen", table: "Mobile")
        title.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0
        title.accessibilityTraits = .header

        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.delegate = self
        let previews = [WidgetPreview(isWide: false), WidgetPreview(isWide: true)]
        for preview in previews {
            let page = UIView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.centerXAnchor.constraint(equalTo: page.centerXAnchor),
                preview.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            ])
            pageRow.addArrangedSubview(page)
        }
        pageRow.axis = .horizontal
        pageRow.distribution = .fillEqually
        pageRow.translatesAutoresizingMaskIntoConstraints = false
        pages.addSubview(pageRow)
        pageControl.numberOfPages = previews.count
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel
        pageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pages.setContentOffset(
                CGPoint(x: CGFloat(pageControl.currentPage) * pages.bounds.width, y: 0), animated: true,
            )
        }, for: .valueChanged)

        let list = UIStackView(arrangedSubviews: Self.steps.enumerated().map { Self.stepRow(number: $0 + 1, text: $1) })
        list.axis = .vertical
        list.spacing = 14

        let done = UIButton(configuration: {
            var configuration = UIButton.Configuration.filled()
            configuration.title = String(localized: "Done", table: "Mobile")
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .large
            return configuration
        }(), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        done.accessibilityIdentifier = "browser.homeScreen.done"

        let column = UIStackView(arrangedSubviews: [title, pages, pageControl, list])
        column.axis = .vertical
        column.spacing = 16
        column.setCustomSpacing(4, after: pages)
        column.setCustomSpacing(24, after: pageControl)
        let scroll = UIScrollView()
        scroll.addSubview(column)
        for view in [scroll, column, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(scroll)
        view.addSubview(done)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            pages.heightAnchor.constraint(equalToConstant: 200),
            pageRow.topAnchor.constraint(equalTo: pages.contentLayoutGuide.topAnchor),
            pageRow.bottomAnchor.constraint(equalTo: pages.contentLayoutGuide.bottomAnchor),
            pageRow.leadingAnchor.constraint(equalTo: pages.contentLayoutGuide.leadingAnchor),
            pageRow.trailingAnchor.constraint(equalTo: pages.contentLayoutGuide.trailingAnchor),
            pageRow.heightAnchor.constraint(equalTo: pages.frameLayoutGuide.heightAnchor),
            pageRow.widthAnchor.constraint(
                equalTo: pages.frameLayoutGuide.widthAnchor, multiplier: CGFloat(previews.count),
            ),
            done.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            done.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages, scrollView.bounds.width > 0 else { return }
        pageControl.currentPage = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
    }

    // MARK: Private

    private let pages = UIScrollView()
    private let pageRow = UIStackView()
    private let pageControl = UIPageControl()

    private static func stepRow(number: Int, text: String) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = .systemFont(ofSize: 15, weight: .bold)
        badge.textAlignment = .center
        badge.textColor = .systemBackground
        badge.backgroundColor = .label
        badge.layer.cornerRadius = 13
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [badge, label])
        row.alignment = .firstBaseline
        row.spacing = 12
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(number). \(text)"
        return row
    }
}

// MARK: - WidgetPreview

/// The widget drawn as the Home Screen shows it, for the guide only.
private final class WidgetPreview: UIView {
    // MARK: Lifecycle

    init(isWide: Bool) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityLabel = isWide
            ? String(localized: "Medium widget: search, Voice Search and New Tab", table: "Mobile")
            : String(localized: "Small widget: search, Voice Search and New Tab", table: "Mobile")

        let mark = UIImageView(image: BrowserMobileAppIcon.original.preview)
        mark.layer.cornerRadius = 7
        mark.layer.cornerCurve = .continuous
        mark.clipsToBounds = true
        let field = Self.capsule()
        let fieldLabel = UILabel()
        fieldLabel.text = String(localized: "Search", table: "Mobile")
        fieldLabel.font = .systemFont(ofSize: 16, weight: .medium)
        fieldLabel.textColor = .secondaryLabel
        let fieldRow = UIStackView(arrangedSubviews: [fieldLabel])
        if isWide {
            let microphone = UIImageView(image: UIImage(systemName: "mic.fill"))
            microphone.tintColor = .secondaryLabel
            microphone.setContentHuggingPriority(.required, for: .horizontal)
            fieldRow.addArrangedSubview(microphone)
        }
        fieldRow.alignment = .center
        Self.fill(field, with: fieldRow, inset: 14)
        let top = UIStackView(arrangedSubviews: [mark, field])
        top.spacing = isWide ? 10 : 8
        top.alignment = .center
        let buttons = isWide
            ? [Self.button(symbol: "mic.fill", title: String(localized: "Voice Search", table: "Mobile")),
               Self.button(symbol: "plus", title: String(localized: "New Tab", table: "Mobile"))]
            : [Self.button(symbol: "mic.fill", title: nil), Self.button(symbol: "plus", title: nil)]
        let bottom = UIStackView(arrangedSubviews: buttons)
        bottom.spacing = 10
        bottom.distribution = .fillEqually
        let column = UIStackView(arrangedSubviews: [top, bottom])
        column.axis = .vertical
        column.spacing = 12
        Self.fill(self, with: column, inset: 16)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: isWide ? 338 : 158),
            heightAnchor.constraint(equalToConstant: 158),
            mark.widthAnchor.constraint(equalToConstant: 30),
            mark.heightAnchor.constraint(equalToConstant: 30),
            field.heightAnchor.constraint(equalToConstant: 40),
        ] + buttons.map { $0.heightAnchor.constraint(equalToConstant: 44) })
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Private

    private static func capsule() -> UIView {
        let view = UIView()
        view.backgroundColor = .tertiarySystemFill
        view.layer.cornerRadius = 20
        return view
    }

    private static func button(symbol: String, title: String?) -> UIView {
        let view = capsule()
        view.layer.cornerRadius = 22
        let image = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold),
        ))
        image.tintColor = .label
        let row = UIStackView(arrangedSubviews: [image])
        row.spacing = 6
        row.alignment = .center
        if let title {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            row.addArrangedSubview(label)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
        ])
        return view
    }

    private static func fill(_ container: UIView, with content: UIView, inset: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }
}
