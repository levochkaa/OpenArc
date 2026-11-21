// BrowserMobileSearchPanel.swift

import UIKit

/// The search sheet that grows out of the bar for New Tab: a field over a
/// dark glass panel, with suggestions under it. The field starts as the
/// bar's New Tab capsule and widens once the panel is up. At the field's end,
/// the microphone dictates into it and the eyes turn Incognito on.
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
    /// The eyes' center, from the field's trailing edge.
    static let eyesInset: CGFloat = 29
    /// The distance between the microphone's and the eyes' centers.
    static let accessorySpacing: CGFloat = 44

    let field = BrowserMobileCompletingField()
    var candidates = [BrowserMobileSearchSuggestions.Candidate]() {
        didSet { refresh(complete: false) }
    }

    var onSubmit: ((String) -> Void)?
    var onSelect: ((BrowserMobileSearchSuggestions.Item) -> Void)?
    /// The eyes were tapped; the new value is already shown.
    var onIncognitoChange: ((Bool) -> Void)?

    /// Pages open in private tabs; the suggestions give way to a note.
    var isIncognito = false {
        didSet {
            guard isIncognito != oldValue else { return }
            if isIncognito { dictation.stop() }
            updateAccessories()
        }
    }

    /// Whether the field is full width, or still the bar's New Tab capsule.
    private(set) var isFieldExpanded = true

    private let fieldBackground = UIView()
    private let plusGlyph = UIImageView(image: UIImage(
        systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
    ))
    private let table = UITableView(frame: .zero, style: .plain)
    private var suggestions = BrowserMobileSearchSuggestions(query: "", candidates: [])
    /// The microphone and the eyes, which fade in with the field.
    private let accessories = UIView()
    private let micButton = UIButton(type: .system)
    private let eyesButton = UIButton(type: .system)
    private let incognitoLabel = UILabel()
    private let incognitoNote = UILabel()
    private let dictation = BrowserMobileDictation()
    /// The text before dictation started; what is heard goes after it.
    private var dictationPrefix = ""

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
        field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        fieldBackground.addSubview(field)
        plusGlyph.tintColor = .white
        plusGlyph.contentMode = .center
        plusGlyph.alpha = 0
        fieldBackground.addSubview(plusGlyph)
        configureAccessories()
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
        incognitoNote.text = String(localized: "You’re browsing Incognito", table: "Mobile")
        incognitoNote.font = .systemFont(ofSize: 20, weight: .medium)
        incognitoNote.textColor = UIColor(white: 1, alpha: 0.5)
        incognitoNote.textAlignment = .center
        incognitoNote.accessibilityIdentifier = "browser.searchIncognitoNote"
        addSubview(incognitoNote)
        updateAccessories()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stopDictation), name: UIApplication.didEnterBackgroundNotification, object: nil,
        )
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let full = CGRect(
            x: Self.margin, y: Self.fieldTop, width: bounds.width - Self.margin * 2, height: Self.fieldHeight,
        )
        let capsule = CGRect(
            x: (bounds.width - BrowserMobilePhoneBarView.plusWidth) / 2, y: BrowserMobilePhoneBarView.controlTopInset,
            width: BrowserMobilePhoneBarView.plusWidth, height: BrowserMobilePhoneBarView.controlHeight,
        )
        let frame = isFieldExpanded ? full : capsule
        fieldBackground.frame = frame
        fieldBackground.layer.cornerRadius = frame.height / 2
        // The text and the icons at its end keep the full width, so they do
        // not reflow while the capsule widens; the capsule clips them.
        accessories.frame = CGRect(x: 0, y: 0, width: full.width, height: frame.height)
        let eyesX = full.width - Self.eyesInset
        eyesButton.frame = CGRect(x: eyesX - 22, y: (frame.height - 44) / 2, width: 44, height: 44)
        micButton.frame = eyesButton.frame.offsetBy(dx: -Self.accessorySpacing, dy: 0)
        incognitoLabel.sizeToFit()
        incognitoLabel.frame = CGRect(
            x: eyesX - 12 - 8 - incognitoLabel.bounds.width, y: (frame.height - incognitoLabel.bounds.height) / 2,
            width: incognitoLabel.bounds.width, height: incognitoLabel.bounds.height,
        )
        let fieldEnd = isIncognito ? incognitoLabel.frame.minX - 6 : micButton.frame.minX + 4
        field.frame = CGRect(x: 24, y: 0, width: max(fieldEnd - 24, 0), height: frame.height)
        let glyphSide = BrowserMobilePhoneBarView.controlHeight
        plusGlyph.frame = CGRect(
            x: isFieldExpanded ? 4 : (frame.width - glyphSide) / 2, y: (frame.height - glyphSide) / 2,
            width: glyphSide, height: glyphSide,
        )
        let tableTop = frame.maxY + 6
        table.frame = CGRect(x: 0, y: tableTop, width: bounds.width, height: max(bounds.height - tableTop, 0))
        incognitoNote.frame = table.frame.insetBy(dx: Self.margin, dy: 0)
    }

    /// Lays the field out as the full-width field or as the New Tab capsule;
    /// call it inside an animation to morph between them.
    func setFieldExpanded(_ expanded: Bool) {
        isFieldExpanded = expanded
        fieldBackground.clipsToBounds = true
        setNeedsLayout()
        layoutIfNeeded()
        // The plus fades as the capsule starts to widen and the placeholder
        // comes in after it, so the two do not overlap.
        let inAnimation = UIView.inheritedAnimationDuration > 0
        guard inAnimation else {
            field.alpha = expanded ? 1 : 0
            accessories.alpha = field.alpha
            plusGlyph.alpha = expanded ? 0 : 1
            return
        }
        UIView.animate(withDuration: expanded ? 0.12 : 0.2, delay: expanded ? 0 : 0.08, options: [
            .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve,
        ]) {
            self.plusGlyph.alpha = expanded ? 0 : 1
        }
        UIView.animate(withDuration: expanded ? 0.2 : 0.1, delay: expanded ? 0.08 : 0, options: [
            .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve,
        ]) {
            self.field.alpha = expanded ? 1 : 0
            self.accessories.alpha = self.field.alpha
        }
    }

    /// Whether a downward drag at `point` should move the panel rather than
    /// scroll the suggestions.
    func dragMovesPanel(at point: CGPoint, downward: Bool) -> Bool {
        guard table.frame.contains(point) else { return true }
        return downward && table.contentOffset.y <= -table.adjustedContentInset.top + 1
    }

    /// Fills the field and the suggestions without focusing it.
    func prepare(text: String) {
        field.replaceText(text)
        refresh(complete: false)
    }

    /// Stops dictation, leaving what was heard in the field.
    @objc func stopDictation() {
        dictation.stop()
    }

    func focus() {
        field.becomeFirstResponder()
        if field.text?.isEmpty == false {
            DispatchQueue.main.async { [weak self] in self?.field.selectAll(nil) }
        }
    }

    func textFieldShouldClear(_: UITextField) -> Bool {
        field.replaceText(field.text ?? "")
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.markedTextRange == nil else { return false }
        field.keepCompletion()
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        dictation.stop()
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

    private func configureAccessories() {
        accessories.alpha = 0
        fieldBackground.addSubview(accessories)
        for button in [micButton, eyesButton] {
            button.tintColor = UIColor(white: 1, alpha: 0.55)
            accessories.addSubview(button)
        }
        micButton.accessibilityIdentifier = "browser.searchDictation"
        micButton.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .touchUpInside)
        eyesButton.accessibilityIdentifier = "browser.searchIncognito"
        eyesButton.accessibilityLabel = String(localized: "Incognito", table: "Mobile")
        eyesButton.addAction(UIAction { [weak self] _ in self?.toggleIncognito() }, for: .touchUpInside)
        incognitoLabel.text = String(localized: "Incognito", table: "Mobile")
        incognitoLabel.font = .systemFont(ofSize: 13)
        incognitoLabel.textColor = UIColor(white: 1, alpha: 0.55)
        incognitoLabel.isAccessibilityElement = false
        accessories.addSubview(incognitoLabel)
        dictation.onListeningChange = { [weak self] _ in self?.updateAccessories() }
        dictation.onText = { [weak self] text in
            guard let self else { return }
            field.replaceText(dictationPrefix + text)
            refresh(complete: false)
        }
    }

    private func updateAccessories() {
        let symbol = { (name: String) in
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        }
        let listening = dictation.isListening
        micButton.setImage(symbol(listening ? "mic.fill" : "mic"), for: .normal)
        micButton.tintColor = listening ? .systemRed : UIColor(white: 1, alpha: 0.55)
        micButton.accessibilityLabel = listening
            ? String(localized: "Stop Dictation", table: "Mobile")
            : String(localized: "Dictate", table: "Mobile")
        micButton.isHidden = isIncognito
        eyesButton.setImage(symbol(isIncognito ? "eyes.inverse" : "eyes"), for: .normal)
        eyesButton.tintColor = UIColor(white: 1, alpha: isIncognito ? 0.9 : 0.55)
        eyesButton.accessibilityTraits = isIncognito ? [.button, .selected] : .button
        incognitoLabel.isHidden = !isIncognito
        table.isHidden = isIncognito
        incognitoNote.isHidden = !isIncognito
        setNeedsLayout()
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        field.keepCompletion()
        let typed = field.text ?? ""
        dictationPrefix = typed.isEmpty || typed.hasSuffix(" ") ? typed : typed + " "
        dictation.start(language: field.textInputMode?.primaryLanguage)
    }

    private func toggleIncognito() {
        isIncognito.toggle()
        onIncognitoChange?(isIncognito)
    }

    @objc private func textChanged() {
        refresh(complete: !field.lastEditDeleted)
    }

    /// Lists suggestions for the typed text; while typing forward it also fills
    /// in the rest of a known host, which the next keystroke replaces.
    private func refresh(complete: Bool) {
        let typed = field.typedText
        suggestions = BrowserMobileSearchSuggestions(query: typed, candidates: candidates)
        table.reloadData()
        guard complete, field.markedTextRange == nil, let completion = suggestions.completion,
              completion.hasPrefix(typed.lowercased()), !typed.isEmpty else { return }
        field.showCompletion(String(completion.dropFirst(typed.count)), after: typed)
    }
}
