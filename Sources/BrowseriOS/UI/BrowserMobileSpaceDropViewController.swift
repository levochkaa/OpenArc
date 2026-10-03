import UIKit

/// A drag destination palette. Space identities and row geometry stay fixed for
/// its lifetime; the source controller validates the latest document at drop.
@MainActor final class BrowserMobileSpaceDropViewController: UIViewController {
    // MARK: Lifecycle

    init(spaces: [BrowserSpaceSessionSnapshot], includesFolders: Bool, dropDelegate: any UIDropInteractionDelegate) {
        self.spaces = spaces
        self.includesFolders = includesFolders
        self.dropDelegate = dropDelegate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    struct Target: Equatable {
        let spaceID: String
        let placement: BrowserTabPlacement
        let isEnabled: Bool

        var plannerTarget: BrowserMobileSidebarDrop.Target {
            BrowserMobileSidebarDrop.rootTarget(spaceID: spaceID, placement: placement)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "browser.spaceDropTargets"
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 16
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor
        view.clipsToBounds = true
        if let dropDelegate {
            view.addInteraction(UIDropInteraction(delegate: dropDelegate))
        }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        let title = UILabel()
        title.text = String(localized: "Move to Space", table: "Mobile")
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        content.addArrangedSubview(title)
        for space in spaces {
            let label = UILabel()
            label.text = space.title
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            content.addArrangedSubview(label)
            for placement in [BrowserTabPlacement.spacePinned, .temporary] {
                let target = Target(
                    spaceID: space.id,
                    placement: placement,
                    isEnabled: placement == .spacePinned || !includesFolders
                )
                let row = makeRow(target)
                targetViews.append((target, row))
                content.addArrangedSubview(row)
            }
        }
    }

    func target(at point: CGPoint) -> Target? {
        guard view.bounds.contains(point) else { return nil }
        return targetViews.first { _, row in row.bounds.contains(row.convert(point, from: view)) }?.0
    }

    func previewTarget(for target: Target) -> UIDragPreviewTarget? {
        guard let row = targetViews.first(where: { $0.0 == target })?.1 else { return nil }
        return UIDragPreviewTarget(
            container: view,
            center: row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: view)
        )
    }

    func highlight(_ target: Target?) {
        for (candidate, row) in targetViews {
            row.backgroundColor = candidate == target
                ? view.tintColor.withAlphaComponent(0.16)
                : .tertiarySystemGroupedBackground
        }
    }

    // MARK: Private

    private let spaces: [BrowserSpaceSessionSnapshot]
    private let includesFolders: Bool
    private weak var dropDelegate: (any UIDropInteractionDelegate)?
    private var targetViews = [(Target, UIView)]()

    private func makeRow(_ target: Target) -> UIView {
        let row = UIView()
        row.backgroundColor = .tertiarySystemGroupedBackground
        row.layer.cornerRadius = 10
        row.isAccessibilityElement = true
        let isPinned = target.placement == .spacePinned
        let text = isPinned ? String(localized: "Pinned", table: "Mobile") : String(localized: "Today", table: "Mobile")
        row.accessibilityIdentifier = "browser.spaceDrop.\(target.spaceID).\(isPinned ? "pinned" : "today")"
        row.accessibilityLabel = text
        row.accessibilityTraits = target.isEnabled ? .staticText : [.staticText, .notEnabled]
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = target.isEnabled ? .label : .secondaryLabel
        label.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [label])
        labels.axis = .vertical
        labels.spacing = 2
        if !target.isEnabled {
            let detail = UILabel()
            detail.text = String(localized: "Tabs only", table: "Mobile")
            detail.font = .preferredFont(forTextStyle: .caption1)
            detail.adjustsFontForContentSizeCategory = true
            detail.textColor = .secondaryLabel
            detail.numberOfLines = 0
            labels.addArrangedSubview(detail)
            row.accessibilityValue = detail.text
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            labels.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
        ])
        return row
    }
}
