import AppKit
import QuartzCore
import SwiftUI

struct BrowserSidebarHeaderView: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool
    let shortcutStore: BrowserShortcutStore
    let showsWindowControlsInSidebar: Bool
    let onToggleSidebar: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onStopLoading: () -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: BrowserChromeLayout.windowControlsTrailingGap) {
                BrowserWindowControlsView(showsInSidebar: showsWindowControlsInSidebar)
                    .frame(height: BrowserChromeLayout.chromeButtonSize)
                    .fixedSize(horizontal: true, vertical: false)

                BrowserChromeControlButton(
                    systemImageName: "sidebar.left",
                    tooltipTitle: shortcutStore.descriptor(for: .toggleSidebar).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .toggleSidebar),
                    pressEffect: .compress,
                    action: onToggleSidebar
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                BrowserChromeControlButton(
                    systemImageName: "arrow.backward",
                    tooltipTitle: shortcutStore.descriptor(for: .goBack).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .goBack),
                    isEnabled: canGoBack,
                    pressEffect: .moveLeft,
                    action: onGoBack
                )

                BrowserChromeControlButton(
                    systemImageName: "arrow.forward",
                    tooltipTitle: shortcutStore.descriptor(for: .goForward).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .goForward),
                    isEnabled: canGoForward,
                    pressEffect: .moveRight,
                    action: onGoForward
                )

                if canStopLoading {
                    BrowserChromeControlButton(
                        systemImageName: "xmark",
                        tooltipTitle: BrowserStrings.navigationStopLoading,
                        tooltipShortcut: nil,
                        isEnabled: canStopLoading,
                        pressEffect: .compress,
                        action: onStopLoading
                    )
                } else {
                    BrowserChromeControlButton(
                        systemImageName: "arrow.clockwise",
                        tooltipTitle: shortcutStore.descriptor(for: .reload).helpTitle,
                        tooltipShortcut: shortcutStore.shortcut(for: .reload),
                        isEnabled: canReload,
                        pressEffect: .rotateClockwise,
                        action: onReload
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
    }
}
