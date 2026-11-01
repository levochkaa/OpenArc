// BrowserNavigationListPanel.swift

import AppKit

// MARK: - BrowserNavigationListLayout

private enum BrowserNavigationListLayout {
    static let width: CGFloat = 221
    static let rowHeight: CGFloat = 40
    static let padding: CGFloat = 8
    static let arrowHeight: CGFloat = 6
    static let arrowWidth: CGFloat = 14
    static let cornerRadius: CGFloat = 12
    static let anchorGap: CGFloat = 10
    static let iconX: CGFloat = 16
    static let iconSize: CGFloat = 16
    static let titleX: CGFloat = 40
    static let maximumRows = 14
}

// MARK: - BrowserNavigationListPanel

/// The pages behind a back or forward button: a black card that points at the
/// button. It closes on a choice, a click anywhere else, Escape or the app leaving.
@MainActor final class BrowserNavigationListPanel: NSPanel {
    // MARK: Private

    private static var current: BrowserNavigationListPanel?

    // MARK: Internal

    override var canBecomeKey: Bool { false }

    private var monitors = [Any]()
    private var resignObserver: NSObjectProtocol?

    private init(entries: [BrowserNavigationEntry], arrowOffset: CGFloat, onChoose: @escaping (Int) -> Void) {
        let height = BrowserNavigationListLayout.padding * 2
            + CGFloat(entries.count) * BrowserNavigationListLayout.rowHeight
            + BrowserNavigationListLayout.arrowHeight
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BrowserNavigationListLayout.width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = BrowserNavigationListContentView(
            entries: entries,
            arrowOffset: arrowOffset,
            onChoose: { [weak self] offset in
                self?.dismiss()
                onChoose(offset)
            },
        )
    }

    static func show(
        entries: [BrowserNavigationEntry],
        below anchor: NSView,
        onChoose: @escaping (Int) -> Void,
    ) {
        current?.dismiss()
        guard let window = anchor.window, !entries.isEmpty else { return }
        let shown = Array(entries.prefix(BrowserNavigationListLayout.maximumRows))
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = BrowserNavigationListLayout.width
        let visible = window.screen?.visibleFrame ?? window.frame
        let x = min(max(frame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let panel = BrowserNavigationListPanel(entries: shown, arrowOffset: frame.midX - x, onChoose: onChoose)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.minY - BrowserNavigationListLayout.anchorGap))
        window.addChildWindow(panel, ordered: .above)
        panel.startDismissMonitors()
        current = panel
    }

    private func startDismissMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self, event.window !== self else { return event }
            dismiss()
            return event
        }) {
            monitors.append(local)
        }
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            dismiss()
            return nil
        }) {
            monitors.append(key)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(global)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self {
            Self.current = nil
        }
    }
}

// MARK: - BrowserNavigationListContentView

private final class BrowserNavigationListContentView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    private let shape = CAShapeLayer()

    init(entries: [BrowserNavigationEntry], arrowOffset: CGFloat, onChoose: @escaping (Int) -> Void) {
        let layout = BrowserNavigationListLayout.self
        let height = layout.padding * 2 + CGFloat(entries.count) * layout.rowHeight + layout.arrowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: height))
        wantsLayer = true
        shape.path = Self.bubble(
            size: bounds.size,
            arrowX: min(
                max(arrowOffset, layout.cornerRadius + layout.arrowWidth / 2),
                layout.width - layout.cornerRadius - layout.arrowWidth / 2,
            ),
        )
        shape.fillColor = NSColor.black.cgColor
        shape.frame = bounds
        layer?.addSublayer(shape)
        for (index, entry) in entries.enumerated() {
            let row = BrowserNavigationListRow(entry: entry) { onChoose(entry.offset) }
            row.frame = NSRect(
                x: 0,
                y: layout.arrowHeight + layout.padding + CGFloat(index) * layout.rowHeight,
                width: layout.width,
                height: layout.rowHeight,
            )
            addSubview(row)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func bubble(size: NSSize, arrowX: CGFloat) -> CGPath {
        let layout = BrowserNavigationListLayout.self
        let top = layout.arrowHeight
        let radius = layout.cornerRadius
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: top))
        path.addLine(to: CGPoint(x: arrowX - layout.arrowWidth / 2, y: top))
        path.addLine(to: CGPoint(x: arrowX, y: 0))
        path.addLine(to: CGPoint(x: arrowX + layout.arrowWidth / 2, y: top))
        path.addArc(
            tangent1End: CGPoint(x: size.width, y: top),
            tangent2End: CGPoint(x: size.width, y: size.height),
            radius: radius,
        )
        path.addArc(
            tangent1End: CGPoint(x: size.width, y: size.height),
            tangent2End: CGPoint(x: 0, y: size.height),
            radius: radius,
        )
        path.addArc(tangent1End: CGPoint(x: 0, y: size.height), tangent2End: CGPoint(x: 0, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 0, y: top), tangent2End: CGPoint(x: radius, y: top), radius: radius)
        path.closeSubpath()
        return path
    }
}

// MARK: - BrowserNavigationListRow

private final class BrowserNavigationListRow: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    private let onChoose: () -> Void
    private let hover = NSView()
    private let icon = BrowserFaviconNSView()
    private let title = NSTextField(labelWithString: "")

    init(entry: BrowserNavigationEntry, onChoose: @escaping () -> Void) {
        self.onChoose = onChoose
        super.init(frame: .zero)
        let layout = BrowserNavigationListLayout.self
        hover.wantsLayer = true
        hover.layer?.cornerRadius = 8
        hover.layer?.cornerCurve = .continuous
        hover.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        hover.isHidden = true
        addSubview(hover)
        icon.update(url: entry.faviconURL, pageURLString: entry.urlString)
        addSubview(icon)
        title.stringValue = entry.displayTitle
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        icon.frame = NSRect(
            x: layout.iconX,
            y: (layout.rowHeight - layout.iconSize) / 2,
            width: layout.iconSize,
            height: layout.iconSize,
        )
        title.frame = NSRect(
            x: layout.titleX,
            y: (layout.rowHeight - 18) / 2,
            width: layout.width - layout.titleX - layout.iconX,
            height: 18,
        )
        hover.frame = NSRect(
            x: layout.padding,
            y: 0,
            width: layout.width - layout.padding * 2,
            height: layout.rowHeight,
        )
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        ))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(entry.displayTitle)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with _: NSEvent) { hover.isHidden = false }
    override func mouseExited(with _: NSEvent) { hover.isHidden = true }
    override func mouseUp(with _: NSEvent) { onChoose() }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
