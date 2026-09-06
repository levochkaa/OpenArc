import AppKit
import SwiftUI

// MARK: - BrowserWebAppViewActions

struct BrowserWebAppViewActions {
    let showAppInfo: () -> Void
    let openInBrowser: () -> Void
    let uninstall: () -> Void
}

// MARK: - BrowserWebAppRootView

struct BrowserWebAppRootView: View {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        configuration: BrowserWebAppConfiguration,
        preferences: BrowserWebAppPreferences,
        actions: BrowserWebAppViewActions
    ) {
        self.model = model
        self.configuration = configuration
        self.preferences = preferences
        self.actions = actions
        _shortcutStore = ObservedObject(wrappedValue: model.shortcutStore)
        _userPreferences = ObservedObject(wrappedValue: model.userPreferencesStore)
    }

    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel
    @ObservedObject var preferences: BrowserWebAppPreferences

    var body: some View {
        GeometryReader { proxy in
            let windowLayout = BrowserWebAppWindowLayout(
                isFullscreen: isWindowFullscreen,
                showsToolbar: showsToolbar
            )

            ZStack(alignment: .topLeading) {
                BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                BrowserContentView(
                    hostView: model.hostView,
                    isContextReady: model.isContextReady,
                    hasSelectedTab: model.selectedTabID != nil,
                    isSidebarVisible: false,
                    usesWindowContentInsets: windowLayout.usesWindowContentInsets
                )
                .equatable()
                .frame(
                    width: max(proxy.size.width - windowLayout.contentHorizontalInset * 2, 0),
                    height: max(proxy.size.height - windowLayout.contentMinY - windowLayout.contentBottomInset, 0)
                )
                .offset(x: windowLayout.contentHorizontalInset, y: windowLayout.contentMinY)

                if showsToolbar {
                    BrowserWebAppToolbar(
                        model: model,
                        preferences: preferences,
                        configuration: configuration,
                        actions: actions,
                        shortcutStore: shortcutStore,
                        windowControlsWidth: windowLayout.windowControlsWidth
                    )
                    .frame(
                        width: max(proxy.size.width - windowLayout.toolbarHorizontalInset * 2, 0),
                        height: BrowserWebAppLayout.toolbarHeight
                    )
                    .offset(x: windowLayout.toolbarHorizontalInset, y: windowLayout.toolbarTopInset)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
                }

                BrowserContentEdgeDragRegions(
                    windowSize: proxy.size,
                    blockedLeadingWidth: 0,
                    leadingInset: windowLayout.edgeDragInset,
                    topInset: windowLayout.edgeDragInset,
                    trailingInset: windowLayout.edgeDragInset,
                    bottomInset: windowLayout.edgeDragInset
                )
                .zIndex(6)

                BrowserFindBarOverlay(model: model, blockedLeadingInset: 0)
                    .frame(
                        width: max(proxy.size.width - windowLayout.contentHorizontalInset * 2, 0),
                        height: max(proxy.size.height - windowLayout.contentMinY - windowLayout.contentBottomInset, 0)
                    )
                    .offset(x: windowLayout.contentHorizontalInset, y: windowLayout.contentMinY)
                    .zIndex(8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background {
            BrowserWindowFullscreenReader { state in
                isWindowFullscreen = state.isFullscreen
            }
            .allowsHitTesting(false)
        }
        .clipped()
        .environmentObject(faviconCache)
        .animation(
            .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
            value: showsToolbar
        )
    }

    // MARK: Private

    @ObservedObject private var shortcutStore: BrowserShortcutStore
    @ObservedObject private var userPreferences: BrowserUserPreferencesStore
    @ObservedObject private var faviconCache = BrowserFaviconCache.shared
    @State private var isWindowFullscreen = false

    private let configuration: BrowserWebAppConfiguration
    private let actions: BrowserWebAppViewActions

    private var chromeBackgroundMode: BrowserChromeBackgroundMode {
        userPreferences.blurredChromeBackgroundEnabled ? .blurred : .black
    }

    private var showsToolbar: Bool {
        !isWindowFullscreen || preferences.alwaysShowsToolbarInFullscreen
    }
}

// MARK: - BrowserWebAppToolbar

struct BrowserWebAppToolbar: View {
    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel
    @ObservedObject var preferences: BrowserWebAppPreferences

    let configuration: BrowserWebAppConfiguration
    let actions: BrowserWebAppViewActions

    @ObservedObject var shortcutStore: BrowserShortcutStore

    let windowControlsWidth: CGFloat

    var body: some View {
        ZStack {
            BrowserWindowDragRegion()

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                if windowControlsWidth > 0 {
                    BrowserWindowControlsView(showsInSidebar: true)
                        .frame(
                            width: windowControlsWidth,
                            height: BrowserWindowControlsLayout.controlsHeight
                        )
                }

                BrowserChromeControlButton(
                    systemImageName: "arrow.backward",
                    tooltipTitle: BrowserStrings.navigationBack,
                    tooltipShortcut: shortcutStore.shortcut(for: .goBack),
                    isEnabled: model.canGoBack,
                    pressEffect: .moveLeft,
                    action: model.goBack
                )

                BrowserChromeControlButton(
                    systemImageName: model.canStopLoading ? "xmark" : "arrow.clockwise",
                    tooltipTitle: model.canStopLoading
                        ? BrowserStrings.navigationStopLoading
                        : BrowserStrings.navigationRefresh,
                    tooltipShortcut: model.canStopLoading ? nil : shortcutStore.shortcut(for: .reload),
                    isEnabled: model.canStopLoading || model.canReload,
                    pressEffect: model.canStopLoading ? .compress : .rotateClockwise,
                    action: model.canStopLoading ? model.stopLoadingCurrentTab : model.reloadCurrentTab
                )

                Spacer(minLength: BrowserWebAppLayout.minimumTitlePadding)

                extensionsButton
                moreMenu
            }

            Text(toolbarTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .lineLimit(1)
                .truncationMode(preferences.alwaysShowsFullURLs ? .middle : .tail)
                .frame(maxWidth: BrowserWebAppLayout.titleMaximumWidth)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, BrowserChromeLayout.bookmarksBarHorizontalPadding)
        .frame(height: BrowserWebAppLayout.toolbarHeight)
        .background {
            BrowserWindowDragRegion()
        }
        .onDisappear {
            extensionActionPopup?.close()
            extensionActionPopup = nil
            isMoreMenuHovered = false
        }
    }

    // MARK: Private

    @State private var isExtensionsPopoverPresented = false
    @State private var extensionActionPopup: BrowserExtensionActionPopup?
    @State private var isMoreMenuHovered = false

    private var toolbarTitle: String {
        guard let tab = model.currentTab else {
            return configuration.name
        }

        if preferences.alwaysShowsFullURLs {
            return BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
        }

        return tab.displayTitle
    }

    private var currentHost: String? {
        guard let host = model.currentTab?.pageURL?.host else {
            return nil
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
    }

    private var extensionsButton: some View {
        BrowserChromeControlButton(
            systemImageName: "puzzlepiece.extension",
            tooltipTitle: BrowserStrings.extensionsSectionTitle,
            tooltipShortcut: nil,
            isEnabled: model.isContextReady,
            pressEffect: .compress,
            action: { isExtensionsPopoverPresented = true }
        )
        .popover(isPresented: $isExtensionsPopoverPresented, arrowEdge: .top) {
            BrowserSiteControlCenterPopover(
                extensions: model.browserExtensions,
                pinnedExtensionIDs: model.pinnedExtensionIDs,
                currentHost: currentHost,
                onManageExtensions: {
                    isExtensionsPopoverPresented = false
                    model.openExtensionsManager()
                },
                onAddExtension: {
                    isExtensionsPopoverPresented = false
                    model.openExtensionStore()
                },
                onSelectExtension: { extensionID in
                    let popup = model.openExtension(id: extensionID)
                    isExtensionsPopoverPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = popup
                    return popup
                },
                onOpenExtensionStore: { extensionID in
                    isExtensionsPopoverPresented = false
                    model.openExtensionStore(id: extensionID)
                },
                onOpenExtensionDetails: { extensionID in
                    isExtensionsPopoverPresented = false
                    model.openExtensionDetails(id: extensionID)
                },
                onRemoveExtension: { extensionID in
                    isExtensionsPopoverPresented = false
                    model.removeExtension(id: extensionID)
                },
                onToggleExtensionPinned: { extensionID in
                    model.toggleExtensionPinned(id: extensionID)
                }
            )
            .onAppear(perform: model.refreshBrowserExtensions)
        }
        .popover(item: $extensionActionPopup, arrowEdge: .top) { popup in
            BrowserExtensionActionPopupView(popup: popup)
        }
    }

    private var moreMenu: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
                style: .continuous
            )
            .fill(isMoreMenuHovered ? BrowserChromePalette.rowHover : Color.clear)

            Menu {
                Button(BrowserStrings.webAppInfoAction, action: actions.showAppInfo)

                Button(BrowserStrings.webAppCopyURLAction) {
                    _ = model.copySelectedTabLink()
                }
                .disabled(!model.canCopySelectedTabLink)

                Button(BrowserStrings.webAppOpenInBrowserAction, action: actions.openInBrowser)
                    .disabled(model.currentTab == nil)

                Divider()

                Button(BrowserStrings.webAppUninstallAction(configuration.name), role: .destructive) {
                    actions.uninstall()
                }

                Divider()

                Menu(BrowserStrings.webAppZoomMenu(model.zoomPercent)) {
                    Button(BrowserStrings.webAppZoomOutAction, action: model.zoomOut)
                        .disabled(model.zoomPercent == BrowserChromeModel.zoomPercentages.first)

                    Button(BrowserStrings.webAppZoomResetAction, action: model.resetZoom)
                        .disabled(model.zoomPercent == 100)

                    Button(BrowserStrings.webAppZoomInAction, action: model.zoomIn)
                        .disabled(model.zoomPercent == BrowserChromeModel.zoomPercentages.last)
                }

                Button(BrowserStrings.menuPrint, action: model.printCurrentPage)
                    .disabled(!model.canPrintPage)

                Button(BrowserStrings.menuFind, action: { _ = model.presentFindInPage() })
                    .disabled(!model.canPresentFindInPage)

                Menu(BrowserStrings.webAppEditMenu) {
                    Button(BrowserStrings.menuCut) {
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                    }
                    Button(BrowserStrings.menuCopy) {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                    Button(BrowserStrings.menuPaste) {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                    Button(BrowserStrings.menuSelectAll) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }

                Button(BrowserStrings.webAppCastAction, action: model.castCurrentPage)
                    .disabled(!model.canCastPage)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .frame(
                        width: BrowserChromeLayout.chromeButtonSize,
                        height: BrowserChromeLayout.chromeButtonSize
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(BrowserSidebarCloseButtonStyle())
        }
        .frame(
            width: BrowserChromeLayout.chromeButtonSize,
            height: BrowserChromeLayout.chromeButtonSize
        )
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            isMoreMenuHovered = hovering
        }
        .onDisappear {
            isMoreMenuHovered = false
        }
        .help(BrowserStrings.webAppMoreAction)
    }
}
