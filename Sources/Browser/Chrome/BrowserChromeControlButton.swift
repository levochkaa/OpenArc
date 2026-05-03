import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserChromeControlButton

struct BrowserChromeControlButton: View {
    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement = BrowserTooltipPlacement.belowLeading
    var isEnabled = true
    var isSelected = false
    var pressEffect = BrowserChromeControlPressEffect.none
    let action: () -> Void

    @State var isHovered = false
    @State var isPressed = false

    var buttonShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
            style: .continuous
        )
    }

    var effectiveIsPressed: Bool {
        isEnabled && isPressed
    }

    var backgroundColor: Color {
        guard isEnabled else {
            return .clear
        }

        if effectiveIsPressed {
            return BrowserChromePalette.chromeButtonPressedBackground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverBackground
        }

        return .clear
    }

    var foregroundColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if effectiveIsPressed {
            return BrowserChromePalette.chromeButtonPressedForeground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverForeground
        }

        if isSelected {
            return BrowserChromePalette.primaryText
        }

        return BrowserChromePalette.secondaryText
    }

    var horizontalOffset: CGFloat {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .moveLeft:
            return -2
        case .moveRight:
            return 2
        case .compress, .moveDown, .moveUp, .none, .rotateClockwise:
            return 0
        }
    }

    var verticalOffset: CGFloat {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .moveUp:
            return -2
        case .moveDown:
            return 2
        case .compress, .moveLeft, .moveRight, .none, .rotateClockwise:
            return 0
        }
    }

    var rotationAngle: Double {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .rotateClockwise:
            return 90
        case .compress, .moveDown, .moveLeft, .moveRight, .moveUp, .none:
            return 0
        }
    }

    var scale: CGFloat {
        guard effectiveIsPressed else {
            return 1
        }

        switch pressEffect {
        case .compress:
            return 0.9
        case .moveDown, .moveLeft, .moveRight, .moveUp, .none, .rotateClockwise:
            return 1
        }
    }

    var shadowColor: Color {
        guard isEnabled, isHovered || effectiveIsPressed else {
            return .clear
        }

        return BrowserChromePalette.chromeButtonHighlightGlow
    }

    var shadowRadius: CGFloat {
        guard isEnabled, isHovered || effectiveIsPressed else {
            return 0
        }

        return effectiveIsPressed ? 10 : 8
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                buttonShape
                    .fill(backgroundColor)

                Image(systemName: systemImageName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .offset(x: horizontalOffset, y: verticalOffset)
                    .rotationEffect(.degrees(rotationAngle))
                    .scaleEffect(scale)
            }
            .frame(
                width: BrowserChromeLayout.chromeButtonSize,
                height: BrowserChromeLayout.chromeButtonSize
            )
            .shadow(color: shadowColor, radius: shadowRadius)
        }
        .buttonStyle(BrowserChromeControlPressTrackingButtonStyle { isPressed in
            self.isPressed = isEnabled && isPressed
        })
        .disabled(!isEnabled)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            placement: tooltipPlacement,
            isPresented: isHovered
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
    }
}

// MARK: - BrowserChromeControlPressEffect

enum BrowserChromeControlPressEffect {
    case none
    case compress
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case rotateClockwise
}

// MARK: - BrowserChromeControlPressTrackingButtonStyle

struct BrowserChromeControlPressTrackingButtonStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
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
