import AppKit
import SwiftUI

// MARK: - BrowserSidebarView

/// Temporary header adapter surrounds the native sidebar; list layout and interaction are AppKit-owned.
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

    var topChrome: some View {
        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(
                canGoBack: snapshot.canGoBack,
                canGoForward: snapshot.canGoForward,
                canStopLoading: snapshot.canStopLoading,
                canReload: snapshot.canReload,
                shortcutStore: model.shortcutStore,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                showsNavigationControls: showsCurrentURLRow,
                toggleSidebarTooltipTitle: toggleSidebarTooltipTitle,
                onToggleSidebar: onToggleSidebar,
                onGoBack: model.goBack,
                onGoForward: model.goForward,
                onStopLoading: model.stopLoadingCurrentTab,
                onReload: model.reloadCurrentTab
            )

            if model.showsProfileIndicator {
                BrowserSidebarProfileIndicator(profileName: model.profileDisplayName)
            }

            if showsCurrentURLRow {
                BrowserSidebarCurrentURLRow(
                    tab: snapshot.selectedTab,
                    extensions: extensions,
                    pinnedExtensionIDs: model.pinnedExtensionIDs,
                    copyLinkShortcut: model.shortcutStore.shortcut(for: .copyLink),
                    toggleBookmarksBarShortcut: model.shortcutStore.shortcut(for: .toggleBookmarksBar),
                    isSearchPresented: isCurrentPageCommandBarPresented,
                    isSidebarResizing: isSidebarResizing,
                    isSiteToolbarPresented: model.userPreferencesStore.siteURLToolbarEnabled,
                    siteToolbarShowsFullURL: model.userPreferencesStore.siteToolbarShowsFullURL,
                    isBookmarksBarVisible: model.userPreferencesStore.bookmarksBarVisible,
                    onFrameChange: onURLRowFrameChange,
                    onOpenSearch: model.presentCurrentPageCommandBar,
                    onCopyURL: {
                        model.copySelectedTabLink()
                    },
                    onCaptureFullPage: {
                        model.captureFullPageSelectedTabToPasteboard()
                    },
                    onToggleSiteToolbar: {
                        model.userPreferencesStore.siteURLToolbarEnabled.toggle()
                    },
                    onToggleSiteToolbarFullURL: {
                        model.userPreferencesStore.siteToolbarShowsFullURL.toggle()
                    },
                    onToggleBookmarksBar: {
                        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
                            model.userPreferencesStore.bookmarksBarVisible.toggle()
                        }
                    },
                    onRefreshExtensions: model.refreshBrowserExtensions,
                    onOpenExtensionsManager: model.openExtensionsManager,
                    onOpenExtensionStore: model.openExtensionStore,
                    onOpenExtensionStorePage: model.openExtensionStore,
                    onOpenExtensionDetails: model.openExtensionDetails,
                    onRemoveExtension: { extensionID in
                        model.removeExtension(id: extensionID)
                    },
                    onToggleExtensionPinned: { extensionID in
                        model.toggleExtensionPinned(id: extensionID)
                    },
                    onOpenExtension: model.openExtension
                )
            }
        }
    }

    static func dismantleNSView(_ view: BrowserNativeSidebarNSView, coordinator _: ()) {
        view.state.clearTabDragState()
    }

    func makeNSView(context: Context) -> BrowserNativeSidebarNSView {
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot, sidebarWidth: sidebarWidth)
        let header =
            NSHostingView(rootView: AnyView(topChrome.frame(width: contentWidth)
                    .environmentObject(BrowserFaviconCache.shared)))
        let footer = BrowserNativeSidebarFooterNSView(state: state, updateController: updateController)
        header.sizingOptions = [.intrinsicContentSize]
        let view = BrowserNativeSidebarNSView(state: state, header: header, footer: footer)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserNativeSidebarNSView, context _: Context) {
        if let header = view.header as? NSHostingView<AnyView> {
            header
                .rootView = AnyView(topChrome.frame(width: contentWidth).environmentObject(BrowserFaviconCache.shared))
            view.headerHeight = header.fittingSize.height
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
