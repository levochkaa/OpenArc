// BrowserMobileLanguagesViewController.swift

import Speech
import UIKit

// MARK: - BrowserMobileVoiceSearchLanguages

/// The languages Voice Search may listen in, and the one it uses. With none
/// chosen it listens in the keyboard's language.
enum BrowserMobileVoiceSearchLanguages {
    static let listKey = "browser.settings.voiceSearchLanguages"
    static let preferredKey = "browser.settings.voiceSearchLanguage"

    /// The added languages as BCP 47 codes, in the order they were added.
    static func list(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: listKey) ?? []
    }

    /// The language Voice Search listens in, or nil for the keyboard's.
    static func preferred(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: preferredKey).flatMap { list(defaults).contains($0) ? $0 : nil }
    }

    static func setPreferred(_ language: String?, defaults: UserDefaults = .standard) {
        defaults.set(language, forKey: preferredKey)
    }

    /// Adds the language and makes it the one Voice Search uses.
    static func add(_ language: String, defaults: UserDefaults = .standard) {
        var languages = list(defaults)
        if !languages.contains(language) {
            languages.append(language)
            defaults.set(languages, forKey: listKey)
        }
        setPreferred(language, defaults: defaults)
    }

    /// Removes the language; Voice Search falls back to the keyboard's if it was the one in use.
    static func remove(_ language: String, defaults: UserDefaults = .standard) {
        defaults.set(list(defaults).filter { $0 != language }, forKey: listKey)
        if defaults.string(forKey: preferredKey) == language {
            setPreferred(nil, defaults: defaults)
        }
    }

    /// The language Voice Search starts in: the chosen one, else the keyboard's.
    static func language(keyboard: String?, defaults: UserDefaults = .standard) -> String? {
        preferred(defaults) ?? keyboard
    }

    /// A language's name in the app's language, such as "Russian (Russia)".
    static func name(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    /// A language's name in itself, such as "русский (Россия)".
    static func nativeName(_ language: String) -> String {
        Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }
}

// MARK: - BrowserMobileLanguagesViewController

/// Settings ▸ Languages: the languages Voice Search may listen in. Tapping one
/// makes it the one in use; Keyboard Language follows the keyboard.
final class BrowserMobileLanguagesViewController: UITableViewController {
    // MARK: Lifecycle

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(style: .insetGrouped)
        title = String(localized: "Languages", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.languages"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        languages.count + 2
    }

    override func tableView(_: UITableView, titleForHeaderInSection _: Int) -> String? {
        String(localized: "Voice Search", table: "Mobile")
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(
            localized: "Voice Search listens in the checked language. Keyboard Language follows the keyboard you type with.",
            table: "Mobile",
        )
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        let preferred = BrowserMobileVoiceSearchLanguages.preferred(defaults)
        switch row(at: indexPath) {
        case .keyboard:
            content.text = String(localized: "Keyboard Language", table: "Mobile")
            cell.accessoryType = preferred == nil ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.languages.keyboard"
        case let .language(language):
            content.text = BrowserMobileVoiceSearchLanguages.name(language)
            content.secondaryText = BrowserMobileVoiceSearchLanguages.nativeName(language)
            cell.accessoryType = preferred == language ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.languages.\(language)"
        case .add:
            content.text = String(localized: "Add Language…", table: "Mobile")
            content.textProperties.color = tableView.tintColor
            cell.accessoryType = .none
            cell.accessibilityIdentifier = "browser.languages.add"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch row(at: indexPath) {
        case .keyboard:
            BrowserMobileVoiceSearchLanguages.setPreferred(nil, defaults: defaults)
        case let .language(language):
            BrowserMobileVoiceSearchLanguages.setPreferred(language, defaults: defaults)
        case .add:
            navigationController?.pushViewController(
                BrowserMobileAddLanguageViewController(defaults: defaults), animated: true,
            )
            return
        }
        tableView.reloadData()
    }

    override func tableView(
        _: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .language(language) = row(at: indexPath) else { return nil }
        let remove = UIContextualAction(
            style: .destructive, title: String(localized: "Remove", table: "Mobile"),
        ) { [weak self] _, _, done in
            guard let self else { return done(false) }
            BrowserMobileVoiceSearchLanguages.remove(language, defaults: defaults)
            tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    // MARK: Private

    private enum Row {
        case keyboard
        case language(String)
        case add
    }

    private let defaults: UserDefaults

    private var languages: [String] { BrowserMobileVoiceSearchLanguages.list(defaults) }

    private func row(at indexPath: IndexPath) -> Row {
        let languages = languages
        if indexPath.row == 0 { return .keyboard }
        if indexPath.row <= languages.count { return .language(languages[indexPath.row - 1]) }
        return .add
    }
}

// MARK: - BrowserMobileAddLanguageViewController

/// Every language the speech recognizer knows, to search and add.
final class BrowserMobileAddLanguageViewController: UITableViewController, UISearchResultsUpdating {
    // MARK: Lifecycle

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(style: .insetGrouped)
        title = String(localized: "Add Language", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    /// The recognizer's languages by name, leaving out those already added.
    nonisolated static func choices(
        supported: Set<Locale>, added: [String], name: (String) -> String,
    ) -> [String] {
        Set(supported.map(\.identifier)).subtracting(added)
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    nonisolated static func matches(_ language: String, query: String, name: String, nativeName: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [name, nativeName, language].contains { $0.localizedStandardContains(query) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.addLanguage"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
        all = Self.choices(
            supported: SFSpeechRecognizer.supportedLocales(),
            added: BrowserMobileVoiceSearchLanguages.list(defaults),
            name: BrowserMobileVoiceSearchLanguages.name,
        )
        shown = all
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let language = shown[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = BrowserMobileVoiceSearchLanguages.name(language)
        content.secondaryText = BrowserMobileVoiceSearchLanguages.nativeName(language)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "browser.addLanguage.\(language)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        BrowserMobileVoiceSearchLanguages.add(shown[indexPath.row], defaults: defaults)
        navigationController?.popViewController(animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        shown = all.filter {
            Self.matches(
                $0, query: query, name: BrowserMobileVoiceSearchLanguages.name($0),
                nativeName: BrowserMobileVoiceSearchLanguages.nativeName($0),
            )
        }
        tableView.reloadData()
    }

    // MARK: Private

    private let defaults: UserDefaults
    private var all = [String]()
    private var shown = [String]()
}
