// BrowserSplitDividerView.swift

import AppKit
import QuartzCore

// MARK: - BrowserSplitDividerView

/// Handle in the gap between two Split View panes. Dragging resizes the
/// neighbors live and commits once on release; a double click makes the two
/// neighbors equal. A small grip fades in while the handle is hovered or
/// dragged.
@objc final class BrowserSplitDividerView: NSView {
    // MARK: Internal

    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }

    /// Index of the left or upper pane next to this divider.
    @objc var index = 0

    /// Pointer location in the superview's coordinates.
    @objc var onDrag: ((NSPoint) -> Void)?
    @objc var onDragEnd: (() -> Void)?
    @objc var onReset: (() -> Void)?

    /// The grip shows on hover; the edge of docked Developer Tools has none.
    @objc var showsGrip = true

    /// Panes are stacked top to bottom, so the divider moves vertically.
    @objc var isVerticalSplit = false {
        didSet {
            if oldValue != isVerticalSplit {
                window?.invalidateCursorRects(for: self)
                needsLayout = true
            }
        }
    }

    /// A right-click menu, as the docked Developer Tools' edge offers.
    @objc var contextMenuProvider: (() -> NSMenu?)?

    // MARK: Private

    private let grip = CALayer()
    private var trackingArea: NSTrackingArea?

    private var isHovered = false {
        didSet { updateGrip() }
    }

    private var isDragging = false {
        didSet { updateGrip() }
    }

    private var cursor: NSCursor { isVerticalSplit ? .resizeUpDown : .resizeLeftRight }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        grip.cornerRadius = BrowserSplitPaneLayout.dividerGripSize.width / 2
        grip.opacity = 0
        layer?.addSublayer(grip)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(BrowserStrings.splitDividerAccessibilityLabel)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = BrowserSplitPaneLayout.dividerGripSize
        let gripSize = isVerticalSplit ? CGSize(width: size.height, height: size.width) : size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.frame = CGRect(
            x: ((bounds.width - gripSize.width) / 2).rounded(),
            y: ((bounds.height - gripSize.height) / 2).rounded(),
            width: gripSize.width,
            height: gripSize.height,
        )
        CATransaction.commit()
    }

    override func updateLayer() {
        grip.backgroundColor = BrowserChromeColors.secondaryText.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        isDragging = true
        cursor.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        onDragEnd?()
    }

    /// The grip fades over 0.16 s.
    private func updateGrip() {
        let opacity: Float = showsGrip && (isHovered || isDragging) ? 1 : 0
        guard grip.opacity != opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = grip.presentation()?.opacity ?? grip.opacity
        fade.toValue = opacity
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        grip.add(fade, forKey: "opacity")
        grip.opacity = opacity
    }
}

// MARK: - BrowserDevToolsDockSide

/// Which side of the page docked Developer Tools take, kept across launches.
@objc enum BrowserDevToolsDockSide: Int, CaseIterable {
    case right
    case bottom
    case left
    /// A window of their own, as the engine opens them.
    case window

    static let defaultsKey = "browser.devtools.dockSide"
    static let didChangeNotification = Notification.Name("BrowserDevToolsDockSideDidChange")

    static var current: BrowserDevToolsDockSide {
        BrowserDevToolsDockSide(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .right
    }

    var title: String {
        switch self {
        case .right: BrowserStrings.devToolsDockRight
        case .bottom: BrowserStrings.devToolsDockBottom
        case .left: BrowserStrings.devToolsDockLeft
        case .window: BrowserStrings.devToolsUndock
        }
    }
}

// MARK: - BrowserDevToolsDockMenu

/// The docked tools' edge menu: Dock to Right, Bottom or Left.
@MainActor @objc final class BrowserDevToolsDockMenu: NSObject {
    /// For the engine, which lays the tools out on this side.
    @objc static var currentSide: BrowserDevToolsDockSide { BrowserDevToolsDockSide.current }

    @objc static func menu() -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        let current = BrowserDevToolsDockSide.current
        for side in BrowserDevToolsDockSide.allCases {
            if side == .window {
                menu.addItem(.separator())
            }
            let item = BrowserNativeMenus.add(side.title, to: menu) {
                UserDefaults.standard.set(side.rawValue, forKey: BrowserDevToolsDockSide.defaultsKey)
                NotificationCenter.default.post(name: BrowserDevToolsDockSide.didChangeNotification, object: nil)
            }
            item.state = side == current ? .on : .off
        }
        return menu
    }
}
