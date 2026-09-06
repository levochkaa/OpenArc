import AppKit
import SwiftUI

// MARK: - BrowserSidebarView

/// Temporary header/footer adapters surround the native sidebar; list layout and interaction are AppKit-owned.
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

    func bottomChrome(state: BrowserNativeSidebarState) -> some View {
        VStack(spacing: 0) {
            BrowserUpdateToastView(updateController: updateController)
                .padding(.horizontal, 2)
                .padding(.bottom, BrowserChromeLayout.sidebarSectionSpacing)
            if model.supportsSpaces {
                spacesBar(state: state)
            }
        }
    }

    func spacesBar(state: BrowserNativeSidebarState) -> some View {
        BrowserSidebarSpacesBar(
            spaces: snapshot.spaces,
            selectedSpaceID: snapshot.selectedSpaceID,
            downloadsModel: model.downloadsModel,
            isSidebarResizing: isSidebarResizing,
            onSelectSpace: { spaceID in
                state.dismissRenamingIfNeeded()
                state.clearPinnedTabSelection()
                model.selectSpace(id: spaceID)
            },
            onCreateSpace: {
                state.dismissRenamingIfNeeded()
                state.clearPinnedTabSelection()
                model.createNewSpace()
            },
            onBeginRenameSpace: { spaceID in
                state.clearPinnedTabSelection()
                state.beginRenamingSpace(id: spaceID)
            },
            onChangeSpaceIcon: { systemImageName, spaceID in
                model.setIcon(systemImageName, forSpaceID: spaceID)
            },
            onDeleteSpace: { spaceID in
                state.dismissRenamingIfNeeded()
                state.clearPinnedTabSelection()
                model.deleteSpace(id: spaceID)
            }
        )
    }

    static func dismantleNSView(_ view: BrowserNativeSidebarNSView, coordinator _: ()) {
        view.state.clearTabDragState()
    }

    func makeNSView(context: Context) -> BrowserNativeSidebarNSView {
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot, sidebarWidth: sidebarWidth)
        let header =
            NSHostingView(rootView: AnyView(topChrome.frame(width: contentWidth)
                    .environmentObject(BrowserFaviconCache.shared)))
        let footer = NSHostingView(rootView: AnyView(bottomChrome(state: state).frame(width: contentWidth)))
        header.sizingOptions = [.intrinsicContentSize]
        footer.sizingOptions = [.intrinsicContentSize]
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
        if let footer = view.footer as? NSHostingView<AnyView> {
            footer.rootView = AnyView(bottomChrome(state: view.state).frame(width: contentWidth))
            view.footerHeight = footer.fittingSize.height
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
