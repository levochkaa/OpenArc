// BrowserMobileSiteSettingsViewController.swift

import UIKit

// MARK: - BrowserMobileSiteSettings

/// Choices the phone keeps per site (`www.` is the same site).
enum BrowserMobileSiteSettings {
    private static let keepsBarKey = "BrowserMobileSiteSettings.keepsBarExpanded"

    /// Whether scrolling the site's pages collapses the bottom bar.
    static func collapsesBar(onPage urlString: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let host = BrowserMobileFavicons.host(forPage: urlString ?? "") else { return true }
        return !(defaults.stringArray(forKey: keepsBarKey) ?? []).contains(host)
    }

    static func setCollapsesBar(_ collapses: Bool, host: String, defaults: UserDefaults = .standard) {
        var hosts = Set(defaults.stringArray(forKey: keepsBarKey) ?? [])
        if collapses { hosts.remove(host) } else { hosts.insert(host) }
        defaults.set(hosts.sorted(), forKey: keepsBarKey)
    }
}

// MARK: - BrowserFilterListKind + Mobile

extension BrowserFilterListKind {
    /// The order the phone lists the blocker's switches in.
    static let mobileOrder: [Self] = [.ads, .cookieBanners, .trackers]

    var mobileTitle: String {
        switch self {
        case .ads: String(localized: "Block Ads", table: "Mobile")
        case .cookieBanners: String(localized: "Block Cookie Banners", table: "Mobile")
        case .trackers: String(localized: "Block Trackers", table: "Mobile")
        }
    }

    @MainActor var mobileTile: UIImage {
        switch self {
        case .ads: BrowserMobileSiteSettingsViewController.tile("hand.raised.fill", color: .systemRed)
        case .cookieBanners: BrowserMobileSiteSettingsViewController.tile(
                "rectangle.bottomthird.inset.filled", color: .systemOrange,
            )
        case .trackers: BrowserMobileSiteSettingsViewController.tile("eyeglasses", color: .systemYellow)
        }
    }
}

// MARK: - BrowserMobileSiteSettingsViewController

/// Settings for the site of the open page, from the page menu.
final class BrowserMobileSiteSettingsViewController: UITableViewController {
    /// Opaque grays of the phone's dark sheets.
    static let sheetBackground = UIColor(white: 0.17, alpha: 1)
    static let cellBackground = UIColor(white: 0.265, alpha: 1)

    // MARK: Internal

    var showAppSettings: (() -> Void)?
    /// Called once the sheet goes away after a blocker switch changed, so the page loads again with it.
    var didChangeBlocking: (() -> Void)?

    private var changedBlocking = false

    // MARK: Private

    private let host: String
    private let collapseSwitch = UISwitch()
    private var blockingSwitches = [BrowserFilterListKind: UISwitch]()

    private var pageURLString: String { "https://\(host)/" }

    init(host: String) {
        self.host = host
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Site Settings", table: "Mobile")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done", table: "Mobile"), style: .plain, target: self, action: #selector(done),
        )
        tableView.backgroundColor = Self.sheetBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        collapseSwitch.isOn = BrowserMobileSiteSettings.collapsesBar(onPage: "https://\(host)")
        collapseSwitch.accessibilityIdentifier = "browser.siteSettings.collapseBar"
        collapseSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            BrowserMobileSiteSettings.setCollapsesBar(collapseSwitch.isOn, host: host)
        }, for: .valueChanged)
        let settings = BrowserMobileContentBlocking.settings()
        for kind in BrowserFilterListKind.mobileOrder {
            let toggle = UISwitch()
            toggle.isOn = settings.enabledKinds(forURLString: pageURLString).contains(kind)
            // A list turned off in Settings stays off everywhere.
            toggle.isEnabled = settings.blocks(kind)
            toggle.accessibilityIdentifier = "browser.siteSettings.block.\(kind.rawValue)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                BrowserMobileContentBlocking.setBlocks(kind, toggle.isOn, onPage: pageURLString)
                changedBlocking = true
            }, for: .valueChanged)
            blockingSwitches[kind] = toggle
        }
    }

    override func numberOfSections(in _: UITableView) -> Int { 3 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? BrowserFilterListKind.mobileOrder.count : 1
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? String(localized: "\(host) Settings", table: "Mobile").uppercased() : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.cell()
        if indexPath.section == 0 {
            let kind = BrowserFilterListKind.mobileOrder[indexPath.row]
            content.text = kind.mobileTitle
            content.image = kind.mobileTile
            cell.accessoryView = blockingSwitches[kind]
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            content.text = String(localized: "Collapse Bottom Bar", table: "Mobile")
            content.image = Self.tile("iphone.gen3", color: .systemPurple)
            cell.accessoryView = collapseSwitch
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            content.text = String(localized: "App Settings", table: "Mobile")
            content.image = Self.tile("gearshape.fill", color: .systemGray)
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "browser.siteSettings.appSettings"
        }
        cell.contentConfiguration = content
        cell.backgroundColor = Self.cellBackground
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        showAppSettings?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard changedBlocking else { return }
        changedBlocking = false
        didChangeBlocking?()
    }

    /// A white symbol on a colored rounded square, as in the system's Settings.
    static func tile(_ symbol: String, color: UIColor) -> UIImage {
        let side: CGFloat = 29
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            .image { _ in
                color.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 7).fill()
                let glyph = UIImage(
                    systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium),
                )?.withTintColor(.white, renderingMode: .alwaysOriginal)
                if let glyph {
                    glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
                }
            }
            .withRenderingMode(.alwaysOriginal)
    }

    @objc private func done() {
        dismiss(animated: true)
    }
}
