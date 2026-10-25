// BrowserWindowControlsLayout.swift

import CoreGraphics

enum BrowserWindowControlsLayout {
    static let buttonSize: CGFloat = 14
    static let controlsHeight: CGFloat = buttonSize
    static let buttonSpacing: CGFloat = 9
    static let controlsWidth: CGFloat = buttonSize * 3 + buttonSpacing * 2
    static let trailingSpacing: CGFloat = 6
    static let totalWidth: CGFloat = controlsWidth + trailingSpacing
}
