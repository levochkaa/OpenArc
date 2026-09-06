import AppKit
import SwiftUI

// MARK: - BrowserSidebarView

/// Temporary mounting adapter for the AppKit sidebar.
struct BrowserSidebarView: NSViewRepresentable {
    // MARK: Internal

    let model: BrowserChromeModel
    @ObservedObject var updateController: BrowserUpdateController

    let snapshot: BrowserSidebarSnapshot
    let extensions: [BrowserExtension]
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let showsCurrentURLRow: Bool
    let sidebarWidth: CGFloat
    let isSidebarResizing: Bool
    let toggleSidebarTooltipTitle: String
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    static func dismantleNSView(_ view: BrowserNativeSidebarNSView, coordinator _: ()) {
        view.state.clearTabDragState()
    }

    func makeNSView(context: Context) -> BrowserNativeSidebarNSView {
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot, sidebarWidth: sidebarWidth)
        let header = BrowserNativeSidebarHeaderNSView(model: model)
        let footer = BrowserNativeSidebarFooterNSView(state: state, updateController: updateController)
        let view = BrowserNativeSidebarNSView(state: state, header: header, footer: footer)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserNativeSidebarNSView, context _: Context) {
        if let header = view.header as? BrowserNativeSidebarHeaderNSView {
            header.onToggleSidebar = onToggleSidebar
            header.urlControls.onURLFrameChange = onURLRowFrameChange
            header.configure(
                showsWindowControls: showsWindowControlsInSidebar,
                showsURL: showsCurrentURLRow,
                isResizing: isSidebarResizing,
                toggleTitle: toggleSidebarTooltipTitle
            )
            view.headerHeight = header.preferredHeight
        }
        if let footer = view.footer as? BrowserNativeSidebarFooterNSView {
            footer.update(snapshot: snapshot, isResizing: isSidebarResizing)
            view.footerHeight = footer.height(for: contentWidth)
        }
        let previous = view.state.snapshot
        view.state.update(snapshot: snapshot, sidebarWidth: sidebarWidth, isResizing: isSidebarResizing)
        view.isCommandBarPresented = isCommandBarPresented
        let animated = previous.selectedSpaceID != snapshot.selectedSpaceID
            || previous.allTabs.map(\.id) != snapshot.allTabs.map(\.id)
            || previous.pinnedTabFolders != snapshot.pinnedTabFolders
        view.refresh(animated: animated)
    }

    // MARK: Private

    private var contentWidth: CGFloat { max(sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0) }
}

// MARK: @MainActor Equatable

extension BrowserSidebarView: @MainActor Equatable {
    static func == (lhs: BrowserSidebarView, rhs: BrowserSidebarView) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.extensions == rhs.extensions
            && lhs.showsWindowControlsInSidebar == rhs.showsWindowControlsInSidebar
            && lhs.isCommandBarPresented == rhs.isCommandBarPresented
            && lhs.isCurrentPageCommandBarPresented == rhs.isCurrentPageCommandBarPresented
            && lhs.showsCurrentURLRow == rhs.showsCurrentURLRow
            && lhs.sidebarWidth == rhs.sidebarWidth
            && lhs.isSidebarResizing == rhs.isSidebarResizing
            && lhs.toggleSidebarTooltipTitle == rhs.toggleSidebarTooltipTitle
    }
}
