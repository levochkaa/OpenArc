import AppKit

/// Owns one native confirmation and resolves its continuation exactly once.
/// The engine bridge separately validates the browser identity and close nonce.
@objc(BrowserBeforeUnloadConfirmation)
@MainActor final class BrowserBeforeUnloadConfirmation: NSObject {
    // MARK: Lifecycle

    @objc(initWithWindow:completion:) convenience init(window: NSWindow?, completion: @escaping (Bool) -> Void) {
        self.init(window: window, presenter: { alert, parent, reply in
            alert.beginSheetModal(for: parent, completionHandler: reply)
        }, completion: completion)
    }

    init(window: NSWindow?, presenter: @escaping Presenter, completion: @escaping (Bool) -> Void) {
        self.window = window
        self.presenter = presenter
        self.completion = completion
        super.init()
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.beforeUnloadTitle
        alert.informativeText = BrowserStrings.beforeUnloadMessage
        alert.addButton(withTitle: BrowserStrings.beforeUnloadKeepTab).keyEquivalent = "\r"
        alert.addButton(withTitle: BrowserStrings.beforeUnloadCloseTab).keyEquivalent = ""
        alert.window.setAccessibilityIdentifier("browser.beforeUnload")
    }

    isolated deinit { removeKeyMonitor() }

    // MARK: Internal

    typealias Presenter = @MainActor (NSAlert, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void)
        -> Void

    let alert = NSAlert()

    @objc func present() {
        guard !didPresent, completion != nil else { return }
        didPresent = true
        // Never stack a destructive confirmation over another app sheet.
        guard let window, window.attachedSheet == nil else {
            finish(false)
            return
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) == true ? nil : event
        }
        presenter(alert, window) { [weak self] response in
            self?.finish(response == .alertSecondButtonReturn)
        }
    }

    @objc func cancel() {
        finish(false)
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
    }

    /// Used by the scoped native monitor; no application-wide Escape override.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard completion != nil, didPresent, event.type == .keyDown,
              event.window === alert.window, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        cancel()
        return true
    }

    // MARK: Private

    private weak var window: NSWindow?
    private let presenter: Presenter
    private var completion: ((Bool) -> Void)?
    private var didPresent = false
    private var keyMonitor: Any?

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func finish(_ confirmed: Bool) {
        guard let completion else { return }
        self.completion = nil
        removeKeyMonitor()
        completion(confirmed)
    }
}
