import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarEmptySectionDropZone

struct BrowserSidebarEmptySectionDropZone: View {
    let height: CGFloat
    let showsDropIndicator: Bool

    var body: some View {
        Color.clear
            .frame(height: height)
            .overlay(alignment: .center) {
                if showsDropIndicator, height > 0 {
                    BrowserSidebarDropIndicator()
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - BrowserSidebarTopChromeDivider

struct BrowserSidebarTopChromeDivider: View {
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(BrowserChromePalette.sidebarTopChromeDivider)
            .frame(height: BrowserChromeLayout.sidebarTopChromeDividerHeight)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - BrowserSidebarTemporaryTabsDivider

struct BrowserSidebarTemporaryTabsDivider: View {
    let clearTemporaryTabsDescriptor: BrowserCommandDescriptor
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let showsClearButton: Bool
    let isClearButtonHovered: Bool
    let onHoverClearButton: (Bool) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(BrowserChromePalette.sidebarDivider)
                .frame(height: 1)

            if showsClearButton {
                Button(action: onClear) {
                    Text(BrowserStrings.sidebarClearTemporaryTabs)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            isClearButtonHovered
                                ? BrowserChromePalette.secondaryText
                                : BrowserChromePalette.sidebarClearButtonForeground
                        )
                        .padding(.horizontal, BrowserChromeLayout.sidebarClearButtonHorizontalPadding)
                        .padding(.vertical, BrowserChromeLayout.sidebarClearButtonVerticalPadding)
                        .background {
                            BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                        }
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.12), value: isClearButtonHovered)
                .transition(.opacity)
                .onHover(perform: onHoverClearButton)
                .browserTooltip(
                    title: clearTemporaryTabsDescriptor.helpTitle,
                    shortcut: clearTemporaryTabsDescriptor.shortcut,
                    isPresented: isClearButtonHovered
                )
            }
        }
        .frame(height: BrowserChromeLayout.sidebarDividerHeight)
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: showsClearButton)
    }
}

// MARK: - BrowserSidebarDropIndicator

struct BrowserSidebarDropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarDropIndicatorThickness / 2, style: .continuous)
            .fill(BrowserChromePalette.sidebarDropIndicator)
            .frame(height: BrowserChromeLayout.sidebarDropIndicatorThickness)
    }
}
