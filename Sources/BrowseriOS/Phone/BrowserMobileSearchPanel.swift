// BrowserMobileSearchPanel.swift

import UIKit

/// The search sheet that grows out of the bar for New Tab: a field over a
/// dark glass panel, with suggestions under it. The field starts as the
/// bar's New Tab capsule and widens once the panel is up. At the field's end,
/// the microphone dictates into it and the eyes turn Incognito on; once
/// there is text, a clear button takes their place.
final class BrowserMobileSearchPanel: UIView, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate,
    UIGestureRecognizerDelegate
{
    // MARK: Private

    /// A pressed row lights a rounded plate inset from the panel's edges,
    /// about as wide as the field, not the whole row.
    private final class PressedBackground: UIView {
        // MARK: Private

        private let plate = UIView()

        // MARK: Internal

        override init(frame: CGRect) {
            super.init(frame: frame)
            plate.backgroundColor = UIColor(white: 1, alpha: 0.11)
            plate.layer.cornerRadius = 12
            plate.layer.cornerCurve = .continuous
            addSubview(plate)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            plate.frame = bounds.insetBy(dx: 10, dy: 2)
        }
    }

    /// Lays the buttons over the field's end; a touch between them reaches the field.
    private final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

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
            selectedBackgroundView = PressedBackground()
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

        /// A suggested search that goes on from the typed text shows that
        /// text dimmed.
        func show(_ item: BrowserMobileSearchSuggestions.Item, typed: String) {
            self.item = item
            if case .search = item.kind, !typed.isEmpty, item.title.count > typed.count,
               item.title.lowercased().hasPrefix(typed.lowercased())
            {
                let text = NSMutableAttributedString(string: item.title)
                let end = item.title.index(item.title.startIndex, offsetBy: typed.count)
                text.addAttribute(
                    .foregroundColor, value: UIColor(white: 1, alpha: 0.5),
                    range: NSRange(item.title.startIndex..<end, in: item.title),
                )
                title.attributedText = text
            } else {
                title.text = item.title
            }
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
    /// A tab's row was asked to leave the suggestions.
    var onRemove: ((BrowserMobileSearchSuggestions.Item) -> Void)?
    /// The eyes were tapped; the new value is already shown.
    var onIncognitoChange: ((Bool) -> Void)?

    /// Pages open in private tabs; the suggestions give way to a note.
    var isIncognito = false {
        didSet {
            guard isIncognito != oldValue else { return }
            if isIncognito { dictation.stop() }
            updateAccessories(animated: window != nil)
            refresh(complete: false)
        }
    }

    /// Whether the field is full width, or still the bar's New Tab capsule.
    private(set) var isFieldExpanded = true

    private let fieldBackground = UIView()
    private let plusGlyph = UIImageView(image: UIImage(
        systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
    ))
    private let table = UITableView(frame: .zero, style: .plain)
    private let holdGesture = UILongPressGestureRecognizer()
    private var suggestions = BrowserMobileSearchSuggestions(query: "", candidates: [])
    /// The microphone and the eyes, which fade in with the field.
    private let accessories = PassThroughView()
    private let micButton = UIButton(type: .system)
    private let eyesButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    /// Clips the Incognito label, which slides out from under the eyes.
    private let incognitoClip = UIView()
    private let incognitoLabel = UILabel()
    private let incognitoNote = UILabel()
    /// Darkens the panel while Incognito is on.
    private let incognitoShade = UIView()
    private let webSuggestions = BrowserMobileWebSuggestions()
    /// What the accessories show now, to animate only what changes.
    private var shownIncognito: Bool?
    private var shownText: Bool?
    private let dictation = BrowserMobileDictation()
    /// The text before dictation started; what is heard goes after it.
    private var dictationPrefix = ""

    /// A finger is on the suggestions, so the keyboard may be following it.
    var isDraggingSuggestions: Bool { table.isTracking }

    private var hasText: Bool { field.text?.isEmpty == false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.searchPanel"
        incognitoShade.backgroundColor = UIColor(white: 0, alpha: 0.57)
        incognitoShade.alpha = 0
        incognitoShade.isUserInteractionEnabled = false
        addSubview(incognitoShade)
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
            attributes: [
                .foregroundColor: UIColor(white: 1, alpha: 0.45),
                .font: UIFont.systemFont(ofSize: 19, weight: .semibold),
            ],
        )
        field.font = .systemFont(ofSize: 19)
        field.textColor = .white
        // A blue caret, as on the system's own fields over dark glass.
        field.tintColor = UIColor(red: 114 / 255, green: 135 / 255, blue: 242 / 255, alpha: 1)
        field.keyboardType = .webSearch
        field.keyboardAppearance = .dark
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .never
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
        // A drag down the suggestions takes the keyboard with it.
        table.keyboardDismissMode = .interactive
        table.alwaysBounceVertical = true
        table.showsVerticalScrollIndicator = false
        table.register(Cell.self, forCellReuseIdentifier: "Suggestion")
        table.accessibilityIdentifier = "browser.searchSuggestions"
        addSubview(table)
        // Holding a suggested search puts it in the field to go on typing.
        holdGesture.addTarget(self, action: #selector(heldSuggestion(_:)))
        holdGesture.delegate = self
        table.addGestureRecognizer(holdGesture)
        incognitoNote.text = String(localized: "You’re browsing Incognito", table: "Mobile")
        incognitoNote.font = .systemFont(ofSize: 20, weight: .medium)
        incognitoNote.textColor = UIColor(white: 1, alpha: 0.5)
        incognitoNote.textAlignment = .center
        incognitoNote.accessibilityIdentifier = "browser.searchIncognitoNote"
        addSubview(incognitoNote)
        updateAccessories(animated: false)
        webSuggestions.onChange = { [weak self] in self?.refresh(complete: false, asks: false) }
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
        clearButton.frame = eyesButton.frame
        // The label hides under the eyes' left edge and slides out of it.
        let clipEnd = eyesX - 12
        incognitoClip.frame = CGRect(x: 0, y: 0, width: max(clipEnd, 0), height: frame.height)
        incognitoLabel.sizeToFit()
        let labelSize = incognitoLabel.bounds.size
        let labelShownX = clipEnd - 8 - labelSize.width
        incognitoLabel.frame = CGRect(
            x: isIncognito ? labelShownX : clipEnd, y: (frame.height - labelSize.height) / 2,
            width: labelSize.width, height: labelSize.height,
        )
        let fieldEnd = hasText
            ? clearButton.frame.minX + 4
            : isIncognito ? labelShownX - 6 : micButton.frame.minX + 4
        field.frame = CGRect(x: 24, y: 0, width: max(fieldEnd - 24, 0), height: frame.height)
        let glyphSide = BrowserMobilePhoneBarView.controlHeight
        plusGlyph.frame = CGRect(
            x: isFieldExpanded ? 4 : (frame.width - glyphSide) / 2, y: (frame.height - glyphSide) / 2,
            width: glyphSide, height: glyphSide,
        )
        let tableTop = frame.maxY + 6
        table.frame = CGRect(x: 0, y: tableTop, width: bounds.width, height: max(bounds.height - tableTop, 0))
        incognitoNote.frame = table.frame.insetBy(dx: Self.margin, dy: 0)
        incognitoShade.frame = bounds
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // Only on a suggested search, so the tabs' rows keep their menu.
        guard gesture === holdGesture else { return super.gestureRecognizerShouldBegin(gesture) }
        return fillableSearch(at: gesture.location(in: table)) != nil
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
        // With the keyboard up the suggestions take the drag, so it can pull the keyboard down.
        guard !field.isFirstResponder else { return false }
        return downward && table.contentOffset.y <= -table.adjustedContentInset.top + 1
    }

    /// Fills the field and the suggestions without focusing it.
    func prepare(text: String) {
        field.replaceText(text)
        refresh(complete: false)
        updateAccessories(animated: false)
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

    func textFieldDidChangeSelection(_: UITextField) {
        field.noteSelectionChange()
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
        cell.show(
            suggestions.items[indexPath.row], typed: field.typedText.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onSelect?(suggestions.items[indexPath.row])
    }

    func tableView(
        _: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard suggestions.items.indices.contains(indexPath.row) else { return nil }
        let item = suggestions.items[indexPath.row]
        guard case .tab = item.kind else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: item.iconPage ?? "", children: [
                UIAction(
                    title: String(localized: "Remove Suggestion", table: "Mobile"), image: UIImage(systemName: "trash"),
                ) { _ in
                    self?.onRemove?(item)
                },
            ])
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    func reloadIcons() {
        for cell in table.visibleCells.compactMap({ $0 as? Cell }) {
            cell.reloadIcon()
        }
    }

    /// Starts listening, as the microphone button does.
    func startDictation() {
        guard !dictation.isListening else { return }
        toggleDictation()
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
        incognitoClip.clipsToBounds = true
        incognitoClip.isUserInteractionEnabled = false
        incognitoClip.addSubview(incognitoLabel)
        accessories.addSubview(incognitoClip)
        clearButton.setImage(UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular),
        ), for: .normal)
        clearButton.tintColor = UIColor(white: 1, alpha: 0.75)
        clearButton.accessibilityIdentifier = "browser.searchClear"
        clearButton.accessibilityLabel = String(localized: "Clear text", table: "Mobile")
        clearButton.addAction(UIAction { [weak self] _ in self?.clearText() }, for: .touchUpInside)
        accessories.addSubview(clearButton)
        dictation.onListeningChange = { [weak self] _ in self?.updateAccessories(animated: false) }
        dictation.onText = { [weak self] text in
            guard let self else { return }
            field.replaceText(dictationPrefix + text)
            refresh(complete: false)
            updateAccessories(animated: true)
        }
    }

    /// Shows the microphone and the eyes, or the clear button once there is
    /// text; with Incognito on, the eyes fill, the label slides out from under
    /// them, the microphone goes and the panel darkens.
    private func updateAccessories(animated: Bool) {
        let symbol = { (name: String) in
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        }
        let listening = dictation.isListening
        micButton.setImage(symbol(listening ? "mic.fill" : "mic"), for: .normal)
        micButton.tintColor = listening ? .systemRed : UIColor(white: 1, alpha: 0.55)
        micButton.accessibilityLabel = listening
            ? String(localized: "Stop Dictation", table: "Mobile")
            : String(localized: "Dictate", table: "Mobile")
        eyesButton.accessibilityTraits = isIncognito ? [.button, .selected] : .button
        let incognito = isIncognito
        let text = hasText
        let incognitoChanged = shownIncognito != nil && shownIncognito != incognito
        let textChanged = shownText != nil && shownText != text
        let eyes = symbol(incognito ? "eyes" : "eyes.inverse")
        if animated, incognitoChanged {
            UIView.transition(
                with: eyesButton,
                duration: 0.12,
                options: [.transitionCrossDissolve, .allowUserInteraction],
            ) {
                self.eyesButton.setImage(eyes, for: .normal)
                self.eyesButton.tintColor = UIColor(white: 1, alpha: incognito ? 0.9 : 0.55)
            }
        } else {
            eyesButton.setImage(eyes, for: .normal)
            eyesButton.tintColor = UIColor(white: 1, alpha: incognito ? 0.9 : 0.55)
        }
        shownIncognito = incognito
        shownText = text
        let controls = {
            self.micButton.alpha = incognito || text ? 0 : 1
            self.eyesButton.alpha = text ? 0 : 1
            self.incognitoClip.alpha = text ? 0 : 1
            self.clearButton.alpha = text ? 1 : 0
        }
        let mood = {
            self.incognitoShade.alpha = incognito ? 1 : 0
            self.fieldBackground.backgroundColor = UIColor(white: 1, alpha: incognito ? 0.13 : 0.1)
            self.table.alpha = incognito ? 0 : 1
            self.incognitoNote.alpha = incognito ? 1 : 0
        }
        micButton.isUserInteractionEnabled = !incognito && !text
        eyesButton.isUserInteractionEnabled = !text
        clearButton.isUserInteractionEnabled = text
        table.isUserInteractionEnabled = !incognito
        incognitoNote.isHidden = false
        setNeedsLayout()
        guard animated, incognitoChanged || textChanged else {
            controls()
            mood()
            layoutIfNeeded()
            return
        }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if incognitoChanged, incognito {
            // The microphone goes at once while the label slides out and the
            // panel darkens.
            UIView.animate(withDuration: 0.1, delay: 0, options: options.union(.curveLinear), animations: controls)
            UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0, options: options) {
                self.layoutIfNeeded()
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: options.union(.curveEaseOut), animations: mood)
        } else if incognitoChanged {
            // The label slides back under the eyes before the microphone returns.
            UIView.animate(withDuration: 0.2, delay: 0, options: options.union(.curveEaseInOut)) {
                self.layoutIfNeeded()
            }
            UIView.animate(withDuration: 0.1, delay: 0.18, options: options.union(.curveLinear), animations: controls)
            UIView.animate(withDuration: 0.22, delay: 0, options: options.union(.curveEaseOut), animations: mood)
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: options.union(.curveEaseOut)) {
                controls()
                self.layoutIfNeeded()
            }
        }
    }

    /// The suggested search, other than the typed text, in the row at `point`.
    private func fillableSearch(at point: CGPoint) -> String? {
        guard let indexPath = table.indexPathForRow(at: point), suggestions.items.indices.contains(indexPath.row),
              case .search(let text) = suggestions.items[indexPath.row].kind,
              text != field.typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return text
    }

    @objc private func heldSuggestion(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let text = fillableSearch(at: gesture.location(in: table)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dictation.stop()
        field.replaceText(text)
        refresh(complete: false)
        updateAccessories(animated: true)
    }

    private func clearText() {
        dictation.stop()
        field.replaceText("")
        refresh(complete: false)
        updateAccessories(animated: true)
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        field.keepCompletion()
        let typed = field.text ?? ""
        dictationPrefix = typed.isEmpty || typed.hasSuffix(" ") ? typed : typed + " "
        dictation
            .start(language: BrowserMobileVoiceSearchLanguages.language(keyboard: field.textInputMode?.primaryLanguage))
    }

    private func toggleIncognito() {
        isIncognito.toggle()
        onIncognitoChange?(isIncognito)
    }

    @objc private func textChanged() {
        field.noteEdit()
        refresh(complete: !field.lastEditDeleted)
        updateAccessories(animated: true)
    }

    /// Lists suggestions for the typed text; while typing forward at the end
    /// it also fills in the rest of a known host, which the next keystroke
    /// replaces. An edit in the middle fills nothing in, so the caret stays.
    private func refresh(complete: Bool, asks: Bool = true) {
        let typed = field.typedText
        // Private browsing and other search engines send nothing out.
        let asksWeb = !isIncognito && BrowserMobileSearchEngineSetting.current() == .google
        if asks { webSuggestions.request(asksWeb ? typed : nil) }
        suggestions = BrowserMobileSearchSuggestions(
            query: typed, candidates: candidates,
            searches: asksWeb
                ? webSuggestions.suggestions(for: typed.trimmingCharacters(in: .whitespacesAndNewlines))
                : [],
        )
        table.reloadData()
        let fill = suggestions.completion.flatMap { completion in
            completion.hasPrefix(typed.lowercased()) && !typed.isEmpty && field.markedTextRange == nil
                ? String(completion.dropFirst(typed.count))
                : nil
        }
        if complete, field.isTypingAtEnd, let fill {
            field.showCompletion(fill, after: typed)
        } else if field.completion != nil, field.completion != fill {
            // What shows no longer completes the typed text.
            field.dropCompletion()
        }
    }
}
