import AppKit
import SwiftUI

// MARK: - BrowserChromeControlButton

/// Temporary mounting adapter; chrome rendering and interactions live in AppKit.
struct BrowserChromeControlButton: NSViewRepresentable {
    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement = BrowserTooltipPlacement.belowLeading
    var isEnabled = true
    var isSelected = false
    var pressEffect = BrowserChromeControlPressEffect.none
    let action: () -> Void

    func makeNSView(context: Context) -> BrowserNativeChromeButton {
        let button = BrowserNativeChromeButton(symbol: systemImageName, title: tooltipTitle, action: action)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: BrowserNativeChromeButton, context _: Context) {
        button.configureSymbol(systemImageName, title: tooltipTitle)
        button.tooltipShortcut = tooltipShortcut
        button.tooltipPlacement = tooltipPlacement
        button.isEnabled = isEnabled
        button.isSelected = isSelected
        button.pressEffect = pressEffect.native
        button.onAction = action
    }

    func sizeThatFits(_: ProposedViewSize, nsView: BrowserNativeChromeButton, context _: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - BrowserChromeControlPressEffect

enum BrowserChromeControlPressEffect {
    case none, compress, moveLeft, moveRight, moveUp, moveDown, rotateClockwise

    // MARK: Internal

    var native: BrowserNativeChromeButton.PressEffect {
        switch self {
        case .none: .none
        case .compress: .compress
        case .moveLeft: .left
        case .moveRight: .right
        case .moveUp: .up
        case .moveDown: .down
        case .rotateClockwise: .rotateClockwise
        }
    }
}

// MARK: - BrowserSidebarPressButtonStyle

struct BrowserSidebarPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - BrowserSidebarPressTrackingButtonStyle

struct BrowserSidebarPressTrackingButtonStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
            }
    }
}

// MARK: - BrowserSidebarCloseButtonStyle

struct BrowserSidebarCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? BrowserChromeLayout.sidebarCloseButtonPressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
