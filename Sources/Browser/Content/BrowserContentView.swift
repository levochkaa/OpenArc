import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserContentView

/// Temporary mounting adapter for the browser window shell.
struct BrowserContentView: NSViewRepresentable {
    let hostView: NSView
    let isContextReady: Bool
    let hasSelectedTab: Bool
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool

    func makeNSView(context: Context) -> BrowserContentNSView {
        let view = BrowserContentNSView(hostView: hostView)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserContentNSView, context _: Context) {
        view.update(
            hostView: hostView,
            isContextReady: isContextReady,
            hasSelectedTab: hasSelectedTab,
            isSidebarVisible: isSidebarVisible,
            usesWindowContentInsets: usesWindowContentInsets
        )
    }
}

// MARK: @MainActor Equatable

extension BrowserContentView: @MainActor Equatable {
    static func == (lhs: BrowserContentView, rhs: BrowserContentView) -> Bool {
        ObjectIdentifier(lhs.hostView) == ObjectIdentifier(rhs.hostView)
            && lhs.isContextReady == rhs.isContextReady
            && lhs.hasSelectedTab == rhs.hasSelectedTab
            && lhs.isSidebarVisible == rhs.isSidebarVisible
            && lhs.usesWindowContentInsets == rhs.usesWindowContentInsets
    }
}

// MARK: - BrowserViewportHostRepresentable

struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: NSView
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask

    func makeNSView(context _: Context) -> BrowserViewportClipView {
        let clipView = BrowserViewportClipView(hostView: hostView)
        clipView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
        return clipView
    }

    func updateNSView(_ nsView: BrowserViewportClipView, context _: Context) {
        nsView.update(hostView: hostView)
        nsView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
    }
}
