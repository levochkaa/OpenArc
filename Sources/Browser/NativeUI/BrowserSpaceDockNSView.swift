// BrowserSpaceDockNSView.swift

import AppKit

// MARK: - BrowserSpaceDockNSView

/// The Space switcher at the bottom of the sidebar. A click selects a Space;
/// dragging an icon sideways reorders the Spaces, and a
/// sidebar drag can drop tabs on an icon. The dock takes the mouse itself
/// because its buttons track clicks on their own.
final class BrowserSpaceDockNSView: BrowserNativeSurface {
    // MARK: Internal

    override var isFlipped: Bool { true }

    /// The dragged Space and its new index.
    var onMove: (String, Int) -> Void = { _, _ in }

    var itemSize: CGFloat = BrowserChromeLayout.chromeButtonSize
    var itemHeight: CGFloat = BrowserChromeLayout.chromeButtonSize
    var itemSpacing: CGFloat = BrowserChromeLayout.chromeButtonSpacing
    var isReorderingEnabled = true

    private(set) var draggedID: String?

    /// Buttons in Space order.
    var items = [(id: String, button: BrowserNativeChromeButton)]() {
        didSet { needsLayout = true }
    }

    /// The Space whose icon a sidebar drag rests on, shown like a hover.
    var dropTargetID: String? {
        didSet {
            for item in items {
                item.button.isDropTarget = item.id == dropTargetID
            }
        }
    }

    // MARK: Private

    private var pressedIndex: Int?
    private var pressStart = NSPoint.zero
    private var dragX: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return item(at: local) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        let contentWidth = CGFloat(items.count) * itemSize + CGFloat(max(items.count - 1, 0)) * itemSpacing
        let origin = (bounds.width - contentWidth) / 2
        let order = displayOrder()
        for (slot, index) in order.enumerated() {
            let item = items[index]
            guard item.id != draggedID else { continue }
            item.button.frame = NSRect(
                x: origin + CGFloat(slot) * (itemSize + itemSpacing),
                y: 0,
                width: itemSize,
                height: itemHeight,
            )
        }
        if let draggedID, let dragged = items.first(where: { $0.id == draggedID }) {
            let x = min(max(dragX - itemSize / 2, origin), origin + contentWidth - itemSize)
            dragged.button.frame = NSRect(x: x, y: 0, width: itemSize, height: itemHeight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = item(at: point) else { return }
        pressedIndex = index
        pressStart = point
        items[index].button.highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedIndex, items.indices.contains(pressedIndex) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if draggedID == nil {
            guard isReorderingEnabled, items.count > 1, abs(point.x - pressStart.x) > 4 else { return }
            items[pressedIndex].button.highlight(false)
            draggedID = items[pressedIndex].id
        }
        dragX = point.x
        animateLayout()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedIndex = nil
        }
        guard let pressedIndex, items.indices.contains(pressedIndex) else { return }
        let button = items[pressedIndex].button
        button.highlight(false)
        guard let draggedID else {
            let point = convert(event.locationInWindow, from: nil)
            if item(at: point) == pressedIndex, button.isEnabled {
                button.sendAction(button.action, to: button.target)
            }
            return
        }
        let target = targetIndex()
        self.draggedID = nil
        if target != pressedIndex {
            onMove(draggedID, target)
        }
        animateLayout()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return item(at: point).flatMap { items[$0].button.menu }
    }

    /// The Space whose icon, with half the gap on each side, is under a
    /// window point; nil while the dock is hidden.
    func spaceID(atWindowPoint point: NSPoint) -> String? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: nil)
        guard visibleRect.contains(local) else { return nil }
        return items.first { item in
            item.button.frame.insetBy(dx: -itemSpacing / 2, dy: 0).contains(local)
        }?.id
    }

    private func item(at point: NSPoint) -> Int? {
        items.indices.first { items[$0].button.frame.contains(point) }
    }

    /// The slot the dragged icon's center is over.
    private func targetIndex() -> Int {
        guard let pressedIndex else { return 0 }
        guard draggedID != nil else { return pressedIndex }
        let contentWidth = CGFloat(items.count) * itemSize + CGFloat(max(items.count - 1, 0)) * itemSpacing
        let origin = (bounds.width - contentWidth) / 2
        let slot = Int(((dragX - origin) / (itemSize + itemSpacing)).rounded(.down))
        return min(max(slot, 0), items.count - 1)
    }

    /// Item indices by slot while dragging: the others make room for the
    /// dragged icon at its target slot.
    private func displayOrder() -> [Int] {
        var order = Array(items.indices)
        guard draggedID != nil, let pressedIndex else { return order }
        order.remove(at: pressedIndex)
        order.insert(pressedIndex, at: targetIndex())
        return order
    }

    private func animateLayout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
            needsLayout = true
            layout()
        }
    }
}
