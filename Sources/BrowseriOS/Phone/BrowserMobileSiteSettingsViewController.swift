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

// MARK: - BrowserMobileSiteSettingsViewController

/// Settings for the site of the open page, from the page menu.
final class BrowserMobileSiteSettingsViewController: UITableViewController {
    /// Opaque grays of the phone's dark sheets.
    static let sheetBackground = UIColor(white: 0.17, alpha: 1)
    static let cellBackground = UIColor(white: 0.265, alpha: 1)

    // MARK: Internal

    var showAppSettings: (() -> Void)?

    // MARK: Private

    private let host: String
    private let collapseSwitch = UISwitch()

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
    }

    override func numberOfSections(in _: UITableView) -> Int { 2 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { 1 }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? String(localized: "\(host) Settings", table: "Mobile").uppercased() : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.cell()
        if indexPath.section == 0 {
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
        guard indexPath.section == 1 else { return }
        showAppSettings?()
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
