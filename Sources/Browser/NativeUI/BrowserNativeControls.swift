// BrowserNativeControls.swift

import AppKit

// MARK: - BrowserActionButton

final class BrowserActionButton: NSButton {
    // MARK: Internal

    var onAction: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.onAction = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(activate)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Private

    @objc private func activate() { onAction() }
}

// MARK: - BrowserActionToggle

/// An on/off switch in the small size Settings rows use.
final class BrowserActionToggle: NSSwitch {
    // MARK: Internal

    var onChange: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        controlSize = .mini
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Private

    @objc private func changed() { onChange(state == .on) }
}

// MARK: - BrowserActionPopUpButton

final class BrowserActionPopUpButton: NSPopUpButton {
    // MARK: Internal

    var onChange: (Int) -> Void = { _ in }

    init(titles: [String]) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Private

    @objc private func changed() { onChange(indexOfSelectedItem) }
}

// MARK: - BrowserNativeControls

@MainActor enum BrowserNativeControls {
    static func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        wraps: Bool = false,
    ) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func stack(
        _ views: [NSView],
        orientation: NSUserInterfaceLayoutOrientation = .vertical,
        spacing: CGFloat = 0,
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        stack.alignment = orientation == .vertical ? .leading : .centerY
        return stack
    }

    static func fillWidth(_ view: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor
            .constraint(
                equalTo: stack.widthAnchor,
                constant: -stack.edgeInsets.left - stack.edgeInsets.right,
            )
            .isActive = true
    }

    static func replaceViews(_ views: [NSView], in stack: NSStackView, fillingWidth: Bool = true) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            if fillingWidth {
                fillWidth(view, in: stack)
            } else {
                stack.addArrangedSubview(view)
            }
        }
    }

    static func padded(_ content: NSView, horizontal: CGFloat = 0, vertical: CGFloat = 0) -> NSView {
        let container = NSView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
        return container
    }

    static func divider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }
}

// MARK: - BrowserNativeScrollingStack

/// A flipped document with a stable scroll position; rebuilding a section does not replace the scroll view.
final class BrowserNativeScrollingStack: NSScrollView {
    // MARK: Internal

    let stack = NSStackView()

    // MARK: Private

    private let document = BrowserNativeSurface()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = document
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let position = contentView.bounds.origin
        document.setFrameSize(NSSize(width: contentView.bounds.width, height: document.frame.height))
        document.layoutSubtreeIfNeeded()
        let height = max(stack.fittingSize.height + 48, contentView.bounds.height)
        document.setFrameSize(NSSize(width: contentView.bounds.width, height: ceil(height)))
        contentView.scroll(to: NSPoint(x: 0, y: min(position.y, max(height - contentView.bounds.height, 0))))
        reflectScrolledClipView(contentView)
    }

    func setViews(_ views: [NSView]) {
        BrowserNativeControls.replaceViews(views, in: stack)
        needsLayout = true
    }
}
