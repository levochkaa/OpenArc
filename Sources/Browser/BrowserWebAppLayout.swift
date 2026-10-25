// BrowserWebAppLayout.swift

import AppKit

// MARK: - BrowserWebAppWindowLayout

struct BrowserWebAppWindowLayout: Equatable {
    let isFullscreen: Bool
    let showsToolbar: Bool

    var usesWindowContentInsets: Bool {
        !isFullscreen
    }

    var toolbarHorizontalInset: CGFloat {
        isFullscreen ? 0 : BrowserWebAppLayout.windowEdgeInset
    }

    var toolbarTopInset: CGFloat {
        showsToolbar ? BrowserWebAppLayout.windowEdgeInset : 0
    }

    var contentHorizontalInset: CGFloat {
        usesWindowContentInsets ? BrowserWebAppLayout.windowEdgeInset : 0
    }

    var contentBottomInset: CGFloat {
        usesWindowContentInsets ? BrowserWebAppLayout.windowEdgeInset : 0
    }

    var contentMinY: CGFloat {
        guard showsToolbar else {
            return usesWindowContentInsets ? BrowserWebAppLayout.windowEdgeInset : 0
        }

        return BrowserWebAppLayout.toolbarSurfaceHeight
    }

    var windowControlsWidth: CGFloat {
        isFullscreen ? 0 : BrowserWindowControlsLayout.totalWidth
    }

    var edgeDragInset: CGFloat {
        usesWindowContentInsets ? BrowserWebAppLayout.windowEdgeInset : 0
    }
}

// MARK: - BrowserWebAppLayout

enum BrowserWebAppLayout {
    static let windowStyleMask: NSWindow.StyleMask = [
        .borderless,
        .closable,
        .miniaturizable,
        .resizable,
    ]
    static let windowEdgeInset: CGFloat = 8
    static let toolbarHeight: CGFloat = 28
    static let toolbarContentGap = windowEdgeInset
    static let toolbarSurfaceHeight = windowEdgeInset + toolbarHeight + toolbarContentGap
    static let titleMaximumWidth: CGFloat = 420
    static let minimumTitlePadding: CGFloat = 24
}
