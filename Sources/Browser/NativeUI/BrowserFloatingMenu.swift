// BrowserFloatingMenu.swift

import AppKit

// MARK: - BrowserFloatingMenuItem

enum BrowserFloatingMenuItem {
    case action(symbol: String, title: String, shortcut: String?, isEnabled: Bool, identifier: String, run: () -> Void)
    case separator
}

// MARK: - BrowserFloatingMenu

/// A dark menu with large rows that rises from a chrome button, its tail on the
/// button. It closes on a choice, an outside click or Escape.
@MainActor final class BrowserFloatingMenu {
    // MARK: Internal

    var onClose: () -> Void = {}

    // MARK: Private

    private var panel: NSPanel?
    private var monitor: Any?

    var isShown: Bool { panel != nil }

    func show(items: [BrowserFloatingMenuItem], above anchor: NSView) {
        close()
        guard let parent = anchor.window else { return }
        let content = BrowserFloatingMenuView(items: items) { [weak self] in self?.close() }
        let size = content.fittingSize
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // The tail points at the button's center and the body stays on screen.
        let leadingLimit = parent.frame.minX + 4
        let x = max(anchorRect.midX - size.width + 30, leadingLimit)
        let frame = NSRect(x: x, y: anchorRect.maxY + 1, width: size.width, height: size.height)
        content.tailX = anchorRect.midX - x
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = parent.level
        panel.contentView = content
        panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
            panel.animator().alphaValue = 1
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
            .keyDown,
        ]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            if event.window !== self.panel { close() }
            return event
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose()
    }
}

// MARK: - BrowserFloatingMenuView

private final class BrowserFloatingMenuView: NSView {
    // MARK: Private

    private static let width: CGFloat = 210
    private static let margin: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let tail: CGFloat = 6
    private static let highlight = NSColor(srgbRed: 0.271, green: 0.271, blue: 0.271, alpha: 0.48)

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let rows = rowFrames.last?.maxY ?? 0
        return NSSize(width: Self.width + Self.margin * 2, height: rows + Self.padding + Self.margin * 2 + Self.tail)
    }

    // MARK: Internal

    var tailX: CGFloat = 0

    private let items: [BrowserFloatingMenuItem]
    private let rowFrames: [NSRect]
    private let close: () -> Void
    private var tracking: NSTrackingArea?
    private var hovered: Int?

    init(items: [BrowserFloatingMenuItem], close: @escaping () -> Void) {
        self.items = items
        self.close = close
        var y = Self.padding
        var frames = [NSRect]()
        for item in items {
            let height: CGFloat =
                if case .separator = item {
                    17
                } else {
                    40
                }
            frames.append(NSRect(x: Self.padding, y: y, width: Self.width - Self.padding * 2, height: height))
            y += height
        }
        self.rowFrames = frames
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        let body = NSRect(
            x: Self.margin,
            y: Self.margin,
            width: Self.width,
            height: bounds.height - Self.margin * 2 - Self.tail,
        )
        let path = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
        let tip = min(max(tailX, body.minX + 22), body.maxX - 22)
        path.move(to: NSPoint(x: tip - 8, y: body.maxY))
        path.line(to: NSPoint(x: tip, y: body.maxY + Self.tail))
        path.line(to: NSPoint(x: tip + 8, y: body.maxY))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        for (index, item) in items.enumerated() {
            let frame = rowFrames[index].offsetBy(dx: Self.margin, dy: Self.margin)
            switch item {
            case .separator:
                Self.highlight.setFill()
                NSRect(x: frame.minX + 4, y: frame.minY + 8, width: frame.width - 8, height: 1).fill()
            case .action(let symbol, let title, let shortcut, let isEnabled, _, _):
                if index == hovered, isEnabled {
                    Self.highlight.setFill()
                    NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
                }
                let alpha: CGFloat = isEnabled ? 1 : 0.4
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
                {
                    let tinted = NSImage(size: image.size, flipped: false) { rect in
                        image.draw(in: rect)
                        NSColor.white.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(
                        in: NSRect(
                            x: frame.minX + 20 - image.size.width / 2,
                            y: frame.midY - image.size.height / 2,
                            width: image.size.width,
                            height: image.size.height,
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: alpha,
                        respectFlipped: true,
                        hints: nil,
                    )
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                ]
                let size = (title as NSString).size(withAttributes: attributes)
                (title as NSString).draw(
                    at: NSPoint(x: frame.minX + 40, y: frame.midY - size.height / 2),
                    withAttributes: attributes,
                )
                if let shortcut {
                    let keys: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.4 * alpha),
                    ]
                    let width = (shortcut as NSString)
                        .size(withAttributes: keys)
                        .width
                    (shortcut as NSString)
                        .draw(
                            at: NSPoint(x: frame.maxX - 8 - width, y: frame.midY - size.height / 2 + 1),
                            withAttributes: keys,
                        )
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(rowIndex(at: event)) }
    override func mouseExited(with _: NSEvent) { setHovered(nil) }

    override func mouseUp(with event: NSEvent) {
        guard let index = rowIndex(at: event),
              case .action(_, _, _, let isEnabled, _, let run) = items[index], isEnabled
        else { return }
        close()
        run()
    }

    private func rowIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return rowFrames.firstIndex { $0.offsetBy(dx: Self.margin, dy: Self.margin).contains(point) }
    }

    private func setHovered(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        needsDisplay = true
    }
}
