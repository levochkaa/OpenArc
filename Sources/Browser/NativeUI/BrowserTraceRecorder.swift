// BrowserTraceRecorder.swift

import AppKit

// MARK: - BrowserTraceRecorder

/// Help > Troubleshooting > Record Trace: a Chromium trace of the next few seconds, with a note, in Downloads.
/// OpenArc has no team server, so a trace stays on the Mac.
@MainActor final class BrowserTraceRecorder: NSObject {
    // MARK: Private

    private let beginTrace: () -> Bool
    private let endTrace: (String, @escaping () -> Void) -> Bool
    private let onClose: () -> Void
    private var window: NSWindow?
    private let duration = NSPopUpButton()
    private let issue = NSTextView()
    private let start = NSButton()
    private let seconds = [5, 15, 30, 60]

    /// The engine's two calls, from the app's bridge.
    init(
        beginTrace: @escaping () -> Bool,
        endTrace: @escaping (String, @escaping () -> Void) -> Bool,
        onClose: @escaping () -> Void,
    ) {
        self.beginTrace = beginTrace
        self.endTrace = endTrace
        self.onClose = onClose
        super.init()
    }

    // MARK: Internal

    nonisolated static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "OpenArc Trace \(formatter.string(from: date))"
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = BrowserStrings.menuRecordTrace.replacingOccurrences(of: "…", with: "")
        window.isReleasedWhenClosed = false
        window.delegate = self

        for value in seconds {
            duration.addItem(withTitle: String(format: BrowserStrings.traceSeconds, value))
        }
        duration.selectItem(at: 1)

        issue.font = .systemFont(ofSize: 13)
        issue.isRichText = false
        let scroll = NSScrollView()
        scroll.documentView = issue
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        issue.autoresizingMask = [.width]
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let note = NSTextField(wrappingLabelWithString: BrowserStrings.traceNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320

        start.title = BrowserStrings.traceStart
        start.bezelStyle = .push
        start.keyEquivalent = "\r"
        start.target = self
        start.action = #selector(startPressed)
        let footer = NSStackView(views: [NSView(), start])
        footer.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let stack = NSStackView(views: [
            NSTextField(labelWithString: BrowserStrings.traceDuration),
            duration,
            NSTextField(labelWithString: BrowserStrings.traceIssue),
            scroll,
            note,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(stack.fittingSize)
        window.center()
        return window
    }

    @objc private func startPressed() {
        guard beginTrace() else {
            NSSound.beep()
            return
        }
        start.isEnabled = false
        start.title = BrowserStrings.traceRecording
        duration.isEnabled = false
        issue.isEditable = false
        let length = TimeInterval(seconds[duration.indexOfSelectedItem])
        let note = issue.string
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self] in
            self?.finish(note: note)
        }
    }

    private func finish(note: String) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        let name = Self.fileName(at: Date())
        let trace = downloads.appendingPathComponent(name).appendingPathExtension("json")
        if !note.isEmpty {
            try? note.write(
                to: downloads.appendingPathComponent(name).appendingPathExtension("txt"),
                atomically: true,
                encoding: .utf8,
            )
        }
        let didEnd = endTrace(trace.path) { [weak self] in
            MainActor.assumeIsolated {
                NSWorkspace.shared.activateFileViewerSelecting([trace])
                self?.window?.close()
            }
        }
        if !didEnd {
            window?.close()
        }
    }
}

// MARK: NSWindowDelegate

extension BrowserTraceRecorder: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        window?.delegate = nil
        onClose()
    }
}
