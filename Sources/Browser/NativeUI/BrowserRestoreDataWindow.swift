// BrowserRestoreDataWindow.swift

import AppKit

// MARK: - BrowserRestoreDataWindow

/// Help > Restore Data: go back to a dated copy of the sidebar and tabs.
@MainActor final class BrowserRestoreDataWindow: NSObject {
    // MARK: Private

    private let snapshots: BrowserSessionSnapshots
    private let relaunch: () -> Void
    private let onClose: () -> Void
    private var window: NSWindow?
    private let dates = NSPopUpButton()
    private var files = [URL]()

    // MARK: Internal

    init(snapshots: BrowserSessionSnapshots, relaunch: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.snapshots = snapshots
        self.relaunch = relaunch
        self.onClose = onClose
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = BrowserStrings.menuRestoreData
        window.isReleasedWhenClosed = false
        window.delegate = self
        files = snapshots.snapshots()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for file in files {
            dates.addItem(withTitle: snapshots.date(of: file).map(formatter.string(from:)) ?? file.lastPathComponent)
        }
        dates.isEnabled = !files.isEmpty
        let restore = NSButton(
            title: BrowserStrings.restoreDataRestore,
            target: self,
            action: #selector(restorePressed),
        )
        restore.isEnabled = !files.isEmpty
        let note = NSTextField(wrappingLabelWithString: files.isEmpty
            ? BrowserStrings.restoreDataNone
            : BrowserStrings.restoreDataNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [dates, note, restore])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 360, height: stack.fittingSize.height))
        window.center()
        return window
    }

    @objc private func restorePressed() {
        guard dates.indexOfSelectedItem >= 0, dates.indexOfSelectedItem < files.count, let window else { return }
        let file = files[dates.indexOfSelectedItem]
        let alert = NSAlert()
        alert.messageText = String(format: BrowserStrings.restoreDataConfirm, dates.titleOfSelectedItem ?? "")
        alert.informativeText = BrowserStrings.restoreDataConfirmDetail
        alert.addButton(withTitle: BrowserStrings.restoreDataRestart)
        alert.addButton(withTitle: BrowserStrings.javaScriptDialogCancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try snapshots.scheduleRestore(of: file)
                relaunch()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

// MARK: NSWindowDelegate

extension BrowserRestoreDataWindow: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        window?.delegate = nil
        onClose()
    }
}
