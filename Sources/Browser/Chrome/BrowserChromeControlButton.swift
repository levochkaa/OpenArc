import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserChromeControlButton

struct BrowserChromeControlButton: View {
    // MARK: Internal

    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement = BrowserTooltipPlacement.belowLeading
    var isEnabled = true
    var isSelected = false
    var pressEffect = BrowserChromeControlPressEffect.none
    let action: () -> Void

    var effectiveIsPressed: Bool {
        isEnabled && isPressed
    }

    var backgroundColor: Color {
        guard isEnabled else {
            return .clear
        }

        if isHovered {
            return BrowserChromePalette.rowHover
        }

        return .clear
    }

    var backgroundScale: CGFloat {
        effectiveIsPressed ? backgroundPressScale : 1
    }

    var foregroundColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if effectiveIsPressed {
            return BrowserChromePalette.chromeButtonPressedForeground
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
            return compressIconPressScale
        case .moveDown, .moveLeft, .moveRight, .moveUp, .none, .rotateClockwise:
            return 1
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .offset(x: horizontalOffset, y: verticalOffset)
                .rotationEffect(.degrees(rotationAngle))
                .scaleEffect(scale)
                .frame(
                    width: BrowserChromeLayout.chromeButtonSize,
                    height: BrowserChromeLayout.chromeButtonSize
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
                        style: .continuous
                    )
                    .fill(backgroundColor)
                    .scaleEffect(backgroundScale)
                )
        }
        .buttonStyle(BrowserChromeControlPressTrackingButtonStyle { isPressed in
            self.isPressed = isEnabled && isPressed
        })
        .disabled(!isEnabled)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled {
                isPressed = false
            }
        }
        .onDisappear {
            isPressed = false
            isHovered = false
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

    // MARK: Private

    @State private var isHovered = false
    @State private var isPressed = false

    private let backgroundPressScale: CGFloat = 0.95
    private let compressIconPressScale: CGFloat = 0.9
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

private struct BrowserChromeControlPressTrackingButtonStyle: ButtonStyle {
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
