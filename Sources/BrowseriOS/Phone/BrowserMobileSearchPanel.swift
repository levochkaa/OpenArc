// BrowserMobileSearchPanel.swift

import UIKit

/// The search sheet that grows out of the bar for New Tab: a field over a
/// dark glass panel, with suggestions under it.
final class BrowserMobileSearchPanel: UIView, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    // MARK: Private

    private final class Cell: UITableViewCell {
        // MARK: Private

        private let icon = UIImageView()
        private let title = UILabel()
        private let subtitle = UILabel()
        private var item: BrowserMobileSearchSuggestions.Item?

        // MARK: Internal

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            let selected = UIView()
            selected.backgroundColor = UIColor(white: 1, alpha: 0.08)
            selectedBackgroundView = selected
            icon.contentMode = .scaleAspectFit
            icon.tintColor = .white
            icon.layer.cornerRadius = 4
            icon.layer.cornerCurve = .continuous
            icon.clipsToBounds = true
            title.font = .systemFont(ofSize: 17)
            title.textColor = .white
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = UIColor(white: 1, alpha: 0.5)
            for view in [icon, title, subtitle] as [UIView] {
                contentView.addSubview(view)
            }
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = contentView.bounds.height
            icon.frame = CGRect(x: 19, y: (height - 20) / 2, width: 20, height: 20)
            let x: CGFloat = 49
            let width = contentView.bounds.width - x - 16
            if subtitle.isHidden {
                title.frame = CGRect(x: x, y: 0, width: width, height: height)
            } else {
                title.frame = CGRect(x: x, y: height / 2 - 20, width: width, height: 21)
                subtitle.frame = CGRect(x: x, y: height / 2 + 2, width: width, height: 17)
            }
        }

        func show(_ item: BrowserMobileSearchSuggestions.Item) {
            self.item = item
            title.text = item.title
            subtitle.text = item.subtitle
            subtitle.isHidden = item.subtitle == nil
            accessibilityLabel = [item.title, item.subtitle].compactMap(\.self).joined(separator: ", ")
            reloadIcon()
            setNeedsLayout()
        }

        func reloadIcon() {
            guard let item else { return }
            if case .search = item.kind {
                icon.image = UIImage(systemName: "magnifyingglass")
                icon.layer.cornerRadius = 0
            } else if let image = BrowserMobileFavicons.shared.iconOnDark(forPage: item.iconPage) {
                icon.image = image
                icon.layer.cornerRadius = 4
            } else {
                icon.image = UIImage(systemName: "globe")
                icon.layer.cornerRadius = 0
            }
        }
    }

    // MARK: Internal

    static let margin: CGFloat = 16
    static let fieldTop: CGFloat = 17
    static let fieldHeight: CGFloat = 46
    static let rowHeight: CGFloat = 56

    let field = UITextField()
    var candidates = [BrowserMobileSearchSuggestions.Candidate]() {
        didSet { refresh(complete: false) }
    }

    var onSubmit: ((String) -> Void)?
    var onSelect: ((BrowserMobileSearchSuggestions.Item) -> Void)?

    private let fieldBackground = UIView()
    private let table = UITableView(frame: .zero, style: .plain)
    private var suggestions = BrowserMobileSearchSuggestions(query: "", candidates: [])
    private var isDeleting = false
    private var lastTypedLength = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.searchPanel"
        fieldBackground.backgroundColor = UIColor(white: 1, alpha: 0.1)
        fieldBackground.layer.cornerRadius = Self.fieldHeight / 2
        fieldBackground.layer.cornerCurve = .continuous
        fieldBackground.layer.borderWidth = 1 / 3
        fieldBackground.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        addSubview(fieldBackground)
        field.accessibilityIdentifier = "browser.searchField"
        field.accessibilityLabel = String(localized: "Address", table: "Mobile")
        field.attributedPlaceholder = NSAttributedString(
            string: String(localized: "Search…", table: "Mobile"),
            attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.45)],
        )
        field.font = .systemFont(ofSize: 19)
        field.textColor = .white
        field.tintColor = .white
        field.keyboardType = .webSearch
        field.keyboardAppearance = .dark
        field.returnKeyType = .go
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        fieldBackground.addSubview(field)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .none
        table.showsVerticalScrollIndicator = false
        table.register(Cell.self, forCellReuseIdentifier: "Suggestion")
        table.accessibilityIdentifier = "browser.searchSuggestions"
        addSubview(table)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fieldBackground.frame = CGRect(
            x: Self.margin, y: Self.fieldTop, width: bounds.width - Self.margin * 2, height: Self.fieldHeight,
        )
        field.frame = fieldBackground.bounds.insetBy(dx: 18, dy: 0)
        let tableTop = Self.fieldTop + Self.fieldHeight + 6
        table.frame = CGRect(x: 0, y: tableTop, width: bounds.width, height: max(bounds.height - tableTop, 0))
    }

    func begin(text: String) {
        field.text = text
        lastTypedLength = text.count
        refresh(complete: false)
        field.becomeFirstResponder()
        if !text.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.field.selectAll(nil) }
        }
    }

    func textField(_: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        isDeleting = string.isEmpty && range.length > 0
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.markedTextRange == nil else { return false }
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        onSubmit?(text)
        return true
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { suggestions.items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Suggestion", for: indexPath) as! Cell
        cell.show(suggestions.items[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onSelect?(suggestions.items[indexPath.row])
    }

    func reloadIcons() {
        for cell in table.visibleCells.compactMap({ $0 as? Cell }) {
            cell.reloadIcon()
        }
    }

    @objc private func textChanged() {
        refresh(complete: !isDeleting)
        isDeleting = false
    }

    /// Lists suggestions for the typed text; while typing forward it also fills
    /// in the rest of a known host and selects that part, so the next keystroke
    /// replaces it.
    private func refresh(complete: Bool) {
        var typed = field.text ?? ""
        if let selection = field.selectedTextRange, !selection.isEmpty, field.markedTextRange == nil {
            typed = field.text(in: field.textRange(from: field.beginningOfDocument, to: selection.start)!) ?? typed
        }
        suggestions = BrowserMobileSearchSuggestions(query: typed, candidates: candidates)
        table.reloadData()
        guard complete, field.markedTextRange == nil, let completion = suggestions.completion,
              completion.hasPrefix(typed.lowercased()), !typed.isEmpty else { return }
        field.text = typed + completion.dropFirst(typed.count)
        if let start = field.position(from: field.beginningOfDocument, offset: typed.count) {
            field.selectedTextRange = field.textRange(from: start, to: field.endOfDocument)
        }
    }
}
