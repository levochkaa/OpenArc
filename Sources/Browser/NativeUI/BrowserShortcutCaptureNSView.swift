import AppKit

// MARK: - BrowserShortcutCaptureNSView

/// The app's key monitor routes events here before evaluating browser shortcuts.
final class BrowserShortcutCaptureNSView: BrowserNativeSurface {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        strokeColor = .controlAccentColor
        cornerRadius = 6
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel(BrowserStrings.settingsShortcutPressShortcut)
        setAccessibilityIdentifier("browser.settings.shortcut-capture")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var acceptsFirstResponder: Bool { true }

    var onCapture: ((BrowserKeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        Self.activeCapture = self
        return true
    }

    override func resignFirstResponder() -> Bool {
        if Self.activeCapture === self {
            Self.activeCapture = nil
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, Self.activeCapture === self {
            Self.activeCapture = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard let shortcut = BrowserKeyboardShortcut(recordedEvent: event) else { NSSound.beep()
            return
        }
        onCapture?(shortcut)
    }

    static func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard let capture = activeCapture, let window = capture.window,
              (event.window ?? NSApp.keyWindow) === window,
              window.firstResponder === capture else { return false }
        capture.keyDown(with: event)
        return true
    }

    // MARK: Private

    private weak static var activeCapture: BrowserShortcutCaptureNSView?

    private let label = BrowserNativeControls.label(
        BrowserStrings.settingsShortcutPressShortcut,
        size: 12,
        color: .secondaryLabelColor
    )
}

extension BrowserKeyboardShortcut {
    init?(recordedEvent event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let firstCharacter = characters.first,
              String(firstCharacter).rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.init(String(firstCharacter), modifiers: modifiers)
    }
}
