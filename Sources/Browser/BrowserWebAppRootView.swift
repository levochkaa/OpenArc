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

struct BrowserWebAppToolbar: NSViewRepresentable {
    let model: BrowserChromeModel
    let preferences: BrowserWebAppPreferences
    let configuration: BrowserWebAppConfiguration
    let actions: BrowserWebAppViewActions
    let shortcutStore: BrowserShortcutStore
    let windowControlsWidth: CGFloat

    static func dismantleNSView(_ view: BrowserWebAppToolbarNSView, coordinator _: ()) { view.closePopovers() }

    func makeNSView(context: Context) -> BrowserWebAppToolbarNSView {
        let view = BrowserWebAppToolbarNSView(
            model: model,
            preferences: preferences,
            configuration: configuration,
            actions: actions
        )
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserWebAppToolbarNSView, context _: Context) {
        view.actions = actions
        view.windowControlsWidth = windowControlsWidth
        view.refresh()
    }
}
