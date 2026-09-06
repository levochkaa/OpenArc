import AppKit

/// Window chrome reserves space for a pinned sidebar; a hover sidebar stays above the viewport.
struct BrowserWindowChromeLayout {
    let windowSize: CGSize
    let sidebarWidth: CGFloat
    let isSidebarVisible: Bool
    let isHoverSidebarPresented: Bool
    let isOverlayChromeVisible: Bool
    let isFullscreen: Bool
    let showsSiteToolbar: Bool
    let showsBookmarksBar: Bool
    let extensionSidePanelWidth: CGFloat?

    var edgeInset: CGFloat { isFullscreen ? 0 : BrowserChromeLayout.browserContentEdgeInset }
    var sidebarReservedWidth: CGFloat { isSidebarVisible ? sidebarWidth : 0 }
    var leadingInset: CGFloat { isSidebarVisible ? 0 : edgeInset }
    var contentMinX: CGFloat { sidebarReservedWidth + leadingInset }
    var chromeTopInset: CGFloat { showsSiteToolbar || showsBookmarksBar
        ? max(edgeInset, BrowserChromeLayout.sidebarOuterPadding)
        : edgeInset
    }

    var siteToolbarReservedHeight: CGFloat { showsSiteToolbar
        ? BrowserChromeLayout.siteToolbarHeight + BrowserChromeLayout.bookmarksBarContentGap
        : 0
    }

    var bookmarksBarReservedHeight: CGFloat { showsBookmarksBar
        ? BrowserChromeLayout.bookmarksBarHeight + BrowserChromeLayout.bookmarksBarContentGap
        : 0
    }

    var contentMinY: CGFloat { chromeTopInset + siteToolbarReservedHeight + bookmarksBarReservedHeight }
    var extensionReservedWidth: CGFloat {
        extensionSidePanelWidth.map { $0 + BrowserChromeLayout.sidebarOuterPadding } ?? 0
    }

    var barWidth: CGFloat { max(windowSize.width - contentMinX - edgeInset, 0) }
    var contentFrame: CGRect {
        CGRect(
            x: contentMinX,
            y: contentMinY,
            width: max(barWidth - extensionReservedWidth, 0),
            height: max(windowSize.height - contentMinY - edgeInset, 0)
        )
    }

    var toolbarFrame: CGRect { CGRect(
        x: contentMinX,
        y: chromeTopInset,
        width: barWidth,
        height: BrowserChromeLayout.siteToolbarHeight
    ) }
    var bookmarksFrame: CGRect { CGRect(
        x: contentMinX,
        y: chromeTopInset + siteToolbarReservedHeight,
        width: barWidth,
        height: BrowserChromeLayout.bookmarksBarHeight
    ) }
    var sidebarFrame: CGRect {
        let overlay = !isSidebarVisible && isOverlayChromeVisible
        let inset = BrowserChromeLayout.sidebarHoverOverlayEdgeInset
        return CGRect(
            x: isSidebarVisible ? 0 : isHoverSidebarPresented ? inset : -sidebarWidth,
            y: overlay ? inset : 0,
            width: sidebarWidth,
            height: max(windowSize.height - (overlay
                    ? inset * 2
                    : 0), 0)
        )
    }

    var extensionFrame: CGRect {
        let width = extensionSidePanelWidth ?? 0
        return CGRect(
            x: max(windowSize.width - edgeInset - width, 0),
            y: contentMinY,
            width: width,
            height: contentFrame.height
        )
    }

    var extensionResizeFrame: CGRect {
        CGRect(
            x: extensionFrame.minX - BrowserChromeLayout.sidebarResizeHitWidth,
            y: contentMinY,
            width: BrowserChromeLayout.sidebarResizeHitWidth,
            height: contentFrame.height
        )
    }
}
